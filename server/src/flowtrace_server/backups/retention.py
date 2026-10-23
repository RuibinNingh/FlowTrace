"""Protected backup metadata and staged, zero-delete retention previews.

Callers commit short DB phases themselves and close prepared contexts only after
that commit. Pure filesystem preparation never accepts a database Session.
No quarantine, unlink, rename, automatic registration or job handler exists here.
"""

import hashlib
import os
from contextlib import ExitStack
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from uuid import UUID, uuid4

from sqlalchemy import or_, select

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.admin.service import audit, reauthenticate_admin, require_recovery
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import User
from flowtrace_server.auth.service import PASSWORDS, assert_active_principal, now
from flowtrace_server.configuration.models import ConfigurationHead
from flowtrace_server.configuration.runtime import read_runtime_configuration
from flowtrace_server.imports.parsers import canonical
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.persistence.private_files import private_directory, private_open, regular_file

from . import administration as packages
from . import service as backups
from .leases import backup_read_lease
from .retention_models import BackupControl, BackupHold, BackupPin
from .retention_schemas import (
    MAX_PACKAGE_FILES,
    BackupCandidate,
    HoldCreateCommand,
    HoldReleaseCommand,
    PackageStamp,
    PinCreateCommand,
    PinReleaseCommand,
    RetentionPreviewRecord,
    RetentionSelection,
)

ACTIVE = ("pending", "running", "retry_wait")
TERMINAL = ("succeeded", "failed", "cancelled")
_TRUST = object()


def _error(code, status=409):
    return ApiError(code, status)


def _digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def _settings_key(settings):
    # No credentials or private root leave this internal binding.
    value = settings.database_url.get_secret_value() if settings.database_url else ""
    return _digest([os.path.normcase(os.path.abspath(settings.data_directory)), value])


@dataclass
class PreparedRegistration:
    stamp: PackageStamp
    settings_key: str
    guard: ExitStack
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


@dataclass(frozen=True)
class RetentionAuthority:
    actor_id: UUID
    session_id: UUID
    selection: RetentionSelection
    config_version: int
    retention_days: int
    instance_id: UUID
    epoch: UUID
    cutoff: datetime
    stamps: tuple[PackageStamp, ...]
    witness: PackageStamp
    trust: object


@dataclass
class PreparedRetentionPreview:
    record: RetentionPreviewRecord
    witness: PackageStamp
    settings_key: str
    guard: ExitStack
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


@dataclass(frozen=True)
class BackupReadGuard:
    registered: bool
    stamp: PackageStamp | None


def require_backup_readable(session, backup_id):
    """Trusted caller: source SH, short DB gate+commit, then I/O with SH held.

    This is no authentication or persistent hold adapter. HTTP/worker/CLI
    authority belongs to the existing caller. Legacy unknown packages stay
    readable and protected from maintenance; no automatic registration occurs.
    """
    if not isinstance(backup_id, UUID):
        raise _error("backup_input_invalid", 422)
    row = session.scalar(
        select(BackupControl)
        .where(BackupControl.backup_id == backup_id)
        .with_for_update(read=True)
        .execution_options(populate_existing=True)
    )
    if row is None:
        return BackupReadGuard(False, None)
    if row.state != "available":
        raise _error("backup_control_conflict")
    return BackupReadGuard(True, _stamp(row))


