"""Trusted quarantine execution facade for the worker's fenced lifecycle.

Caller lifecycle: prepare -> try run/complete (or current-lease fail) -> commit
-> finally close. Long file work owns EX/SH but never a database transaction.
The original management session must remain active; this worker does not renew
it, construct an administrator principal or re-use a password elevation.
"""

import hashlib
from dataclasses import dataclass
from datetime import timedelta
from time import monotonic
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session

from flowtrace_server.admin.service import audit
from flowtrace_server.auth.models import User, UserSession
from flowtrace_server.auth.service import roles_for
from flowtrace_server.configuration.models import ConfigurationHead
from flowtrace_server.configuration.runtime import read_runtime_configuration
from flowtrace_server.imports.parsers import canonical
from flowtrace_server.jobs import store
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.persistence.models import ServerState

from . import quarantine, retention
from .leases import BackupLeaseError
from .quarantine_schemas import QuarantinePlan, QuarantineSubmission
from .quarantine_submission import _request_hash
from .retention_models import BackupControl, BackupRetentionIntent
from .retention_schemas import PackageStamp, QuarantinePayload

_TRUST = object()
KIND = "backup_quarantine"


class QuarantineExecutionError(RuntimeError):
    def __init__(self, code="backup_quarantine_execution_invalid", *, transient=False):
        super().__init__(code)
        self.code, self.transient = code, transient


def _digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def _payload(job):
    try:
        parsed = QuarantinePayload.model_validate_json(canonical(job.payload))
        if (
            parsed.model_dump(mode="json") != job.payload
            or store._payload(job.payload)[1] != job.payload_hash
        ):
            raise ValueError
        return parsed
    except Exception:
        raise QuarantineExecutionError("job_payload_invalid") from None


def _plan(intent, job):
    try:
        command = QuarantineSubmission(
            preview_id=intent.preview_id,
            request_id=intent.request_id,
            selection_sha256=intent.selection_sha256,
        )
        if (
            intent.job_id != job.id
            or intent.actor_id != job.owner_user_id
            or intent.request_hash != _request_hash(intent.actor_id, command)
            or job.occurrence_key != f"backup_quarantine:{intent.actor_id}:{intent.request_id}"
            or job.scope_id is not None
            or job.rule_revision is not None
        ):
            raise ValueError
        packages = tuple(
            PackageStamp.model_validate_json(canonical(item)) for item in intent.packages
        )
        return QuarantinePlan(
            intent_id=intent.id,
            job_id=job.id,
            actor_id=job.owner_user_id,
            source_instance_id=intent.source_instance_id,
            source_epoch=intent.source_epoch,
            config_version=intent.config_version,
            selection_sha256=intent.selection_sha256,
            packages=packages,
        )
    except Exception:
        raise QuarantineExecutionError("backup_quarantine_intent_changed") from None


def _origin_deadline(origin, owner_id, current):
    if (
        origin is None
        or origin.user_id != owner_id
        or origin.purpose != "admin"
        or origin.revoked_at is not None
    ):
        raise QuarantineExecutionError("backup_quarantine_origin_inactive")
    deadline = min(origin.expires_at, origin.access_expires_at, origin.idle_expires_at)
    if deadline <= current:
        raise QuarantineExecutionError("backup_quarantine_origin_inactive")
    return deadline


@dataclass(frozen=True)
class ExecutionAuthority:
    lease: store.JobLease
    plan: QuarantinePlan
    witness: PackageStamp
    origin_session_id: UUID
    settings_key: str
    remaining_seconds: float


