"""Trusted fixed-job references, without an invented admin or password.

The caller owns authority/transaction boundaries. Lock order is deployment
state, actor/owner, actual job, then backup control. This module performs no
package I/O while holding DB rows. Prepared creation verification retains SH
through the worker's final completion commit. Unknown old packages stay unknown.
"""

import hashlib
import os
import re
from contextlib import ExitStack
from dataclasses import dataclass
from typing import Literal
from uuid import UUID, uuid4

from pydantic import BaseModel, ConfigDict, ValidationError
from sqlalchemy import select

from flowtrace_server.admin.service import audit
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import User
from flowtrace_server.auth.service import roles_for
from flowtrace_server.imports.parsers import canonical, decode_json
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.persistence.private_files import private_directory, private_open

from . import retention
from .leases import backup_read_lease
from .rehearsal_schemas import RestoreRehearsalPayload
from .retention_models import BackupControl, BackupHold
from .service import verify_backup

_TRUST = object()
_ACTIVE = {"pending", "running", "retry_wait"}
_KINDS = {"backup_create", "backup_verify", "restore_rehearsal"}
_MAX_JOURNAL_BYTES = 4096


def _error(code):
    return ApiError(code, 409)


def _backup_id(job):
    try:
        if job.kind == "restore_rehearsal":
            parsed = RestoreRehearsalPayload.model_validate_json(canonical(job.payload))
            if parsed.model_dump(mode="json") != job.payload:
                raise ValueError
            return parsed.backup_id
        if not isinstance(job.payload, dict) or set(job.payload) != {"backup_id"}:
            raise ValueError
        identifier = UUID(job.payload["backup_id"])
        if str(identifier) != job.payload["backup_id"]:
            raise ValueError
        return identifier
    except (ValidationError, ValueError, TypeError, KeyError, AttributeError):
        raise _error("backup_reference_job_invalid") from None


def _job(session, job_id):
    if not isinstance(job_id, UUID):
        raise _error("backup_reference_job_invalid")
    job = session.scalar(
        select(BackgroundJob).where(BackgroundJob.id == job_id).with_for_update()
        .execution_options(populate_existing=True)
    )
    if (
        job is None or job.kind not in _KINDS
        or job.sync_epoch != retention._source(session)[1]
        or session.scalar(select(User.enabled).where(User.id == job.owner_user_id)) is not True
        or "recovery_admin" not in roles_for(session, job.owner_user_id)
    ):
        raise _error("backup_reference_job_invalid")
    return job, _backup_id(job)


def _control(session, backup_id):
    row = session.scalar(
        select(BackupControl).where(BackupControl.backup_id == backup_id).with_for_update()
        .execution_options(populate_existing=True)
    )
    if row is not None and row.state != "available":
        raise _error("backup_control_conflict")
    return row


def _hold(session, job, backup_id):
    kind = "restore_intent" if job.kind == "restore_rehearsal" else "job"
    row = session.scalar(
        select(BackupHold).where(
            BackupHold.backup_id == backup_id, BackupHold.holder_kind == kind,
            BackupHold.holder_id == job.id,
        ).with_for_update().execution_options(populate_existing=True)
    )
    if row is not None:
        if row.job_id != job.id or row.owner_user_id != job.owner_user_id:
            raise _error("backup_reference_job_invalid")
        if row.version != 1 or row.released_at is not None:
            raise _error("backup_reference_released")
    return kind, row


@dataclass(frozen=True)
class JobBackupReference:
    registered: bool
    hold_id: UUID | None
    control_version: int | None


def retain_job_backup(session, job_id, *, for_retry=False):
    """Same enqueue/retry transaction; no automatic registration or release.

    A terminal exact replay only returns its existing reference. A historical
    terminal job with no hold is not turned into a new active operation.
    """
    job, backup_id = _job(session, job_id)
    control = _control(session, backup_id)
    if control is None:
        return JobBackupReference(False, None, None)
    kind, hold = _hold(session, job, backup_id)
    if hold is not None:
        return JobBackupReference(True, hold.id, control.version)
    if job.status not in _ACTIVE and not for_retry and kind != "restore_intent":
        return JobBackupReference(True, None, control.version)
    if for_retry and job.status not in {"failed", "retry_wait"}:
        raise _error("job_not_retryable")
    hold = BackupHold(
        id=uuid4(), backup_id=backup_id, holder_kind=kind, holder_id=job.id,
        job_id=job.id, owner_user_id=job.owner_user_id,
    )
    session.add(hold)
    base = control.version
    retention._bump(control)
    session.flush()
    audit(session, job.owner_user_id, "backup.job_reference", hold.id, base_version=base)
    return JobBackupReference(True, hold.id, control.version)


