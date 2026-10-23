"""Closed management commands; callers own transaction, CSRF and HTTP encoding."""

from uuid import UUID, uuid5

from sqlalchemy import select

from flowtrace_server.admin.service import (
    audit,
    reauthenticate_admin,
    require_portal,
    require_recovery,
)
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import assert_active_principal, roles_for
from flowtrace_server.backups.job_references import retain_job_backup

from . import store
from .models import BackgroundJob, WorkerState

RECOVERY_KINDS = frozenset(
    {"backup_create", "backup_verify", "restore_rehearsal", "backup_quarantine"}
)
EXECUTABLE_KINDS = frozenset(
    {
        "backup_verify",
        "backup_create",
        "restore_rehearsal",
        "backup_quarantine",
        "import_preview",
        "import_apply",
    }
)
BACKUP_REQUEST_NAMESPACE = UUID("d4c895cb-8b34-44c3-b06d-7e61477ce4c0")
STATUSES = frozenset({"pending", "running", "succeeded", "retry_wait", "failed", "cancelled"})


def executable_kinds(settings=None):
    result = {"backup_verify", "backup_quarantine", "import_preview", "import_apply"}
    executable = settings.pg_dump_executable if settings is not None else None
    if executable is not None and executable.is_file():
        result.add("backup_create")
    if settings is not None and any(
        target.pg_restore_executable.is_file() for target in settings.restore_targets.values()
    ):
        result.add("restore_rehearsal")
    return frozenset(result)


def get_job(session, principal, job_id, *, settings=None):
    assert_active_principal(session, principal, lock=False)
    require_portal(session, principal)
    record = session.get(BackgroundJob, job_id)
    current = roles_for(session, principal.user_id)
    service = bool(current.intersection({"server_owner", "service_admin"}))
    if record is None or (not service and record.kind not in RECOVERY_KINDS):
        raise ApiError("not_found", 404)
    result = store.metadata(record)
    controls = (
        "recovery_admin" in current if record.kind in RECOVERY_KINDS else service
    ) and record.kind != "backup_quarantine"
    result["allowed_actions"] = [
        action
        for action, allowed in {
            "retry": controls
            and record.kind in executable_kinds(settings)
            and record.status in {"failed", "retry_wait"},
            "cancel": controls and record.status not in {"succeeded", "cancelled"},
        }.items()
        if allowed
    ]
    return result


def list_jobs(session, principal, *, kind=None, status=None, before=None, settings=None):
    assert_active_principal(session, principal, lock=False)
    require_portal(session, principal)
    if (kind is not None and kind not in store.KINDS) or (
        status is not None and status not in STATUSES
    ):
        raise ApiError("job_filter_invalid", 422)
    statement = select(BackgroundJob)
    if not roles_for(session, principal.user_id).intersection({"server_owner", "service_admin"}):
        statement = statement.where(BackgroundJob.kind.in_(RECOVERY_KINDS))
    if kind is not None:
        statement = statement.where(BackgroundJob.kind == kind)
    if status is not None:
        statement = statement.where(BackgroundJob.status == status)
    if before is not None:
        # An opaque job ID is only an anchor; no caller-provided SQL/date cursor.
        anchor = session.get(BackgroundJob, before)
        if anchor is None:
            raise ApiError("job_cursor_invalid", 422)
        statement = statement.where(
            (BackgroundJob.created_at < anchor.created_at)
            | ((BackgroundJob.created_at == anchor.created_at) & (BackgroundJob.id < anchor.id))
        )
    records = list(
        session.scalars(
            statement.order_by(BackgroundJob.created_at.desc(), BackgroundJob.id.desc()).limit(51)
        )
    )
    return {
        "items": [store.metadata(job) for job in records[:50]],
        "next_cursor": str(records[49].id) if len(records) > 50 else None,
        "has_more": len(records) > 50,
        "executable_kinds": sorted(executable_kinds(settings)),
    }


