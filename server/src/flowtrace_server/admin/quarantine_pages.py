"""Closed confirmation-page inputs for explicitly selected backup quarantine.

Routes own CSRF, threadpool boundaries, short transaction commits and file
lease lifetime. This module performs no file effects and grants no authority.
"""

import re
from uuid import uuid4

from flowtrace_server.backups import quarantine_submission
from flowtrace_server.backups.quarantine_schemas import QuarantineSubmission
from flowtrace_server.jobs.administration import executable_kinds

from . import retention_pages


def require_executable(settings):
    if "backup_quarantine" not in executable_kinds(settings):
        from flowtrace_server.auth.errors import ApiError

        raise ApiError("backup_quarantine_unavailable", 503)


def parse_submission(form, preview_id):
    retention_pages._closed(
        form,
        {
            "csrf_token",
            "confirm_target",
            "request_id",
            "selection_sha256",
            "current_password",
        },
    )
    retention_pages._confirm(form, preview_id)
    checksum = form["selection_sha256"]
    if not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise retention_pages._input_error()
    return (
        QuarantineSubmission(
            preview_id=preview_id,
            request_id=retention_pages._uuid(form["request_id"]),
            selection_sha256=checksum,
        ),
        retention_pages._password(form),
    )


def confirmation_data(session, principal, settings, record):
    """Read-only GET checks; submission still requires fresh password and hashes."""
    require_executable(settings)
    command = QuarantineSubmission(
        preview_id=record.preview_id,
        request_id=uuid4(),
        selection_sha256=record.selection_sha256,
    )
    quarantine_submission.precheck_quarantine_submission(
        session, principal, settings, command=command, record=record, password=None
    )
    return {
        **retention_pages.preview_data(record),
        "submission_request_id": command.request_id,
        "selection_sha256": command.selection_sha256,
    }
