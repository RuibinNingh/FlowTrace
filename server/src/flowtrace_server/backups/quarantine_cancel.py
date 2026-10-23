"""Cancel only never-claimed quarantine jobs after proving no file effect.

Caller commits the read-only precheck before prepare takes selected EX leases.
The final short transaction keeps those leases until caller commit/finally.
No package/intent directory is created, renamed or deleted by this module.
"""

import hashlib
from contextlib import ExitStack
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID

from sqlalchemy import select

from flowtrace_server.admin.service import audit, lock_admin_control, reauthenticate_admin
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import assert_active_principal
from flowtrace_server.configuration.models import ConfigurationHead
from flowtrace_server.configuration.runtime import read_runtime_configuration
from flowtrace_server.imports.parsers import canonical
from flowtrace_server.jobs import store
from flowtrace_server.jobs.models import BackgroundJob, JobAttempt
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.persistence.private_files import contained

from . import retention
from .leases import backup_exclusive_lease
from .quarantine_cancel_schemas import UnclaimedQuarantineCancellation
from .quarantine_execution import QuarantineExecutionError, _payload, _plan
from .quarantine_schemas import QuarantinePlan
from .retention_models import BackupControl, BackupRetentionIntent

_TRUST = object()
CODE = "backup_quarantine_cancelled_unclaimed"


def _error(code="backup_quarantine_cancel_invalid", status=409):
    return ApiError(code, status)


def _digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def _command_hash(actor_id, command):
    if not isinstance(command, UnclaimedQuarantineCancellation):
        raise _error(status=422)
    return _digest(
        {"action": CODE, "actor_id": str(actor_id), "command": command.model_dump(mode="json")}
    )


def _job_plan(session, principal, command, *, lock=False):
    _command_hash(principal.user_id, command)
    query = select(BackgroundJob).where(BackgroundJob.id == command.job_id)
    if lock:
        query = query.with_for_update()
    job = session.scalar(query.execution_options(populate_existing=True))
    if job is None or job.owner_user_id != principal.user_id or job.kind != "backup_quarantine":
        raise _error("not_found", 404)
    try:
        payload = _payload(job)
        intent = session.get(BackupRetentionIntent, payload.intent_id, populate_existing=True)
        plan = _plan(intent, job)
        if (
            command.intent_id != plan.intent_id
            or command.selection_sha256 != plan.selection_sha256
            or payload.selection_sha256 != plan.selection_sha256
            or job.sync_epoch != plan.source_epoch
        ):
            raise ValueError
    except (QuarantineExecutionError, ValueError, TypeError, AttributeError):
        raise _error("backup_quarantine_intent_changed") from None
    return job, plan


def _unclaimed(session, job):
    if (
        job.status != "pending"
        or job.attempt != 0
        or job.lease_generation != 0
        or job.manual_retries != 0
        or job.lease_owner is not None
        or job.lease_until is not None
        or job.result is not None
        or job.error_code is not None
        or session.scalar(select(JobAttempt.job_id).where(JobAttempt.job_id == job.id).limit(1))
        is not None
    ):
        raise _error("backup_quarantine_already_claimed")


def _controls(session, plan, *, lock=False):
    rows = []
    for original in plan.packages:
        query = select(BackupControl).where(BackupControl.backup_id == original.backup_id)
        if lock:
            query = query.with_for_update()
        row = session.scalar(query.execution_options(populate_existing=True))
        if (
            row is None
            or row.state != "reserved"
            or row.intent_id != plan.intent_id
            or row.version != original.control_version + 1
            or not retention._same_package(retention._stamp(row), original)
        ):
            raise _error("backup_control_conflict")
        rows.append(row)
    return rows


def _phase(session, *, lock=False):
    query = select(ServerState).where(ServerState.singleton_id == 1)
    if lock:
        query = query.with_for_update(read=True)
    source = session.scalar(query.execution_options(populate_existing=True))
    query = select(ConfigurationHead.current_version).where(ConfigurationHead.id == 1)
    if lock:
        query = query.with_for_update(read=True)
    version = session.scalar(query)
    if source is None or version != read_runtime_configuration(session).version:
        raise _error("backup_configuration_changed")
    return source.instance_id, source.sync_epoch, version


@dataclass(frozen=True)
class UnclaimedCancellationAuthority:
    plan: QuarantinePlan
    command_sha256: str
    current_instance_id: UUID
    current_epoch: UUID
    current_config_version: int
    settings_key: str
    trust: object


def precheck_unclaimed_cancel(session, principal, settings, *, command, password):
    """Read-only. Caller commits before prepare waits or hashes files."""
    retention._readonly(session, principal, password)
    job, plan = _job_plan(session, principal, command)
    _unclaimed(session, job)
    _controls(session, plan)
    return UnclaimedCancellationAuthority(
        plan,
        _command_hash(principal.user_id, command),
        *_phase(session),
        retention._settings_key(settings),
        _TRUST,
    )


def _authority_hash(authority):
    return _digest(
        {
            "plan": authority.plan.model_dump(mode="json"),
            "command_sha256": authority.command_sha256,
            "phase": [
                str(authority.current_instance_id),
                str(authority.current_epoch),
                authority.current_config_version,
            ],
            "settings_key": authority.settings_key,
        }
    )