def _verify_stamp(settings, backup_id, *, check_budget=None):
    if not isinstance(backup_id, UUID):
        raise _error("backup_input_invalid", 422)
    try:
        root = packages._root(settings)
        manifest, raw, metadata = packages._manifest(root, backup_id)
        verified = backups.verify_backup(root, backup_id, check_budget=check_budget)
        if canonical(verified) != canonical(manifest) or not backups._valid_summary(
            manifest.get("database_summary")
        ):
            raise _error("backup_package_changed")
        descriptors = [manifest["database"], *manifest["files"]]
        expected = {item["path"] for item in descriptors} | {"manifest.json"}
        target = root / str(backup_id)
        actual = set()
        # The fixed package format has at most one objects directory. Even an
        # unknown empty directory is not silently treated as a complete package.
        with os.scandir(target) as entries:
            for entry in entries:
                if check_budget:
                    check_budget()
                if entry.is_symlink() or Path(entry.path).is_junction():
                    raise _error("backup_storage_unsafe")
                if entry.is_dir(follow_symlinks=False):
                    if entry.name != "objects":
                        raise _error("backup_package_changed")
                    with os.scandir(entry.path) as objects:
                        for item in objects:
                            if check_budget:
                                check_budget()
                            regular_file(Path(item.path), root)
                            actual.add(f"objects/{item.name}")
                            if len(actual) > MAX_PACKAGE_FILES:
                                raise _error("backup_too_many_files")
                else:
                    regular_file(Path(entry.path), root)
                    actual.add(entry.name)
                if len(actual) > MAX_PACKAGE_FILES:
                    raise _error("backup_too_many_files")
        if actual != expected or packages._manifest(root, backup_id)[1] != raw:
            raise _error("backup_package_changed")
        tree = sorted(
            [
                *descriptors,
                {
                    "path": "manifest.json",
                    "size_bytes": len(raw),
                    "sha256": hashlib.sha256(raw).hexdigest(),
                },
            ],
            key=lambda item: item["path"],
        )
        return PackageStamp(
            backup_id=backup_id,
            control_version=1,
            manifest_sha256=metadata["manifest_sha256"],
            tree_sha256=_digest(tree),
            size_bytes=metadata["declared_bytes"],
            file_count=metadata["file_count"],
            created_at=datetime.fromisoformat(metadata["created_at"]),
            instance_id=UUID(manifest["instance_id"]),
            sync_epoch=UUID(manifest["sync_epoch"]),
        )
    except ApiError:
        raise
    except Exception:
        raise _error("backup_package_unavailable") from None


def prepare_registration(settings, backup_id, *, check_budget=None):
    """Pure I/O; caller holds this context through registration and its commit."""
    guard = ExitStack()
    try:
        guard.enter_context(backup_read_lease(settings, backup_id, check_budget=check_budget))
        stamp = _verify_stamp(settings, backup_id, check_budget=check_budget)
        return PreparedRegistration(stamp, _settings_key(settings), guard, _TRUST)
    except BaseException:
        guard.close()
        raise


def _source(session):
    state = session.execute(
        select(ServerState.instance_id, ServerState.sync_epoch).where(ServerState.singleton_id == 1)
    ).one_or_none()
    if state is None:
        raise _error("backup_source_unavailable", 503)
    return state.instance_id, state.sync_epoch


def _stamp(record):
    return PackageStamp(
        backup_id=record.backup_id,
        control_version=record.version,
        manifest_sha256=record.manifest_sha256,
        tree_sha256=record.tree_sha256,
        size_bytes=record.size_bytes,
        file_count=record.file_count,
        created_at=record.created_at,
        instance_id=record.instance_id,
        sync_epoch=record.sync_epoch,
    )


def _same_package(left, right):
    return left.model_dump(exclude={"control_version"}) == right.model_dump(
        exclude={"control_version"}
    )


