"""Quarantine submission phases; caller owns commit/rollback and finally.close.

Long file verification follows a committed read precheck. No execution job ID
is invented before store.enqueue. This facade is not mounted by this module.
"""

import hashlib
import os
from contextlib import ExitStack
from dataclasses import dataclass
from datetime import timedelta
from pathlib import Path
from time import monotonic
from uuid import UUID, uuid4

from sqlalchemy import or_, select

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.admin.service import audit, reauthenticate_admin
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import now
from flowtrace_server.configuration.models import ConfigurationHead
from flowtrace_server.configuration.runtime import read_runtime_configuration
from flowtrace_server.imports.parsers import canonical
from flowtrace_server.jobs import store
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.persistence.private_files import private_open

from . import retention
from .leases import backup_exclusive_lease, backup_read_lease
from .quarantine_schemas import QuarantineSubmission
from .retention_models import BackupControl, BackupRetentionIntent
from .retention_schemas import PackageStamp, QuarantinePayload, RetentionPreviewRecord

_TRUST = object()
KIND = "backup_quarantine"


def _error(code="backup_quarantine_submission_invalid", status=409):
    return ApiError(code, status)


def _digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def _record_hash(record):
    return _digest(record.model_dump(mode="json"))


def _request_hash(actor_id, command):
    return _digest({"actor_id": str(actor_id), "command": command.model_dump(mode="json")})


def load_quarantine_preview(settings, preview_id):
    """Pure bounded read; this private record and its audit do not grant auth."""
    if not isinstance(preview_id, UUID):
        raise _error(status=422)
    root = Path(os.path.abspath(settings.data_directory)) / "backup-retention-previews"
    try:
        with private_open(root / f"{preview_id}.json", root) as stream:
            raw = stream.read(32769)
        if len(raw) > 32768:
            raise ValueError
        record = RetentionPreviewRecord.model_validate_json(raw)
        expected = _digest([item.model_dump(mode="json") for item in record.packages])
        if record.preview_id != preview_id or record.selection_sha256 != expected:
            raise ValueError
        return record
    except Exception:
        raise _error("backup_quarantine_preview_unavailable") from None


def _command_record(principal, command, record):
    if not isinstance(command, QuarantineSubmission) or not isinstance(
        record, RetentionPreviewRecord
    ):
        raise _error(status=422)
    if (
        command.preview_id != record.preview_id
        or command.selection_sha256 != record.selection_sha256
        or principal.user_id != record.actor_id
        or principal.session_id != record.session_id
    ):
        raise _error("backup_preview_identity_changed", 403)
    stamp = now()
    if record.expires_at <= stamp or record.issued_at > stamp:
        raise _error("backup_preview_expired")


def _audit_binding(session, record):
    rows = list(
        session.scalars(
            select(AdminAudit)
            .where(
                AdminAudit.action == "backup.retention_preview",
                AdminAudit.target_id == record.preview_id,
                AdminAudit.actor_id == record.actor_id,
            )
            .limit(2)
        )
    )
    if len(rows) != 1:
        raise _error("backup_quarantine_new_preview_required")
    summary = rows[0].summary
    # Service-added auxiliary evidence, not an immutable DB authorization proof.
    # Legacy audits remain untouched and cannot authorize a new file effect.
    if (
        not isinstance(summary, dict)
        or summary.get("preview_sha256") != _record_hash(record)
        or type(summary.get("version")) is not int
        or summary["version"] != record.config_version
        or summary.get("zero_delete") is not True
    ):
        raise _error("backup_quarantine_new_preview_required")


def _source_configuration(session, record, *, lock=False):
    if lock:
        version = session.scalar(
            select(ConfigurationHead.current_version)
            .where(ConfigurationHead.id == 1)
            .with_for_update(read=True)
        )
        if version != record.config_version:
            raise _error("backup_configuration_changed")
    runtime = read_runtime_configuration(session)
    if (
        runtime.version != record.config_version
        or runtime.values.backup_retention_days != record.retention_days
        or record.cutoff > now() - timedelta(days=record.retention_days)
    ):
        raise _error("backup_configuration_changed")
    source = retention._source(session)
    if source != (record.source_instance_id, record.source_epoch):
        raise _error("backup_source_changed")
    return source


