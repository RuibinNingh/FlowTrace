"""Explicit per-job confirmation for cancellation before the first claim."""

import re
from uuid import uuid4

from sqlalchemy import select

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.backups import quarantine_cancel, retention
from flowtrace_server.backups.quarantine_cancel_schemas import UnclaimedQuarantineCancellation
from flowtrace_server.backups.retention_models import BackupRetentionIntent
from flowtrace_server.jobs.models import BackgroundJob

from . import retention_pages


def parse_cancellation(form, job_id):
    retention_pages._closed(
        form,
        {
            "csrf_token",
            "confirm_target",
            "intent_id",
            "selection_sha256",
            "request_id",
            "expected_generation",
            "current_password",
        },
    )
    retention_pages._confirm(form, job_id)
    if form["expected_generation"] != "0" or not re.fullmatch(
        r"[0-9a-f]{64}", form["selection_sha256"]
    ):
        raise retention_pages._input_error()
    command = UnclaimedQuarantineCancellation(
        job_id=job_id,
        intent_id=retention_pages._uuid(form["intent_id"]),
        selection_sha256=form["selection_sha256"],
        request_id=retention_pages._uuid(form["request_id"]),
        expected_generation=0,
    )
    return command, retention_pages._password(form)


def confirmation_data(session, principal, settings, job_id):
    retention._readonly(session, principal)
    job = session.get(BackgroundJob, job_id, populate_existing=True)
    if job is None or job.owner_user_id != principal.user_id or job.kind != "backup_quarantine":
        raise ApiError("not_found", 404)
    intent = session.scalar(
        select(BackupRetentionIntent).where(BackupRetentionIntent.job_id == job_id)
    )
    if intent is None:
        raise ApiError("backup_quarantine_intent_changed", 409)
    command = UnclaimedQuarantineCancellation(
        job_id=job_id,
        intent_id=intent.id,
        selection_sha256=intent.selection_sha256,
        request_id=uuid4(),
        expected_generation=0,
    )
    authority = quarantine_cancel.precheck_unclaimed_cancel(
        session, principal, settings, command=command, password=None
    )
    return {
        "job_id": command.job_id,
        "intent_id": command.intent_id,
        "selection_sha256": command.selection_sha256,
        "request_id": command.request_id,
        "packages": [
            {
                "backup_id": item.backup_id,
                "file_count": item.file_count,
                "size_bytes": item.size_bytes,
            }
            for item in authority.plan.packages
        ],
    }
