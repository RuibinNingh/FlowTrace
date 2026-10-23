"""Caller-owned transactions and fenced completion for the fixed-kind queue.

This is an internal store, not a public RPC surface. Enqueue callers validate
kind-specific closed input and current authority. Financial handlers recheck
plan/permission versions in the same fenced transaction as their effect.
"""

import hashlib
import json
import re
from copy import deepcopy
from dataclasses import dataclass
from datetime import timedelta
from typing import Annotated
from uuid import UUID, uuid4

from pydantic import BaseModel, ConfigDict, Field, StringConstraints
from sqlalchemy import and_, func, or_, select
from sqlalchemy.exc import IntegrityError

from flowtrace_server.auth.models import User
from flowtrace_server.persistence.models import ServerState

from .models import BackgroundJob, JobAttempt, WorkerState

KINDS = frozenset(
    {
        "recurring_occurrence",
        "installment_occurrence",
        "import_preview",
        "import_apply",
        "export",
        "backup_create",
        "backup_verify",
        "restore_rehearsal",
        "backup_quarantine",
    }
)
BACKOFF = (5, 30, 120, 600)
LEASE_SECONDS = 60
# Long database effects cannot renew a job row they already hold FOR UPDATE.
# These server-owned bounds leave room for a single atomic completion; they do
# not advertise handlers or promise capacity/performance at the source limit.
LEASE_SECONDS_BY_KIND = {
    "import_preview": 300,
    "import_apply": 900,
    "backup_create": 300,
    "restore_rehearsal": 900,
    "backup_quarantine": 900,
}
SafeCode = Annotated[str, StringConstraints(pattern=r"^[a-z][a-z0-9_.-]{0,63}$")]