@dataclass
class _LeaseState:
    active: bool = True


@dataclass(frozen=True)
class PreparedUnclaimedCancellation:
    authority: UnclaimedCancellationAuthority
    guard: ExitStack
    _state: _LeaseState
    _authority_sha256: str
    _guard_identity: int
    _state_identity: int

    @property
    def closed(self):
        return not self._state.active

    def close(self):
        self.guard.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def _no_intent_directory(settings, intent_id):
    base = Path(settings.data_directory.absolute())
    target = base / "backup-quarantine" / str(intent_id)
    try:
        contained(target, base)
        target.lstat()
    except FileNotFoundError:
        return
    except OSError:
        raise _error("backup_quarantine_effect_not_absent") from None
    raise _error("backup_quarantine_effect_not_absent")


def prepare_unclaimed_cancel(settings, *, authority, check_budget=None):
    """Pure full verification with EX, without creating an intent/plan directory."""
    if (
        not isinstance(authority, UnclaimedCancellationAuthority)
        or authority.trust is not _TRUST
        or authority.settings_key != retention._settings_key(settings)
    ):
        raise _error(status=422)
    guard, state = ExitStack(), _LeaseState()
    guard.callback(setattr, state, "active", False)
    try:
        guard.enter_context(
            backup_exclusive_lease(
                settings,
                tuple(item.backup_id for item in authority.plan.packages),
                check_budget=check_budget,
            )
        )
        _no_intent_directory(settings, authority.plan.intent_id)
        for original in authority.plan.packages:
            actual = retention._verify_stamp(
                settings, original.backup_id, check_budget=check_budget
            )
            if not retention._same_package(actual, original):
                raise _error("backup_package_changed")
        _no_intent_directory(settings, authority.plan.intent_id)
        return PreparedUnclaimedCancellation(
            authority, guard, state, _authority_hash(authority), id(guard), id(state)
        )
    except BaseException:
        guard.close()
        raise


def _prepared(settings, principal, command, prepared):
    try:
        authority = prepared.authority
        valid = (
            isinstance(prepared, PreparedUnclaimedCancellation)
            and isinstance(authority, UnclaimedCancellationAuthority)
            and authority.trust is _TRUST
            and prepared._state.active
            and prepared._guard_identity == id(prepared.guard)
            and prepared._state_identity == id(prepared._state)
            and prepared._authority_sha256 == _authority_hash(authority)
            and authority.settings_key == retention._settings_key(settings)
            and authority.plan.actor_id == principal.user_id
            and authority.command_sha256 == _command_hash(principal.user_id, command)
        )
    except Exception:
        valid = False
    if not valid:
        raise _error("backup_quarantine_cancel_binding_changed")
    return authority


def _replay(job, command_hash):
    if job.status != "cancelled":
        return None
    wanted = store.JobResult(code=CODE, sha256=command_hash).model_dump(exclude_none=True)
    if (
        job.error_code != CODE
        or job.result != wanted
        or job.attempt != 0
        or job.lease_generation != 0
        or job.manual_retries != 0
        or job.lease_owner is not None
        or job.lease_until is not None
    ):
        raise _error("backup_quarantine_cancel_conflict")
    return store.metadata(job)


def replay_unclaimed_cancel(session, principal, *, command, password):
    """Per-job exact-command metadata replay, fresh auth, no old phase or file I/O."""
    reauthenticate_admin(session, principal, password, capability="recovery")
    job, _ = _job_plan(session, principal, command, lock=True)
    return _replay(job, _command_hash(principal.user_id, command))


def cancel_unclaimed_quarantine(session, principal, settings, *, prepared, command, password):
    """Caller commits/rolls back before finally closing prepared; no file I/O."""
    authority = _prepared(settings, principal, command, prepared)
    # Same ordering as the worker's State -> owner -> job, with admin outermost.
    lock_admin_control(session)
    store._epoch(session, lock=True)
    reauthenticate_admin(session, principal, password, capability="recovery")
    job, plan = _job_plan(session, principal, command, lock=True)
    if old := _replay(job, authority.command_sha256):
        return old
    _unclaimed(session, job)
    phase = _phase(session, lock=True)
    if (
        phase
        != (
            authority.current_instance_id,
            authority.current_epoch,
            authority.current_config_version,
        )
        or plan != authority.plan
    ):
        raise _error("backup_quarantine_cancel_phase_changed")
    controls = _controls(session, plan, lock=True)
    # Wall time can pass while locks wait. Recheck the current action session,
    # password and roles at the end, never the old intent's origin TTL.
    reauthenticate_admin(session, principal, password, capability="recovery")
    _prepared(settings, principal, command, prepared)
    job = store.cancel(session, job.id)
    job.error_code = CODE
    job.result = store.JobResult(code=CODE, sha256=authority.command_sha256).model_dump(
        exclude_none=True
    )
    for row in controls:
        row.state, row.intent_id = "available", None
        retention._bump(row)
    audit(
        session,
        principal.user_id,
        "backup.quarantine_cancel_unclaimed",
        plan.intent_id,
        packages=len(controls),
        command_sha256=authority.command_sha256,
    )
    session.flush()
    assert_active_principal(session, principal, lock=False)
    return store.metadata(job)
