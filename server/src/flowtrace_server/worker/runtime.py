"""Independent durable worker. Only actual handlers are advertised/claimed."""

import hashlib
import threading
from time import monotonic
from uuid import UUID, uuid4

from pydantic import ValidationError
from sqlalchemy import select
from sqlalchemy.orm import Session

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import UserSession
from flowtrace_server.auth.service import now as auth_now
from flowtrace_server.auth.service import roles_for
from flowtrace_server.backups.job_references import (
    complete_creation,
    prepare_created_backup,
    register_created_job_backup,
    require_job_reference,
    start_creation,
)
from flowtrace_server.backups.leases import BackupLeaseError, backup_read_lease
from flowtrace_server.backups.quarantine_execution import (
    QuarantineExecutionError,
    complete_quarantine_execution,
    prepare_quarantine_execution,
    run_quarantine_execution,
)
from flowtrace_server.backups.rehearsal import RehearsalError, run_restore_rehearsal
from flowtrace_server.backups.rehearsal_schemas import RestoreRehearsalPayload
from flowtrace_server.backups.retention import require_backup_readable
from flowtrace_server.backups.service import (
    BackupError,
    _creation_lease,
    create_backup,
    verify_backup,
)
from flowtrace_server.configuration.models import ConfigurationHead
from flowtrace_server.diagnostics.policy import bind_diagnostics, build_diagnostic_policy
from flowtrace_server.imports.parsers import canonical
from flowtrace_server.imports.staging import stage_work_context
from flowtrace_server.imports.staging_parse import parse_stage_in_transaction
from flowtrace_server.imports.staging_preview import preview_stage_in_transaction
from flowtrace_server.imports.staging_publish import (
    apply_stage_in_transaction,
    undo_stage_in_transaction,
)
from flowtrace_server.imports.staging_schemas import (
    StageApplyJob,
    StageParseJob,
    StagePreviewJob,
    StageUndoJob,
)
from flowtrace_server.jobs import store
from flowtrace_server.jobs.administration import executable_kinds
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.persistence.models import ServerState

SUPPORTED_KINDS = frozenset(
    {
        "backup_verify",
        "backup_create",
        "restore_rehearsal",
        "backup_quarantine",
        "import_preview",
        "import_apply",
    }
)


class JobFailure(RuntimeError):
    def __init__(self, code, *, transient=False):
        self.code, self.transient = code, transient
        super().__init__(code)


def _backup_id(job):
    if not isinstance(job.payload, dict) or set(job.payload) != {"backup_id"}:
        raise JobFailure("job_payload_invalid")
    try:
        value = UUID(job.payload["backup_id"])
        if str(value) != job.payload["backup_id"]:
            raise ValueError
        return value
    except (ValueError, TypeError, AttributeError):
        raise JobFailure("job_payload_invalid") from None


def _require_recovery(session, job):
    if "recovery_admin" not in roles_for(session, job.owner_user_id):
        raise JobFailure("job_permission_changed")


def _restore_intent(job):
    try:
        parsed = RestoreRehearsalPayload.model_validate_json(canonical(job.payload))
        if parsed.model_dump(mode="json") != job.payload:
            raise ValueError
        return parsed
    except (ValidationError, TypeError, ValueError):
        raise JobFailure("job_payload_invalid") from None


def _require_restore_configuration(session, intent):
    version = session.scalar(
        select(ConfigurationHead.current_version)
        .where(ConfigurationHead.id == 1)
        .with_for_update(read=True)
    )
    if version != intent.config_version:
        raise JobFailure("restore_configuration_changed")