def list_workers(session, principal):
    assert_active_principal(session, principal, lock=False)
    require_portal(session, principal)
    current = store.stamp(session)
    records = list(
        session.scalars(select(WorkerState).order_by(WorkerState.heartbeat_at.desc()).limit(50))
    )
    return [
        {
            "worker_id": str(record.id),
            "version": record.version,
            "supported_kinds": record.supported_kinds,
            "started_at": record.started_at.isoformat(),
            "heartbeat_at": record.heartbeat_at.isoformat(),
            "fresh": (current - record.heartbeat_at).total_seconds() <= 60,
            "active_job_id": str(record.active_job_id) if record.active_job_id else None,
        }
        for record in records
    ]


def enqueue_backup_verification(session, principal, *, backup_id, request_id, password):
    if not isinstance(backup_id, UUID) or not isinstance(request_id, UUID):
        raise ApiError("job_input_invalid", 422)
    reauthenticate_admin(session, principal, password, capability="recovery")
    try:
        record = store.enqueue(
            session,
            kind="backup_verify",
            occurrence_key=f"backup-verify:{request_id}",
            owner_user_id=principal.user_id,
            payload={"backup_id": str(backup_id)},
        )
    except store.JobConflict:
        raise ApiError("job_occurrence_conflict", 409) from None
    retain_job_backup(session, record.id)
    audit(session, principal.user_id, "job.backup_verify_enqueue", record.id)
    return store.metadata(record)


def enqueue_backup_creation(session, principal, settings, *, request_id, password):
    if not isinstance(request_id, UUID):
        raise ApiError("job_input_invalid", 422)
    reauthenticate_admin(session, principal, password, capability="recovery")
    executable = settings.pg_dump_executable
    if executable is None or not executable.is_file():
        raise ApiError("backup_tool_unavailable", 503)
    backup_id = uuid5(BACKUP_REQUEST_NAMESPACE, f"{principal.user_id}:{request_id}")
    key = f"backup-create:{request_id}"
    existed = session.scalar(
        select(BackgroundJob.id).where(
            BackgroundJob.kind == "backup_create", BackgroundJob.occurrence_key == key
        )
    )
    try:
        record = store.enqueue(
            session,
            kind="backup_create",
            occurrence_key=key,
            owner_user_id=principal.user_id,
            payload={"backup_id": str(backup_id)},
        )
    except store.JobConflict:
        raise ApiError("job_occurrence_conflict", 409) from None
    retain_job_backup(session, record.id)
    if existed is None:
        audit(session, principal.user_id, "job.backup_create_enqueue", record.id)
    return store.metadata(record)


def control_job(session, principal, *, job_id, action, password, settings=None):
    if not isinstance(job_id, UUID) or action not in {"retry", "cancel"}:
        raise ApiError("job_input_invalid", 422)
    # Serialize role mutation and lock the actor before obtaining a job lock.
    reauthenticate_admin(session, principal, password, capability="portal")
    record = session.get(BackgroundJob, job_id)
    if record is None:
        raise ApiError("not_found", 404)
    if record.kind in RECOVERY_KINDS:
        require_recovery(session, principal)
    elif not roles_for(session, principal.user_id).intersection({"server_owner", "service_admin"}):
        raise ApiError("admin_forbidden", 403)
    if record.kind == "backup_quarantine":
        # Cancellation/retry must inspect exact file effects and release only
        # this immutable intent's reservations. Generic queue actions cannot.
        raise ApiError("backup_quarantine_control_required", 409)
    if action == "retry" and record.kind not in executable_kinds(settings):
        raise ApiError("job_handler_unavailable", 409)
    if action == "retry" and record.kind in RECOVERY_KINDS:
        retain_job_backup(session, record.id, for_retry=True)
    try:
        record = (
            store.retry(session, job_id) if action == "retry" else store.cancel(session, job_id)
        )
    except store.JobConflict as error:
        raise ApiError(str(error), 409) from None
    audit(session, principal.user_id, f"job.{action}", record.id)
    return store.metadata(record)