class JobResult(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    code: SafeCode
    artifact_id: str | None = Field(
        default=None, pattern=r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
    )
    commit_id: str | None = Field(
        default=None, pattern=r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
    )
    created_count: int | None = Field(default=None, ge=0, le=200000)
    file_count: int | None = Field(default=None, ge=0, le=100002)
    bytes: int | None = Field(default=None, ge=0, le=2**63 - 1)
    sha256: str | None = Field(default=None, pattern=r"^[0-9a-f]{64}$")


class JobConflict(RuntimeError):
    pass


class LeaseLost(RuntimeError):
    pass


@dataclass(frozen=True)
class JobLease:
    job_id: UUID
    worker_id: UUID
    generation: int


def lease_seconds(kind):
    if kind not in KINDS:
        raise ValueError("job_definition_invalid")
    return LEASE_SECONDS_BY_KIND.get(kind, LEASE_SECONDS)


def stamp(session):
    # Wall clock is sampled after row locks, not transaction-start time.
    return session.scalar(select(func.clock_timestamp()))


def _epoch(session, *, lock=False):
    statement = select(ServerState.sync_epoch).where(ServerState.singleton_id == 1)
    if lock:
        statement = statement.with_for_update(read=True)
    return session.scalar(statement)


def _code(code):
    if not isinstance(code, str) or not re.fullmatch(r"[a-z][a-z0-9_.-]{0,63}", code):
        raise ValueError("job_error_code_invalid")
    return code


def _payload(value):
    if not isinstance(value, dict):
        raise ValueError("job_payload_invalid")

    def walk(item, depth=0):
        if depth > 16:
            raise ValueError("job_payload_invalid")
        if isinstance(item, dict):
            if any(not isinstance(key, str) for key in item):
                raise ValueError("job_payload_invalid")
            for child in item.values():
                walk(child, depth + 1)
        elif isinstance(item, list):
            for child in item:
                walk(child, depth + 1)
        elif item is not None and type(item) not in {str, int, bool}:
            raise ValueError("job_payload_invalid")

    walk(value)
    encoded = json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
    if len(encoded.encode()) > 65536:
        raise ValueError("job_payload_too_large")
    return json.loads(encoded), hashlib.sha256(encoded.encode()).hexdigest()


def enqueue(
    session,
    *,
    kind,
    occurrence_key,
    owner_user_id,
    payload,
    scope_id=None,
    rule_revision=None,
    available_at=None,
):
    """Idempotent immutable intent; does not commit or execute the job."""
    if kind not in KINDS or not re.fullmatch(r"[A-Za-z0-9:_.-]{1,200}", occurrence_key):
        raise ValueError("job_definition_invalid")
    if rule_revision is not None and (
        type(rule_revision) is not int or not 1 <= rule_revision < 2**63
    ):
        raise ValueError("job_rule_revision_invalid")
    value, digest = _payload(payload)
    current_epoch = _epoch(session)

    def existing():
        return session.scalar(
            select(BackgroundJob)
            .where(
                BackgroundJob.kind == kind,
                BackgroundJob.occurrence_key == occurrence_key,
            )
            .with_for_update()
            .execution_options(populate_existing=True)
        )

    def reuse(record):
        if (
            record.owner_user_id != owner_user_id
            or record.scope_id != scope_id
            or record.rule_revision != rule_revision
            or record.sync_epoch != current_epoch
            or record.payload_hash != digest
        ):
            raise JobConflict("job_occurrence_conflict")
        return record

    if record := existing():
        return reuse(record)
    created = stamp(session)
    if available_at is not None and (
        available_at.tzinfo is None or available_at.utcoffset() is None
    ):
        raise ValueError("job_time_requires_offset")
    record = BackgroundJob(
        id=uuid4(),
        kind=kind,
        occurrence_key=occurrence_key,
        owner_user_id=owner_user_id,
        scope_id=scope_id,
        sync_epoch=current_epoch,
        rule_revision=rule_revision,
        payload=value,
        payload_hash=digest,
        status="pending",
        available_at=available_at or created,
        attempt=0,
        manual_retries=0,
        lease_owner=None,
        lease_until=None,
        lease_generation=0,
        result=None,
        error_code=None,
        created_at=created,
        updated_at=created,
    )
    try:
        with session.begin_nested():
            session.add(record)
            session.flush()
    except IntegrityError:
        record = existing()
        if record is None:
            raise
        return reuse(record)
    return record


def _end_attempt(session, job, status, code=None):
    attempt = session.get(JobAttempt, (job.id, job.lease_generation))
    if attempt is not None and attempt.finished_at is None:
        attempt.status, attempt.error_code, attempt.finished_at = status, code, stamp(session)


def _clear_lease(job):
    job.lease_owner = job.lease_until = None


def claim(session, worker_id: UUID, supported_kinds):
    """Commit the returned lease before running any handler outside this call."""
    supported = set(supported_kinds)
    if not supported or not supported.issubset(KINDS):
        raise ValueError("job_worker_kinds_invalid")
    for _ in range(100):
        current = stamp(session)
        job = session.scalar(
            select(BackgroundJob)
            .where(
                BackgroundJob.kind.in_(supported),
                or_(
                    and_(
                        BackgroundJob.status.in_(["pending", "retry_wait"]),
                        BackgroundJob.available_at <= current,
                    ),
                    and_(BackgroundJob.status == "running", BackgroundJob.lease_until <= current),
                ),
            )
            .order_by(BackgroundJob.available_at, BackgroundJob.id)
            .limit(1)
            .with_for_update(skip_locked=True)
            .execution_options(populate_existing=True)
        )
        if job is None:
            return None
        current = stamp(session)
        if job.status == "running":
            _end_attempt(session, job, "lease_expired", "lease_expired")
        owner = session.scalar(select(User.enabled).where(User.id == job.owner_user_id))
        current_epoch = _epoch(session)
        if job.sync_epoch != current_epoch or owner is not True or job.attempt >= 5:
            job.status = "failed" if job.attempt >= 5 else "cancelled"
            job.error_code = (
                "attempts_exhausted"
                if job.attempt >= 5
                else "epoch_changed"
                if job.sync_epoch != current_epoch
                else "owner_disabled"
            )
            _clear_lease(job)
            job.updated_at = current
            session.flush()
            continue
        job.status, job.error_code = "running", None
        job.attempt += 1
        job.lease_generation += 1
        job.lease_owner = worker_id
        job.lease_until = current + timedelta(seconds=lease_seconds(job.kind))
        job.updated_at = current
        session.add(
            JobAttempt(
                job_id=job.id,
                generation=job.lease_generation,
                worker_id=worker_id,
                status="running",
                started_at=current,
                finished_at=None,
                error_code=None,
            )
        )
        session.flush()
        return JobLease(job.id, worker_id, job.lease_generation)
    return None


def leased_job(session, lease: JobLease):
    job = session.scalar(
        select(BackgroundJob)
        .where(BackgroundJob.id == lease.job_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    current = stamp(session)
    if (
        job is None
        or job.status != "running"
        or job.lease_owner != lease.worker_id
        or job.lease_generation != lease.generation
        or job.lease_until <= current
        or job.sync_epoch != _epoch(session)
    ):
        raise LeaseLost("job_lease_lost")
    return job


def renew(session, lease):
    job = leased_job(session, lease)
    job.lease_until = stamp(session) + timedelta(seconds=lease_seconds(job.kind))
    job.updated_at = stamp(session)
    session.flush()


def complete(session, lease, effect):
    """Effect, authority checks and final state share a rollback-only savepoint.

    The handler must not commit/rollback this session or perform external file
    publication here. Failed/expired completion cannot retain partial DB work.
    """
    with session.begin_nested():
        # Match domain lock ordering: deployment state -> user -> job -> scopes.
        # A disabled owner cannot race between the final check and DB commit.
        # All these locks remain held by the caller's outer transaction.
        _epoch(session, lock=True)
        owner_id = session.scalar(
            select(BackgroundJob.owner_user_id).where(BackgroundJob.id == lease.job_id)
        )
        owner = session.scalar(
            select(User)
            .where(User.id == owner_id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
        if owner is None or not owner.enabled:
            raise LeaseLost("job_owner_changed")
        job = leased_job(session, lease)
        result = JobResult.model_validate(effect(session, job)).model_dump(exclude_none=True)
        job = leased_job(session, lease)
        owner = session.scalar(
            select(User)
            .where(User.id == job.owner_user_id)
            .execution_options(populate_existing=True)
        )
        if owner is None or not owner.enabled:
            raise LeaseLost("job_owner_changed")
        _end_attempt(session, job, "succeeded")
        current = stamp(session)
        job.status, job.result, job.error_code = "succeeded", result, None
        job.updated_at = current
        _clear_lease(job)
        session.flush()
        return deepcopy(result)


def fail(session, lease, code: str, *, transient: bool):
    _code(code)
    job = leased_job(session, lease)
    current = stamp(session)
    retry = transient and job.attempt < 5
    next_status = "retry_wait" if retry else "failed"
    _end_attempt(session, job, next_status, code)
    job.status = next_status
    job.error_code, job.updated_at = code, current
    if retry:
        job.available_at = current + timedelta(seconds=BACKOFF[job.attempt - 1])
    _clear_lease(job)
    session.flush()


def cancel(session, job_id):
    job = session.scalar(
        select(BackgroundJob)
        .where(BackgroundJob.id == job_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if job is None:
        raise JobConflict("job_not_found")
    if job.status == "succeeded":
        raise JobConflict("job_already_completed")
    if job.status != "cancelled":
        _end_attempt(session, job, "cancelled", "cancelled")
        current = stamp(session)
        job.status, job.error_code = "cancelled", "cancelled"
        job.updated_at = current
        _clear_lease(job)
        session.flush()
    return job


def retry(session, job_id):
    job = session.scalar(
        select(BackgroundJob)
        .where(BackgroundJob.id == job_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if job is None or job.status not in {"failed", "retry_wait"}:
        raise JobConflict("job_not_retryable")
    if job.sync_epoch != _epoch(session):
        raise JobConflict("job_epoch_changed")
    job.status, job.attempt, job.error_code = "pending", 0, None
    job.manual_retries += 1
    job.available_at = job.updated_at = stamp(session)
    _clear_lease(job)
    session.flush()
    return job


def heartbeat(session, worker_id, *, version, supported_kinds, active_job_id=None):
    kinds = set(supported_kinds)
    if not kinds.issubset(KINDS) or not re.fullmatch(r"[A-Za-z0-9_.+-]{1,32}", version):
        raise ValueError("worker_metadata_invalid")
    current = stamp(session)
    record = session.get(WorkerState, worker_id)
    if record is None:
        record = WorkerState(
            id=worker_id,
            version=version,
            supported_kinds=sorted(kinds),
            started_at=current,
            heartbeat_at=current,
            active_job_id=active_job_id,
        )
        session.add(record)
    else:
        record.version, record.supported_kinds = version, sorted(kinds)
        record.heartbeat_at, record.active_job_id = current, active_job_id
    session.flush()
    return record


def metadata(job):
    """Fixed public projection, never payload/body/paths/exception strings."""
    return {
        "job_id": str(job.id),
        "kind": job.kind,
        "status": job.status,
        "owner_user_id": str(job.owner_user_id),
        "attempt": job.attempt,
        "manual_retries": job.manual_retries,
        "generation": str(job.lease_generation),
        "available_at": job.available_at.isoformat(),
        "created_at": job.created_at.isoformat(),
        "updated_at": job.updated_at.isoformat(),
        "lease_until": job.lease_until.isoformat() if job.lease_until else None,
        "error_code": job.error_code,
        "result": deepcopy(job.result),
    }