def require_job_reference(session, job_id, backup_id):
    """Reject released references even if a trusted old caller retried a job.

    Legacy pending jobs lacking a hold stay protected by actual job inspection;
    all new registered enqueue paths call retain_job_backup in their transaction.
    """
    job, actual = _job(session, job_id)
    if actual != backup_id or job.status != "running":
        raise _error("backup_reference_job_invalid")
    control = _control(session, backup_id)
    if control is not None:
        _hold(session, job, backup_id)
    return control is not None


class _Journal(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True, hide_input_in_errors=True)
    format: Literal["flowtrace-backup-job-creation-v1"] = "flowtrace-backup-job-creation-v1"
    backup_id: UUID
    job_id: UUID
    owner_user_id: UUID
    instance_id: UUID
    sync_epoch: UUID
    nonce: UUID


class _Completion(_Journal):
    manifest_sha256: str


def _journal_root(settings, backup_id):
    root = private_directory(settings.data_directory.absolute() / "backup-controls")
    return private_directory(root / str(backup_id))


def _read(path, root, model):
    try:
        with private_open(path, root) as stream:
            raw = stream.read(_MAX_JOURNAL_BYTES + 1)
        if len(raw) > _MAX_JOURNAL_BYTES:
            raise ValueError
        parsed = model.model_validate_json(canonical(decode_json(raw)))
        if isinstance(parsed, _Completion) and (
            len(parsed.manifest_sha256) != 64
            or any(ch not in "0123456789abcdef" for ch in parsed.manifest_sha256)
        ):
            raise ValueError
        return parsed
    except FileNotFoundError:
        return None
    except Exception:
        raise _error("backup_creation_proof_invalid") from None


def _write(path, root, value):
    raw = canonical(value.model_dump(mode="json"))
    if len(raw) > _MAX_JOURNAL_BYTES:
        raise _error("backup_creation_proof_invalid")
    with private_open(path, root, create=True) as output:
        output.write(raw)
        output.flush()
        os.fsync(output.fileno())


def start_creation(settings, *, backup_id, job_id, owner_user_id, instance_id, epoch):
    """Trusted worker with EX; only a missing package may start provenance."""
    if any(not isinstance(value, UUID) for value in (
        backup_id, job_id, owner_user_id, instance_id, epoch
    )):
        raise _error("backup_creation_proof_invalid")
    root = _journal_root(settings, backup_id)
    start = _read(root / "creation-start.json", root, _Journal)
    complete = _read(root / "creation-complete.json", root, _Completion)
    if start is None:
        if complete is not None:
            raise _error("backup_creation_proof_invalid")
        target = settings.data_directory.absolute() / "backups" / str(backup_id)
        if target.exists() or target.is_symlink() or target.is_junction():
            return None  # Older unknown package: verify, never auto-adopt.
        start = _Journal(
            backup_id=backup_id, job_id=job_id, owner_user_id=owner_user_id,
            instance_id=instance_id, sync_epoch=epoch, nonce=uuid4(),
        )
        _write(root / "creation-start.json", root, start)
    expected = (backup_id, job_id, owner_user_id, instance_id, epoch)
    actual = (
        start.backup_id, start.job_id, start.owner_user_id, start.instance_id, start.sync_epoch
    )
    if actual != expected:
        raise _error("backup_creation_proof_conflict")
    if complete is not None and complete.model_dump(exclude={"manifest_sha256"}) != (
        start.model_dump()
    ):
        raise _error("backup_creation_proof_conflict")
    return start


def complete_creation(settings, start, manifest):
    """EX + freshly verified complete package, including crash-window recovery."""
    if start is None:
        return
    if type(start) is not _Journal or not isinstance(manifest, dict) or (
        manifest.get("backup_id"), manifest.get("instance_id"), manifest.get("sync_epoch")
    ) != (str(start.backup_id), str(start.instance_id), str(start.sync_epoch)):
        raise _error("backup_creation_proof_conflict")
    root = _journal_root(settings, start.backup_id)
    saved = _read(root / "creation-start.json", root, _Journal)
    if saved != start:
        raise _error("backup_creation_proof_conflict")
    value = _Completion(
        **start.model_dump(), manifest_sha256=hashlib.sha256(canonical(manifest)).hexdigest()
    )
    existing = _read(root / "creation-complete.json", root, _Completion)
    if existing is not None:
        if existing != value:
            raise _error("backup_creation_proof_conflict")
        return
    _write(root / "creation-complete.json", root, value)