def _read_authority(session, settings, lease, *, expected=None):
    """Short canonical locks: State -> User -> origin Session -> job -> config/controls."""
    if not isinstance(lease, store.JobLease):
        raise QuarantineExecutionError()
    peek = session.get(BackgroundJob, lease.job_id, populate_existing=True)
    if peek is None or peek.kind != KIND:
        raise QuarantineExecutionError("job_payload_invalid")
    initial_payload = _payload(peek)
    intent = session.get(BackupRetentionIntent, initial_payload.intent_id, populate_existing=True)
    if intent is None:
        raise QuarantineExecutionError("backup_quarantine_intent_changed")
    owner_id, origin_id = peek.owner_user_id, intent.origin_session_id

    epoch = store._epoch(session, lock=True)
    owner = session.scalar(
        select(User)
        .where(User.id == owner_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if owner is None or not owner.enabled:
        raise QuarantineExecutionError("job_owner_changed")
    origin = session.scalar(
        select(UserSession)
        .where(UserSession.id == origin_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    current = store.stamp(session)
    _origin_deadline(origin, owner_id, current)
    if "recovery_admin" not in roles_for(session, owner_id):
        raise QuarantineExecutionError("job_permission_changed")
    job = store.leased_job(session, lease)
    payload = _payload(job)
    intent = session.get(BackupRetentionIntent, payload.intent_id, populate_existing=True)
    if (
        job.kind != KIND
        or job.owner_user_id != owner_id
        or payload != initial_payload
        or intent is None
        or intent.origin_session_id != origin_id
        or payload.selection_sha256 != intent.selection_sha256
    ):
        raise QuarantineExecutionError("backup_quarantine_intent_changed")
    plan = _plan(intent, job)
    instance = session.scalar(select(ServerState.instance_id).where(ServerState.singleton_id == 1))
    if plan.source_instance_id != instance or plan.source_epoch != epoch or job.sync_epoch != epoch:
        raise QuarantineExecutionError("backup_source_changed")
    version = session.scalar(
        select(ConfigurationHead.current_version)
        .where(ConfigurationHead.id == 1)
        .with_for_update(read=True)
    )
    runtime = read_runtime_configuration(session)
    if version != plan.config_version or runtime.version != plan.config_version:
        raise QuarantineExecutionError("backup_configuration_changed")
    if expected is not None and (
        expected.lease != lease
        or expected.plan != plan
        or expected.origin_session_id != origin_id
        or expected.settings_key != retention._settings_key(settings)
    ):
        raise QuarantineExecutionError("backup_quarantine_binding_changed")

    selected = {item.backup_id: item for item in plan.packages}
    source = (instance, epoch)
    # Later callbacks retain the actually locked, freshly verified witness.
    # A newer recovery point does not silently replace its SH/hash identity.
    witness_id = (
        expected.witness.backup_id if expected is not None else retention._newest(session, source)
    )
    if witness_id is None or witness_id in selected:
        raise QuarantineExecutionError("backup_recovery_point_unavailable")
    controls = {}
    for identifier in sorted((*selected, witness_id), key=str):
        row = session.scalar(
            select(BackupControl)
            .where(BackupControl.backup_id == identifier)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
        if row is None or (row.instance_id, row.sync_epoch) != source:
            raise QuarantineExecutionError("backup_control_conflict")
        if identifier in selected:
            original = selected[identifier]
            if (
                row.state != "reserved"
                or row.intent_id != plan.intent_id
                or row.version != original.control_version + 1
                or not retention._same_package(retention._stamp(row), original)
            ):
                raise QuarantineExecutionError("backup_control_conflict")
            reasons = retention._reasons(
                session,
                row,
                source=source,
                cutoff=current - timedelta(days=runtime.values.backup_retention_days),
                newest=witness_id,
            )
            if any(reason != "reserved" for reason in reasons):
                raise QuarantineExecutionError("backup_selection_protected")
        elif row.state != "available" or row.intent_id is not None:
            raise QuarantineExecutionError("backup_recovery_point_unavailable")
        controls[identifier] = row
    witness = retention._stamp(controls[witness_id])
    if expected is not None:
        if not retention._same_package(witness, expected.witness):
            raise QuarantineExecutionError("backup_package_changed")
        witness = expected.witness
    # Holding origin fields stable does not stop wall time while controls wait.
    current = store.stamp(session)
    origin_deadline = _origin_deadline(origin, owner_id, current)
    remaining = (min(job.lease_until, origin_deadline) - current).total_seconds()
    if remaining <= 5:
        raise QuarantineExecutionError("backup_quarantine_budget_exhausted")
    return ExecutionAuthority(
        lease, plan, witness, origin_id, retention._settings_key(settings), remaining
    ), controls


@dataclass
class _ExecutionState:
    started: bool = False
    completion: "_Completion | None" = None


@dataclass(frozen=True)
class _Completion:
    result: quarantine.QuarantineResult
    sha256: str
    authority_sha256: str
    io_identity: int
    guard_identity: int
    trust: object


@dataclass(frozen=True)
class _Binding:
    authority_sha256: str
    io_identity: int
    guard_identity: int
    state_identity: int
    trust: object


@dataclass(frozen=True)
class PreparedQuarantineExecution:
    engine: object
    settings: object
    authority: ExecutionAuthority
    io: quarantine.PreparedQuarantine
    deadline: float
    _state: _ExecutionState
    _binding: _Binding

    @property
    def closed(self):
        return self.io.closed

    @property
    def result(self):
        return self._state.completion.result if self._state.completion is not None else None

    def close(self):
        self.io.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def _authority_hash(authority):
    return _digest(
        {
            "lease": [
                str(authority.lease.job_id),
                str(authority.lease.worker_id),
                authority.lease.generation,
            ],
            "plan": authority.plan.model_dump(mode="json"),
            "witness": authority.witness.model_dump(mode="json"),
            "origin": str(authority.origin_session_id),
            "settings_key": authority.settings_key,
        }
    )


def _result_hash(result):
    return _digest(
        {
            "intent_id": str(result.intent_id),
            "sha256": result.sha256,
            "receipts": [item.model_dump(mode="json") for item in result.receipts],
        }
    )


def _valid_handle(prepared, settings=None, lease=None):
    try:
        binding, authority = prepared._binding, prepared.authority
        valid = (
            isinstance(prepared, PreparedQuarantineExecution)
            and isinstance(binding, _Binding)
            and binding.trust is _TRUST
            and binding.authority_sha256 == _authority_hash(authority)
            and binding.io_identity == id(prepared.io)
            and binding.guard_identity == id(prepared.io.guard)
            and binding.state_identity == id(prepared._state)
            and quarantine._binding_matches(prepared.io)
            and not prepared.io.closed
            and prepared.io.plan == authority.plan
            and prepared.io.witness == authority.witness
            and retention._settings_key(prepared.settings) == authority.settings_key
            and (settings is None or retention._settings_key(settings) == authority.settings_key)
            and (lease is None or lease == authority.lease)
        )
    except Exception:
        valid = False
    if not valid:
        raise QuarantineExecutionError("backup_quarantine_binding_changed")


def _budget(prepared):
    if monotonic() >= prepared.deadline:
        raise QuarantineExecutionError("backup_quarantine_budget_exhausted")


def prepare_quarantine_execution(engine, settings, lease):
    """No rename. On success caller owns this handle until commit/finally."""
    with Session(engine) as session, session.begin():
        authority, _ = _read_authority(session, settings, lease)
    deadline = monotonic() + min(900, authority.remaining_seconds) - 5

    def budget():
        if monotonic() >= deadline:
            raise QuarantineExecutionError("backup_quarantine_budget_exhausted")

    try:
        io = quarantine.prepare_quarantine(
            settings, plan=authority.plan, witness=authority.witness, check_budget=budget
        )
    except (BackupLeaseError, quarantine.QuarantineError) as error:
        raise QuarantineExecutionError(error.code, transient=error.transient) from None
    state = _ExecutionState()
    binding = _Binding(_authority_hash(authority), id(io), id(io.guard), id(state), _TRUST)
    return PreparedQuarantineExecution(engine, settings, authority, io, deadline, state, binding)


def run_quarantine_execution(prepared):
    """Seal the successful I/O result once; on failure caller still owns locks."""
    _valid_handle(prepared)
    if prepared._state.started:
        raise QuarantineExecutionError("backup_quarantine_run_repeated")
    prepared._state.started = True

    def check_current():
        _valid_handle(prepared)
        _budget(prepared)
        with Session(prepared.engine) as session, session.begin():
            _read_authority(
                session, prepared.settings, prepared.authority.lease, expected=prepared.authority
            )
        _budget(prepared)

    try:
        result = quarantine.execute_quarantine(
            prepared.io, check_authority=check_current, check_budget=lambda: _budget(prepared)
        )
    except (BackupLeaseError, quarantine.QuarantineError) as error:
        raise QuarantineExecutionError(error.code, transient=error.transient) from None
    _valid_handle(prepared)
    prepared._state.completion = _Completion(
        result,
        _result_hash(result),
        prepared._binding.authority_sha256,
        id(prepared.io),
        id(prepared.io.guard),
        _TRUST,
    )


def _sealed_result(prepared):
    completion = prepared._state.completion
    if (
        not isinstance(completion, _Completion)
        or completion.trust is not _TRUST
        or completion.authority_sha256 != prepared._binding.authority_sha256
        or completion.io_identity != id(prepared.io)
        or completion.guard_identity != id(prepared.io.guard)
    ):
        raise QuarantineExecutionError("backup_quarantine_result_unsealed")
    result = completion.result
    plan = prepared.authority.plan
    if (
        not prepared._state.started
        or not isinstance(result, quarantine.QuarantineResult)
        or completion.sha256 != _result_hash(result)
        or result.intent_id != plan.intent_id
        or tuple(item.package for item in result.receipts) != plan.packages
        or result.sha256 != _digest([item.model_dump(mode="json") for item in result.receipts])
    ):
        raise QuarantineExecutionError("backup_quarantine_result_unsealed")
    return result


def complete_quarantine_execution(session, settings, lease, prepared):
    """No filesystem I/O here; EX/SH remain held until caller commit/finally."""
    _valid_handle(prepared, settings, lease)
    _budget(prepared)
    result = _sealed_result(prepared)
    # Acquire the same canonical prefix before store.complete locks it again.
    _read_authority(session, settings, lease, expected=prepared.authority)

    def finish(current, job):
        _valid_handle(prepared, settings, lease)
        _budget(prepared)
        authority, controls = _read_authority(current, settings, lease, expected=prepared.authority)
        if job.id != authority.plan.job_id or _sealed_result(prepared) != result:
            raise QuarantineExecutionError("backup_quarantine_result_unsealed")
        for original in authority.plan.packages:
            row = controls[original.backup_id]
            row.state = "quarantined"
            retention._bump(row)
        audit(
            current,
            authority.plan.actor_id,
            "backup.quarantine_complete",
            authority.plan.intent_id,
            packages=len(authority.plan.packages),
            bytes=sum(item.size_bytes for item in authority.plan.packages),
        )
        current.flush()
        origin = current.get(UserSession, authority.origin_session_id, populate_existing=True)
        _origin_deadline(origin, authority.plan.actor_id, store.stamp(current))
        return {
            "code": "backup_quarantined",
            "artifact_id": str(result.intent_id),
            "created_count": len(result.receipts),
            "file_count": sum(item.file_count for item in authority.plan.packages),
            "bytes": sum(item.size_bytes for item in authority.plan.packages),
            "sha256": result.sha256,
        }

    return store.complete(session, lease, finish)