def _selection(session, record, witness=None, *, lock=False):
    source = _source_configuration(session, record, lock=lock)
    newest = retention._newest(session, source)
    selected = {item.backup_id: item for item in record.packages}
    if (
        newest is None
        or newest in selected
        or (witness is not None and newest != witness.backup_id)
    ):
        raise _error("backup_recovery_point_unavailable")
    expected = {**selected}
    if witness is not None:
        expected[witness.backup_id] = witness
    controls = {}
    for identifier in sorted((*selected, newest), key=str):
        if lock:
            row = retention._control(session, identifier)
        else:
            row = session.get(BackupControl, identifier, populate_existing=True)
        if row is None or row.state != "available" or (row.instance_id, row.sync_epoch) != source:
            raise _error("backup_control_conflict")
        if identifier in expected and (
            row.version != expected[identifier].control_version
            or not retention._same_package(retention._stamp(row), expected[identifier])
        ):
            raise _error("backup_package_changed")
        if identifier in selected and retention._reasons(
            session, row, source=source, cutoff=record.cutoff, newest=newest
        ):
            raise _error("backup_selection_protected")
        controls[identifier] = row
    return retention._stamp(controls[newest]), controls


@dataclass(frozen=True)
class QuarantineAuthority:
    record: RetentionPreviewRecord
    witness: PackageStamp
    request_hash: str
    settings_key: str
    trust: object


def precheck_quarantine_submission(session, principal, settings, *, command, record, password):
    """Read-only current precheck. Caller must commit before prepare waits/I/O."""
    retention._readonly(session, principal, password)
    _command_record(principal, command, record)
    _audit_binding(session, record)
    witness, _ = _selection(session, record)
    return QuarantineAuthority(
        record,
        witness,
        _request_hash(principal.user_id, command),
        retention._settings_key(settings),
        _TRUST,
    )


@dataclass
class _LeaseState:
    active: bool = True


@dataclass(frozen=True)
class _Binding:
    record_sha256: str
    witness_sha256: str
    request_hash: str
    settings_key: str
    lock_ids: tuple[UUID, ...]
    guard_identity: int
    state: _LeaseState


@dataclass
class PreparedQuarantineSubmission:
    authority: QuarantineAuthority
    guard: ExitStack
    binding: _Binding
    closed: bool = False

    def close(self):
        if not self.closed:
            self.closed = True
            self.guard.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def prepare_quarantine_submission(settings, *, authority, check_budget=None):
    """Pure verification, no execution plan or invented job ID is persisted."""
    if (
        not isinstance(authority, QuarantineAuthority)
        or authority.trust is not _TRUST
        or authority.settings_key != retention._settings_key(settings)
    ):
        raise _error(status=422)
    record, witness = authority.record, authority.witness
    expected = {item.backup_id: item for item in record.packages}
    if witness.backup_id in expected or (witness.instance_id, witness.sync_epoch) != (
        record.source_instance_id,
        record.source_epoch,
    ):
        raise _error(status=422)
    guard, state = ExitStack(), _LeaseState()
    guard.callback(setattr, state, "active", False)
    try:
        deadline = monotonic() + 2
        lock_ids = tuple(sorted((*expected, witness.backup_id), key=str))
        for identifier in lock_ids:
            remaining = max(0, deadline - monotonic())
            if identifier == witness.backup_id:
                guard.enter_context(
                    backup_read_lease(
                        settings, identifier, timeout_seconds=remaining, check_budget=check_budget
                    )
                )
            else:
                guard.enter_context(
                    backup_exclusive_lease(
                        settings,
                        (identifier,),
                        timeout_seconds=remaining,
                        check_budget=check_budget,
                    )
                )
        for item in (*record.packages, witness):
            actual = retention._verify_stamp(settings, item.backup_id, check_budget=check_budget)
            if not retention._same_package(actual, item):
                raise _error("backup_package_changed")
        binding = _Binding(
            _record_hash(record),
            _digest(witness.model_dump(mode="json")),
            authority.request_hash,
            authority.settings_key,
            lock_ids,
            id(guard),
            state,
        )
        return PreparedQuarantineSubmission(authority, guard, binding)
    except BaseException:
        guard.close()
        raise