@dataclass(repr=False)
class PreparedCreatedBackup:
    package: retention.PreparedRegistration | None
    completion: _Completion | None
    guard: ExitStack
    settings_key: str
    backup_id: UUID
    instance_id: UUID
    sync_epoch: UUID
    manifest_sha256: str
    job_id: UUID
    owner_user_id: UUID
    trust: object
    closed: bool = False

    def close(self):
        if not self.closed:
            self.closed = True
            self.guard.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def prepare_created_backup(
    settings, *, backup_id, job_id, owner_user_id, manifest_sha256, check_budget=None
):
    if (
        any(not isinstance(value, UUID) for value in (backup_id, job_id, owner_user_id))
        or not isinstance(manifest_sha256, str)
        or not re.fullmatch(r"[0-9a-f]{64}", manifest_sha256)
    ):
        raise _error("backup_creation_proof_invalid")
    guard = ExitStack()
    try:
        guard.enter_context(backup_read_lease(settings, backup_id, check_budget=check_budget))
        root = _journal_root(settings, backup_id)
        start = _read(root / "creation-start.json", root, _Journal)
        complete = _read(root / "creation-complete.json", root, _Completion)
        if (start is None) != (complete is None):
            raise _error("backup_creation_proof_invalid")
        package = None
        if complete is None:
            # Keep the original reader contract for unclaimed old packages:
            # no new mandatory database_summary or exact directory inventory.
            manifest = verify_backup(
                settings.data_directory.absolute() / "backups", backup_id,
                check_budget=check_budget,
            )
            if hashlib.sha256(canonical(manifest)).hexdigest() != manifest_sha256:
                raise _error("backup_package_changed")
            try:
                instance_id, sync_epoch = (
                    UUID(manifest["instance_id"]), UUID(manifest["sync_epoch"])
                )
            except (ValueError, TypeError, KeyError, AttributeError):
                raise _error("backup_creation_proof_invalid") from None
        else:
            package = guard.enter_context(
                retention.prepare_registration(settings, backup_id, check_budget=check_budget)
            )
            stamp = package.stamp
            if stamp.manifest_sha256 != manifest_sha256:
                raise _error("backup_package_changed")
            instance_id, sync_epoch = stamp.instance_id, stamp.sync_epoch
        if complete is not None and (
            complete.model_dump(exclude={"manifest_sha256"}) != start.model_dump()
            or (complete.backup_id, complete.job_id, complete.owner_user_id) != (
                backup_id, job_id, owner_user_id
            )
            or (complete.instance_id, complete.sync_epoch, complete.manifest_sha256) != (
                instance_id, sync_epoch, manifest_sha256
            )
        ):
            raise _error("backup_creation_proof_conflict")
        return PreparedCreatedBackup(
            package, complete, guard, retention._settings_key(settings), backup_id,
            instance_id, sync_epoch, manifest_sha256, job_id, owner_user_id, _TRUST,
        )
    except BaseException:
        guard.close()
        raise


def register_created_job_backup(session, settings, *, job, prepared):
    """Inside store.complete, with no file reads, auth impersonation or commit."""
    if (
        not isinstance(prepared, PreparedCreatedBackup) or prepared.trust is not _TRUST
        or prepared.closed or prepared.settings_key != retention._settings_key(settings)
        or (prepared.job_id, prepared.owner_user_id) != (job.id, job.owner_user_id)
    ):
        raise _error("backup_registration_invalid")
    actual, backup_id = _job(session, job.id)
    if (
        actual.kind != "backup_create" or actual.status != "running"
        or actual.owner_user_id != prepared.owner_user_id
        or backup_id != prepared.backup_id
        or (prepared.instance_id, prepared.sync_epoch) != retention._source(session)
    ):
        raise _error("backup_source_changed")
    if prepared.completion is None:
        # A complete legacy artifact may satisfy its old job, but cannot become
        # a cleanup candidate simply because a new worker can read it.
        return False
    if (
        not isinstance(prepared.package, retention.PreparedRegistration)
        or prepared.package.closed or prepared.package.trust is not retention._TRUST
        or prepared.package.settings_key != prepared.settings_key
        or prepared.package.stamp.manifest_sha256 != prepared.manifest_sha256
        or prepared.package.stamp.backup_id != prepared.backup_id
    ):
        raise _error("backup_registration_invalid")
    stamp = prepared.package.stamp
    row = _control(session, backup_id)
    if row is not None:
        if not retention._same_package(retention._stamp(row), stamp):
            raise _error("backup_registration_conflict")
    else:
        row = BackupControl(**stamp.model_dump(exclude={"control_version"}), version=1)
        session.add(row)
        session.flush()
        audit(session, job.owner_user_id, "backup.worker_register", backup_id, version=1)
    retain_job_backup(session, job.id)
    return True