class Worker:
    def __init__(self, engine, settings, *, worker_id=None):
        self.engine, self.settings = engine, settings
        self.id = worker_id or uuid4()
        self.supported_kinds = executable_kinds(settings)
        self.diagnostic_policy = build_diagnostic_policy(settings)

    def close(self):
        self.diagnostic_policy.close()

    def _heartbeat(self, session, job_id=None):
        return store.heartbeat(
            session,
            self.id,
            version="0.1.0",
            supported_kinds=self.supported_kinds,
            active_job_id=job_id,
        )

    def _renew_loop(self, lease, stop, lost):
        while not stop.wait(20):
            try:
                with Session(self.engine) as session, session.begin():
                    store.renew(session, lease)
                    self._heartbeat(session, lease.job_id)
            except Exception:
                # A failed renewal fences completion; no native exception text.
                lost.set()
                return

    def run_once(self):
        with bind_diagnostics(self.diagnostic_policy):
            return self._run_once()

    def _run_once(self):
        with Session(self.engine) as session, session.begin():
            lease = store.claim(session, self.id, self.supported_kinds)
            kind = session.get(BackgroundJob, lease.job_id).kind if lease else None
            self._heartbeat(session, lease.job_id if lease else None)
        if lease is None:
            return False
        stop, lost = threading.Event(), threading.Event()
        created_prepared = None
        quarantine_prepared = None
        renewer = None
        # Maintenance excludes all shared DB transactions, including renewal.
        # Creation uses its fixed 300-second budget and final fence instead.
        if kind not in {
            "backup_create",
            "restore_rehearsal",
            "backup_quarantine",
            "import_preview",
            "import_apply",
        }:
            renewer = threading.Thread(
                target=self._renew_loop, args=(lease, stop, lost), daemon=True
            )
            renewer.start()
        try:
            if kind == "backup_quarantine":
                quarantine_prepared = prepare_quarantine_execution(
                    self.engine, self.settings, lease
                )
                run_quarantine_execution(quarantine_prepared)
                with Session(self.engine) as session, session.begin():
                    complete_quarantine_execution(
                        session, self.settings, lease, quarantine_prepared
                    )
                    self._heartbeat(session)
                return True
            if kind in {"import_preview", "import_apply"}:
                self._complete_import_stage(lease)
                return True
            with Session(self.engine) as session, session.begin():
                job = store.leased_job(session, lease)
                _require_recovery(session, job)
                owner_id = job.owner_user_id
                if kind == "restore_rehearsal":
                    intent = _restore_intent(job)
                    _require_restore_configuration(session, intent)
                    owner_id = job.owner_user_id
                else:
                    backup_id = _backup_id(job)
                epoch = job.sync_epoch
                instance_id = session.scalar(select(ServerState.instance_id))
                remaining = (job.lease_until - store.stamp(session)).total_seconds()
            try:
                if kind == "restore_rehearsal":
                    deadline = monotonic() + max(0, remaining - 5)

                    def check_restore_budget():
                        if monotonic() >= deadline:
                            raise RehearsalError("restore_verification_timeout")

                    def before_restore_read(identifier):
                        if identifier != intent.backup_id:
                            raise JobFailure("job_payload_invalid")
                        with Session(self.engine) as control, control.begin():
                            require_job_reference(control, lease.job_id, identifier)
                            guard = require_backup_readable(control, identifier)
                            if (
                                guard.registered
                                and guard.stamp.manifest_sha256 != intent.manifest_sha256
                            ):
                                raise JobFailure("backup_package_changed")

                    result = run_restore_rehearsal(
                        self.settings,
                        owner_user_id=owner_id,
                        job_id=lease.job_id,
                        payload=intent,
                        check_budget=check_restore_budget,
                        before_read=before_restore_read,
                    )
                elif kind == "backup_create":
                    preparation_deadline = monotonic() + max(0, remaining - 5)

                    def before_creation_read(identifier):
                        if identifier != backup_id:
                            raise JobFailure("job_payload_invalid")
                        with Session(self.engine) as control, control.begin():
                            require_job_reference(control, lease.job_id, identifier)
                            require_backup_readable(control, identifier)

                    manifest = self._create_backup_manifest(
                        backup_id,
                        epoch,
                        instance_id,
                        remaining=remaining,
                        before_read=before_creation_read,
                        job_id=lease.job_id,
                        owner_user_id=owner_id,
                    )

                    def check_preparation():
                        if monotonic() >= preparation_deadline:
                            raise BackupError("backup_creation_timeout")

                    created_prepared = prepare_created_backup(
                        self.settings,
                        backup_id=backup_id,
                        job_id=lease.job_id,
                        owner_user_id=owner_id,
                        manifest_sha256=hashlib.sha256(canonical(manifest)).hexdigest(),
                        check_budget=check_preparation,
                    )
                else:
                    with backup_read_lease(self.settings, backup_id):
                        with Session(self.engine) as control, control.begin():
                            require_job_reference(control, lease.job_id, backup_id)
                            require_backup_readable(control, backup_id)
                        manifest = verify_backup(
                            self.settings.data_directory.absolute() / "backups", backup_id
                        )
            except BackupLeaseError as error:
                raise JobFailure(error.code, transient=error.transient) from None
            except RehearsalError as error:
                raise JobFailure(error.code, transient=error.transient) from None
            except BackupError as error:
                code = str(error)
                try:
                    store._code(code)
                except ValueError:
                    code = "backup_verification_failed"
                raise JobFailure(code) from None
            except (OSError, ValueError):
                raise JobFailure("backup_unavailable") from None
            if lost.is_set():
                raise store.LeaseLost("job_lease_lost")

            def finish(session, current_job: BackgroundJob):
                _require_recovery(session, current_job)
                if kind == "restore_rehearsal":
                    if _restore_intent(current_job) != intent:
                        raise JobFailure("job_payload_changed")
                    _require_restore_configuration(session, intent)
                    if (
                        current_job.sync_epoch != epoch
                        or session.scalar(select(ServerState.instance_id)) != instance_id
                    ):
                        raise JobFailure("restore_source_changed")
                    return result
                if _backup_id(current_job) != backup_id:
                    raise JobFailure("job_payload_changed")
                if kind == "backup_create" and (
                    current_job.sync_epoch != epoch
                    or session.scalar(select(ServerState.instance_id)) != instance_id
                ):
                    raise JobFailure("backup_source_changed")
                if kind == "backup_create":
                    register_created_job_backup(
                        session, self.settings, job=current_job, prepared=created_prepared
                    )
                return {
                    "code": "backup_created" if kind == "backup_create" else "backup_verified",
                    "artifact_id": str(backup_id),
                    "file_count": len(manifest["files"]) + 2,
                    "bytes": manifest["database"]["size_bytes"]
                    + sum(item["size_bytes"] for item in manifest["files"])
                    + len(canonical(manifest)),
                    "sha256": hashlib.sha256(canonical(manifest)).hexdigest(),
                }

            with Session(self.engine) as session, session.begin():
                store.complete(session, lease, finish)
                self._heartbeat(session)
        except store.LeaseLost:
            # The new generation/canceller owns the row. Never overwrite it.
            pass
        except Exception as error:
            code = (
                error.code
                if isinstance(error, (JobFailure, ApiError, QuarantineExecutionError))
                else "job_execution_unavailable"
            )
            transient = (
                error.transient
                if isinstance(error, (JobFailure, QuarantineExecutionError))
                else not isinstance(error, ApiError)
            )
            try:
                with Session(self.engine) as session, session.begin():
                    store.fail(session, lease, code, transient=transient)
                    self._heartbeat(session)
            except Exception:
                # The lease will expire for a subsequent worker; no fake failure receipt.
                pass
        finally:
            stop.set()
            if renewer is not None:
                renewer.join(timeout=10)
            if created_prepared is not None:
                created_prepared.close()
            if quarantine_prepared is not None:
                quarantine_prepared.close()
        return True

    def _complete_import_stage(self, lease):
        """A fixed stage callback and its job result share the final DB fence."""
        with Session(self.engine) as session, session.begin():

            def perform(current, job):
                context = stage_work_context(current, job.id)
                if isinstance(context.intent, StageParseJob):
                    callback = parse_stage_in_transaction
                elif isinstance(context.intent, StagePreviewJob):
                    callback = preview_stage_in_transaction
                elif isinstance(context.intent, StageApplyJob):
                    callback = apply_stage_in_transaction
                elif isinstance(context.intent, StageUndoJob):
                    callback = undo_stage_in_transaction
                else:
                    raise JobFailure("job_payload_invalid")
                origin = current.get(UserSession, context.principal.session_id)
                remaining = min(
                    (job.lease_until - store.stamp(current)).total_seconds(),
                    *(
                        (value - auth_now()).total_seconds()
                        for value in (
                            origin.access_expires_at,
                            origin.expires_at,
                            origin.idle_expires_at,
                        )
                    ),
                )
                deadline = monotonic() + max(0, remaining - 5)

                def check_budget():
                    if monotonic() >= deadline:
                        raise JobFailure("import_execution_timeout", transient=True)

                return callback(current, job.id, check_budget=check_budget)

            store.complete(session, lease, perform)
            self._heartbeat(session)

    def _create_backup_manifest(
        self,
        backup_id,
        epoch,
        instance_id,
        *,
        remaining,
        before_read=None,
        job_id=None,
        owner_user_id=None,
    ):
        executable = self.settings.pg_dump_executable
        if executable is None or not executable.is_file():
            raise JobFailure("backup_tool_unavailable")
        deadline = monotonic() + max(0, remaining - 5)

        def check_budget():
            if monotonic() >= deadline:
                raise BackupError("backup_creation_timeout")

        root = self.settings.data_directory.absolute() / "backups"
        # One EX spans existence checking, creation or retry verification. The
        # trusted token prevents creation from recursively taking another lock.
        with _creation_lease(root, backup_id, check_budget=check_budget) as token:
            if before_read is not None:
                before_read(backup_id)
            provenance = None
            if job_id is not None or owner_user_id is not None:
                provenance = start_creation(
                    self.settings,
                    backup_id=backup_id,
                    job_id=job_id,
                    owner_user_id=owner_user_id,
                    instance_id=instance_id,
                    epoch=epoch,
                )
            if (root / str(backup_id)).exists():
                try:
                    manifest = verify_backup(root, backup_id, check_budget=check_budget)
                except (BackupError, OSError, ValueError):
                    # Keep partial artifacts; never overwrite a failed package.
                    raise JobFailure("backup_incomplete_retained") from None
            else:
                create_backup(
                    self.settings,
                    root,
                    pg_dump=executable,
                    backup_id=backup_id,
                    check_budget=check_budget,
                    _package_lease=token,
                )
                manifest = verify_backup(root, backup_id, check_budget=check_budget)
            if manifest["sync_epoch"] != str(epoch) or manifest["instance_id"] != str(instance_id):
                raise JobFailure("backup_source_changed")
            complete_creation(self.settings, provenance, manifest)
            check_budget()
            return manifest