def _prepared_record(settings, prepared, principal, command):
    try:
        authority, binding = prepared.authority, prepared.binding
        expected = tuple(
            sorted(
                (
                    *[item.backup_id for item in authority.record.packages],
                    authority.witness.backup_id,
                ),
                key=str,
            )
        )
        valid = (
            isinstance(prepared, PreparedQuarantineSubmission)
            and not prepared.closed
            and isinstance(authority, QuarantineAuthority)
            and authority.trust is _TRUST
            and isinstance(binding, _Binding)
            and binding.state.active
            and binding.guard_identity == id(prepared.guard)
            and binding.lock_ids == expected
            and binding.settings_key == authority.settings_key == retention._settings_key(settings)
            and binding.record_sha256 == _record_hash(authority.record)
            and binding.witness_sha256 == _digest(authority.witness.model_dump(mode="json"))
            and binding.request_hash
            == authority.request_hash
            == _request_hash(principal.user_id, command)
        )
    except Exception:
        valid = False
    if not valid:
        raise _error(status=422)
    _command_record(principal, command, authority.record)
    return authority.record


def _existing_submission(session, principal, command):
    if not isinstance(command, QuarantineSubmission):
        raise _error(status=422)
    matches = list(
        session.scalars(
            select(BackupRetentionIntent)
            .where(
                or_(
                    BackupRetentionIntent.request_id == command.request_id,
                    BackupRetentionIntent.preview_id == command.preview_id,
                )
            )
            .limit(3)
        )
    )
    if not matches:
        return None
    if len(matches) != 1:
        raise _error("backup_quarantine_request_conflict")
    intent = matches[0]
    if (
        intent.actor_id != principal.user_id
        or intent.request_id != command.request_id
        or intent.preview_id != command.preview_id
        or intent.selection_sha256 != command.selection_sha256
        or intent.request_hash != _request_hash(principal.user_id, command)
    ):
        raise _error("backup_quarantine_request_conflict")
    job = session.scalar(
        select(BackgroundJob)
        .where(BackgroundJob.id == intent.job_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    payload = QuarantinePayload(intent_id=intent.id, selection_sha256=intent.selection_sha256)
    if (
        job is None
        or job.kind != KIND
        or job.owner_user_id != principal.user_id
        or job.sync_epoch != intent.source_epoch
        or job.payload != payload.model_dump(mode="json")
        or job.payload_hash != store._payload(job.payload)[1]
    ):
        raise _error("backup_quarantine_request_conflict")
    return store.metadata(job)


def replay_quarantine_submission(session, principal, *, command, password):
    """Fresh auth, metadata only, before old preview TTL/epoch lookup; no effects."""
    reauthenticate_admin(session, principal, password, capability="recovery")
    return _existing_submission(session, principal, command)


def enqueue_quarantine_submission(session, principal, settings, *, prepared, command, password):
    """Requires root's separately published kind/DDL. Caller commits or rolls back.

    The actual new job precedes config/control locks; selected reservations and
    the immutable intent share its transaction. Prepared EX/SH stays held until
    the caller's final commit/finally, including any failed enqueue rollback.
    """
    reauthenticate_admin(session, principal, password, capability="recovery")
    if old := _existing_submission(session, principal, command):
        return old
    record = _prepared_record(settings, prepared, principal, command)
    _audit_binding(session, record)
    intent_id = uuid4()
    payload = QuarantinePayload(intent_id=intent_id, selection_sha256=record.selection_sha256)
    job = store.enqueue(
        session,
        kind=KIND,
        occurrence_key=f"backup_quarantine:{principal.user_id}:{command.request_id}",
        owner_user_id=principal.user_id,
        payload=payload.model_dump(mode="json"),
    )
    _, controls = _selection(session, record, prepared.authority.witness, lock=True)
    # Time can advance while waiting for job/config/control locks. These admin
    # locks are already held; recheck current session/PW and preview expiry
    # before persisting a reservation rather than trusting the earlier instant.
    reauthenticate_admin(session, principal, password, capability="recovery")
    _command_record(principal, command, record)
    intent = BackupRetentionIntent(
        id=intent_id,
        preview_id=record.preview_id,
        actor_id=principal.user_id,
        origin_session_id=principal.session_id,
        request_id=command.request_id,
        request_hash=_request_hash(principal.user_id, command),
        selection_sha256=record.selection_sha256,
        config_version=record.config_version,
        source_instance_id=record.source_instance_id,
        source_epoch=record.source_epoch,
        packages=[item.model_dump(mode="json") for item in record.packages],
        job_id=job.id,
    )
    session.add(intent)
    session.flush()
    for item in record.packages:
        row = controls[item.backup_id]
        row.state, row.intent_id = "reserved", intent.id
        retention._bump(row)
    session.flush()
    audit(
        session,
        principal.user_id,
        "backup.quarantine_enqueue",
        intent.id,
        version=record.config_version,
        packages=len(record.packages),
        bytes=sum(item.size_bytes for item in record.packages),
    )
    return store.metadata(job)