def _control(session, backup_id, expected_version=None):
    row = session.scalar(
        select(BackupControl)
        .where(BackupControl.backup_id == backup_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if row is None:
        raise _error("backup_unregistered")
    if row.state != "available" or (
        expected_version is not None and row.version != expected_version
    ):
        raise _error("backup_control_conflict")
    if (row.instance_id, row.sync_epoch) != _source(session):
        raise _error("backup_source_changed")
    return row


def _bump(control):
    control.version += 1
    control.updated_at = now()


def register_verified_backup(session, principal, settings, *, prepared, password):
    reauthenticate_admin(session, principal, password, capability="recovery")
    if (
        not isinstance(prepared, PreparedRegistration)
        or prepared.trust is not _TRUST
        or prepared.closed
        or prepared.settings_key != _settings_key(settings)
    ):
        raise _error("backup_registration_invalid", 422)
    stamp = prepared.stamp
    if (stamp.instance_id, stamp.sync_epoch) != _source(session):
        raise _error("backup_source_changed")
    row = session.scalar(
        select(BackupControl)
        .where(BackupControl.backup_id == stamp.backup_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if row is not None:
        if row.state != "available" or not _same_package(_stamp(row), stamp):
            raise _error("backup_registration_conflict")
        return _stamp(row)
    row = BackupControl(**stamp.model_dump(exclude={"control_version"}), version=1)
    session.add(row)
    session.flush()
    audit(
        session,
        principal.user_id,
        "backup.register",
        row.backup_id,
        version=1,
        files=row.file_count,
        bytes=row.size_bytes,
    )
    return _stamp(row)


def _command_hash(principal, kind, command):
    return _digest(
        {
            "actor_id": str(principal.user_id),
            "kind": kind,
            "command": command.model_dump(mode="json"),
        }
    )


def _pin_view(pin, control):
    return {
        "pin_id": str(pin.id),
        "backup_id": str(pin.backup_id),
        "version": pin.version,
        "active": pin.released_at is None,
        "control_version": control.version,
    }


def create_backup_pin(session, principal, *, command: PinCreateCommand, password):
    reauthenticate_admin(session, principal, password, capability="recovery")
    if not isinstance(command, PinCreateCommand):
        raise _error("backup_input_invalid", 422)
    hashed = _command_hash(principal, "pin_create", command)
    old = session.scalar(
        select(BackupPin)
        .execution_options(populate_existing=True)
        .where(
            or_(
                BackupPin.create_request_id == command.request_id,
                BackupPin.release_request_id == command.request_id,
            )
        )
    )
    control = _control(session, command.backup_id)
    if old is not None:
        old = session.get(BackupPin, old.id, populate_existing=True, with_for_update=True)
        if old.create_request_hash != hashed or old.created_by != principal.user_id:
            raise _error("backup_request_conflict")
        return _pin_view(old, control)
    if control.version != command.expected_control_version or session.get(
        BackupPin, command.pin_id
    ):
        raise _error("backup_control_conflict")
    row = BackupPin(
        id=command.pin_id,
        backup_id=command.backup_id,
        created_by=principal.user_id,
        create_request_id=command.request_id,
        create_request_hash=hashed,
    )
    session.add(row)
    _bump(control)
    session.flush()
    audit(
        session,
        principal.user_id,
        "backup.pin_create",
        row.id,
        base_version=command.expected_control_version,
    )
    return _pin_view(row, control)


def release_backup_pin(session, principal, *, command: PinReleaseCommand, password):
    reauthenticate_admin(session, principal, password, capability="recovery")
    if not isinstance(command, PinReleaseCommand):
        raise _error("backup_input_invalid", 422)
    backup_id = session.scalar(select(BackupPin.backup_id).where(BackupPin.id == command.pin_id))
    if backup_id is None:
        raise _error("not_found", 404)
    control = _control(session, backup_id)
    row = session.get(BackupPin, command.pin_id, populate_existing=True, with_for_update=True)
    hashed = _command_hash(principal, "pin_release", command)
    reused = session.scalar(
        select(BackupPin)
        .execution_options(populate_existing=True)
        .where(
            or_(
                BackupPin.create_request_id == command.request_id,
                BackupPin.release_request_id == command.request_id,
            )
        )
    )
    if reused is not None:
        if (
            reused.id != row.id
            or row.release_request_hash != hashed
            or row.released_by != principal.user_id
        ):
            raise _error("backup_request_conflict")
        return _pin_view(row, control)
    if (
        row.version != command.expected_pin_version
        or row.version != 1
        or control.version != command.expected_control_version
    ):
        raise _error("backup_control_conflict")
    row.version, row.released_at, row.released_by = 2, now(), principal.user_id
    row.release_request_id, row.release_request_hash = command.request_id, hashed
    _bump(control)
    session.flush()
    audit(
        session,
        principal.user_id,
        "backup.pin_release",
        row.id,
        base_version=command.expected_control_version,
    )
    return _pin_view(row, control)


def _hold_job(session, principal, command):
    if command.job_id is None:
        return None
    job = session.scalar(
        select(BackgroundJob)
        .where(BackgroundJob.id == command.job_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if (
        job is None
        or job.owner_user_id != principal.user_id
        or job.sync_epoch != _source(session)[1]
        or job.payload.get("backup_id") != str(command.backup_id)
        or job.kind not in {"backup_verify", "backup_create", "restore_rehearsal"}
        or (command.holder_kind == "restore_intent" and job.kind != "restore_rehearsal")
    ):
        raise _error("backup_hold_job_invalid")
    return job


def _audit_binding(session, principal, action, target, base_version):
    records = list(
        session.scalars(
            select(AdminAudit)
            .where(AdminAudit.action == action, AdminAudit.target_id == target)
            .execution_options(populate_existing=True)
        )
    )
    # Audit rows currently have no database immutability trigger. Their summary
    # is only supplementary binding; current role/source/control/job are rechecked.
    return (
        len(records) == 1
        and records[0].actor_id == principal.user_id
        and records[0].summary == {"base_version": base_version}
    )


def create_backup_hold(session, principal, *, command: HoldCreateCommand, password):
    reauthenticate_admin(session, principal, password, capability="recovery")
    if not isinstance(command, HoldCreateCommand):
        raise _error("backup_input_invalid", 422)
    job = _hold_job(session, principal, command)
    control = _control(session, command.backup_id)
    old = session.get(BackupHold, command.hold_id, populate_existing=True, with_for_update=True)
    if old is not None:
        if (old.backup_id, old.holder_kind, old.holder_id, old.job_id, old.owner_user_id) != (
            command.backup_id,
            command.holder_kind,
            command.holder_id,
            command.job_id,
            principal.user_id,
        ) or not _audit_binding(
            session, principal, "backup.hold_create", old.id, command.expected_control_version
        ):
            raise _error("backup_hold_conflict")
        return {"hold_id": str(old.id), "version": old.version, "control_version": control.version}
    if control.version != command.expected_control_version or (
        job and job.status not in ACTIVE and command.holder_kind != "restore_intent"
    ):
        raise _error("backup_control_conflict")
    duplicate = session.scalar(
        select(BackupHold.id).where(
            BackupHold.backup_id == command.backup_id,
            BackupHold.holder_kind == command.holder_kind,
            BackupHold.holder_id == command.holder_id,
        )
    )
    if duplicate:
        raise _error("backup_hold_conflict")
    row = BackupHold(
        id=command.hold_id,
        backup_id=command.backup_id,
        holder_kind=command.holder_kind,
        holder_id=command.holder_id,
        job_id=command.job_id,
        owner_user_id=principal.user_id,
    )
    session.add(row)
    _bump(control)
    session.flush()
    audit(
        session,
        principal.user_id,
        "backup.hold_create",
        row.id,
        base_version=command.expected_control_version,
    )
    return {"hold_id": str(row.id), "version": row.version, "control_version": control.version}


def release_backup_hold(session, principal, *, command: HoldReleaseCommand, password):
    reauthenticate_admin(session, principal, password, capability="recovery")
    if not isinstance(command, HoldReleaseCommand):
        raise _error("backup_input_invalid", 422)
    binding = session.execute(
        select(BackupHold.backup_id, BackupHold.job_id).where(BackupHold.id == command.hold_id)
    ).one_or_none()
    if binding is None:
        raise _error("not_found", 404)
    job = (
        session.scalar(
            select(BackgroundJob)
            .where(BackgroundJob.id == binding.job_id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
        if binding.job_id
        else None
    )
    control = _control(session, binding.backup_id)
    row = session.get(BackupHold, command.hold_id, populate_existing=True, with_for_update=True)
    if row.holder_kind == "restore_intent":
        raise _error("backup_restore_hold_protected")
    if command.proof != "job_terminal_verified" or row.holder_kind != "job":
        # No public string or forged archive dict can act as an I/O completion
        # proof. Download/reconcile release waits for a trusted reader adapter.
        raise _error("backup_hold_proof_unavailable")
    if (
        job is None
        or job.owner_user_id != row.owner_user_id
        or job.payload.get("backup_id") != str(row.backup_id)
        or job.status not in TERMINAL
        or job.lease_owner is not None
        or job.lease_until is not None
    ):
        raise _error("backup_hold_job_active")
    if row.version == 2:
        if (
            row.release_proof != command.proof
            or command.expected_hold_version != 1
            or not _audit_binding(
                session, principal, "backup.hold_release", row.id, command.expected_control_version
            )
        ):
            raise _error("backup_hold_conflict")
        return {"hold_id": str(row.id), "version": row.version, "control_version": control.version}
    if (
        row.version != command.expected_hold_version
        or row.version != 1
        or control.version != command.expected_control_version
    ):
        raise _error("backup_control_conflict")
    row.version, row.released_at, row.release_proof = 2, now(), command.proof
    _bump(control)
    session.flush()
    audit(
        session,
        principal.user_id,
        "backup.hold_release",
        row.id,
        base_version=command.expected_control_version,
    )
    return {"hold_id": str(row.id), "version": row.version, "control_version": control.version}


def _reasons(session, control, *, source, cutoff, newest):
    reasons = []
    if control is None:
        return ("unregistered",)
    if control.state != "available":
        reasons.append(control.state)
    if (control.instance_id, control.sync_epoch) != source:
        reasons.append("package_unavailable")
    if control.created_at >= cutoff:
        reasons.append("not_old")
    if control.backup_id == newest:
        reasons.append("last_recovery_point")
    if session.scalar(
        select(BackupPin.id)
        .where(BackupPin.backup_id == control.backup_id, BackupPin.released_at.is_(None))
        .limit(1)
    ):
        reasons.append("pinned")
    holds = list(
        session.scalars(
            select(BackupHold.holder_kind)
            .where(BackupHold.backup_id == control.backup_id, BackupHold.released_at.is_(None))
            .limit(10001)
        )
    )
    if len(holds) > 10000:
        raise _error("backup_catalog_limit", 413)
    if holds:
        reasons.append("active_hold")
    jobs = list(
        session.scalars(
            select(BackgroundJob)
            .execution_options(populate_existing=True)
            .where(
                BackgroundJob.kind.in_(("backup_create", "backup_verify", "restore_rehearsal")),
                BackgroundJob.payload["backup_id"].astext == str(control.backup_id),
                or_(BackgroundJob.status.in_(ACTIVE), BackgroundJob.kind == "restore_rehearsal"),
            )
            .limit(10001)
        )
    )
    if len(jobs) > 10000:
        raise _error("backup_catalog_limit", 413)
    if any(job.status in ACTIVE for job in jobs):
        reasons.append("active_job")
    if "restore_intent" in holds or any(job.kind == "restore_rehearsal" for job in jobs):
        reasons.append("restore_intent")
    return tuple(dict.fromkeys(reasons))


def _readonly(session, principal, password=None):
    if session.new or session.dirty or session.deleted:
        raise _error("backup_read_transaction_required")
    assert_active_principal(session, principal, lock=False)
    require_recovery(session, principal)
    if password is not None:
        user = session.get(User, principal.user_id, populate_existing=True)
        if (
            not isinstance(password, str)
            or not 12 <= len(password) <= 256
            or not PASSWORDS.verify(password, user.password_hash)
        ):
            raise _error("reauthentication_failed", 403)


def _newest(session, source):
    return session.scalar(
        select(BackupControl.backup_id)
        .where(
            BackupControl.instance_id == source[0],
            BackupControl.sync_epoch == source[1],
            BackupControl.state == "available",
        )
        .order_by(BackupControl.created_at.desc(), BackupControl.backup_id.desc())
        .limit(1)
    )


def list_retention_candidates(session, principal, settings, *, before=None):
    """Metadata eligibility means 'may prepare', never current full integrity."""
    _readonly(session, principal)
    if before is not None and not isinstance(before, UUID):
        raise _error("backup_input_invalid", 422)
    runtime = read_runtime_configuration(session)
    source, cutoff = _source(session), now() - timedelta(days=runtime.values.backup_retention_days)
    newest = _newest(session, source)
    records = list(
        session.scalars(
            select(BackupControl)
            .execution_options(populate_existing=True)
            .order_by(BackupControl.backup_id)
            .limit(10001)
        )
    )
    if len(records) > 10000:
        raise _error("backup_catalog_limit", 413)
    controls = {record.backup_id: record for record in records}
    root, identities = packages._root(settings), set(controls)
    if root.exists():
        with os.scandir(root) as entries:
            for index, entry in enumerate(entries):
                if index >= 10000:
                    raise _error("backup_catalog_limit", 413)
                try:
                    identifier = UUID(entry.name)
                    if str(identifier) == entry.name:
                        identities.add(identifier)
                except ValueError:
                    continue
    if len(identities) > 10000:
        raise _error("backup_catalog_limit", 413)
    ordered = [
        identifier
        for identifier in sorted(identities, key=str)
        if before is None or str(identifier) > str(before)
    ]
    items = []
    for identifier in ordered[:20]:
        control = controls.get(identifier)
        reasons = list(_reasons(session, control, source=source, cutoff=cutoff, newest=newest))
        if control is not None:
            try:
                with backup_read_lease(settings, identifier, timeout_seconds=0):
                    metadata = packages._manifest(root, identifier)[2]
                if metadata["manifest_sha256"] != control.manifest_sha256:
                    reasons.append("package_unavailable")
            except Exception:
                reasons.append("package_unavailable")
        items.append(
            BackupCandidate(
                backup_id=identifier,
                state=control.state if control else "unregistered",
                eligible=not reasons,
                protection_reasons=tuple(dict.fromkeys(reasons)),
                created_at=control.created_at if control else None,
                size_bytes=control.size_bytes if control else None,
                file_count=control.file_count if control else None,
            )
        )
    return {
        "items": items,
        "has_more": len(ordered) > 20,
        "next_cursor": ordered[19] if len(ordered) > 20 else None,
        "config_version": runtime.version,
        "retention_days": runtime.values.backup_retention_days,
        "metadata_only": True,
    }


def precheck_retention_request(session, principal, *, selection, password):
    """Read-only DB snapshot; caller explicitly commits before filesystem I/O."""
    if not isinstance(selection, RetentionSelection):
        raise _error("backup_input_invalid", 422)
    _readonly(session, principal, password)
    runtime, source = read_runtime_configuration(session), _source(session)
    if runtime.version != selection.expected_config_version:
        raise _error("backup_configuration_changed")
    cutoff = now() - timedelta(days=runtime.values.backup_retention_days)
    newest = _newest(session, source)
    stamps = []
    for identifier in selection.backup_ids:
        control = session.get(BackupControl, identifier, populate_existing=True)
        if _reasons(session, control, source=source, cutoff=cutoff, newest=newest):
            raise _error("backup_selection_protected")
        stamps.append(_stamp(control))
    if newest is None or newest in selection.backup_ids:
        raise _error("backup_recovery_point_unavailable")
    witness = _stamp(session.get(BackupControl, newest, populate_existing=True))
    return RetentionAuthority(
        principal.user_id,
        principal.session_id,
        selection,
        runtime.version,
        runtime.values.backup_retention_days,
        *source,
        cutoff,
        tuple(stamps),
        witness,
        _TRUST,
    )


def build_retention_preview(settings, *, authority, check_budget=None):
    if not isinstance(authority, RetentionAuthority) or authority.trust is not _TRUST:
        raise _error("backup_preview_invalid", 422)
    guard = ExitStack()
    try:
        expected = {stamp.backup_id: stamp for stamp in (*authority.stamps, authority.witness)}
        actual = {}
        for identifier in sorted(expected, key=str):
            guard.enter_context(backup_read_lease(settings, identifier, check_budget=check_budget))
            actual[identifier] = _verify_stamp(settings, identifier, check_budget=check_budget)
            if not _same_package(actual[identifier], expected[identifier]):
                raise _error("backup_package_changed")
        issued = now()
        record = RetentionPreviewRecord(
            preview_id=uuid4(),
            actor_id=authority.actor_id,
            session_id=authority.session_id,
            request_id=authority.selection.request_id,
            config_version=authority.config_version,
            source_instance_id=authority.instance_id,
            source_epoch=authority.epoch,
            retention_days=authority.retention_days,
            cutoff=authority.cutoff,
            packages=authority.stamps,
            selection_sha256=_digest([stamp.model_dump(mode="json") for stamp in authority.stamps]),
            issued_at=issued,
            expires_at=issued + timedelta(seconds=300),
        )
        root = private_directory(
            Path(os.path.abspath(settings.data_directory)) / "backup-retention-previews"
        )
        raw = record.model_dump_json().encode()
        if len(raw) > 32768:
            raise _error("backup_preview_too_large", 413)
        with private_open(root / f"{record.preview_id}.json", root, create=True) as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        return PreparedRetentionPreview(
            record, authority.witness, _settings_key(settings), guard, _TRUST
        )
    except BaseException:
        guard.close()
        raise


def authorize_retention_preview(session, principal, settings, *, prepared, password):
    reauthenticate_admin(session, principal, password, capability="recovery")
    if (
        not isinstance(prepared, PreparedRetentionPreview)
        or prepared.trust is not _TRUST
        or prepared.closed
        or prepared.settings_key != _settings_key(settings)
    ):
        raise _error("backup_preview_invalid", 422)
    record = prepared.record
    if record.actor_id != principal.user_id or record.session_id != principal.session_id:
        raise _error("backup_preview_identity_changed", 403)
    if record.expires_at <= now():
        raise _error("backup_preview_expired")
    version = session.scalar(
        select(ConfigurationHead.current_version)
        .where(ConfigurationHead.id == 1)
        .with_for_update(read=True)
    )
    if version != record.config_version:
        raise _error("backup_configuration_changed")
    source = _source(session)
    if source != (record.source_instance_id, record.source_epoch):
        raise _error("backup_source_changed")
    newest = _newest(session, source)
    stamps = {stamp.backup_id: stamp for stamp in (*record.packages, prepared.witness)}
    for identifier in sorted(stamps, key=str):
        row = _control(session, identifier, stamps[identifier].control_version)
        if not _same_package(_stamp(row), stamps[identifier]):
            raise _error("backup_package_changed")
        if identifier != prepared.witness.backup_id and _reasons(
            session, row, source=source, cutoff=record.cutoff, newest=newest
        ):
            raise _error("backup_selection_protected")
    old = session.scalar(
        select(AdminAudit.id).where(
            AdminAudit.action == "backup.retention_preview",
            AdminAudit.target_id == record.preview_id,
        )
    )
    if old is None:
        audit(
            session,
            principal.user_id,
            "backup.retention_preview",
            record.preview_id,
            version=record.config_version,
            packages=len(record.packages),
            bytes=sum(stamp.size_bytes for stamp in record.packages),
            zero_delete=True,
            preview_sha256=_digest(record.model_dump(mode="json")),
        )
    return record
