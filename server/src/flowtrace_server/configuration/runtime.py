"""Fresh validated runtime policy; database values never become arbitrary code."""

from dataclasses import dataclass

from pydantic import ValidationError
from sqlalchemy import func, select

from flowtrace_server.auth.errors import ApiError

from .schemas import PublicConfiguration

EFFECTIVE_FIELDS = (
    "registration_enabled",
    "invitation_default_days",
    "attachment_max_bytes",
    "per_user_attachment_quota_bytes",
    "orphan_retention_days",
    "worker_poll_seconds",
    "diagnostics_enabled",
)


@dataclass(frozen=True)
class RuntimeConfiguration:
    version: int
    values: PublicConfiguration


def read_runtime_configuration(session) -> RuntimeConfiguration:
    from .models import PUBLIC_KEYS, ConfigurationHead

    record = session.execute(
        select(ConfigurationHead.current_version, ConfigurationHead.public_values).where(
            ConfigurationHead.id == 1
        )
    ).one_or_none()
    if record is None:
        raise ApiError("configuration_not_initialized", 503)
    try:
        if set(record.public_values) != set(PUBLIC_KEYS):
            raise ValueError
        values = PublicConfiguration.model_validate(record.public_values)
    except (ValidationError, ValueError, TypeError):
        raise ApiError("configuration_snapshot_invalid", 503) from None
    return RuntimeConfiguration(record.current_version, values)


def require_registration_enabled(session):
    if not read_runtime_configuration(session).values.registration_enabled:
        raise ApiError("registration_disabled", 403)


def enforce_attachment_reservation(session, principal, size_bytes):
    """Caller already holds the current user lock before scope/attachment locks.

    Pending/uploaded reservations and deletion-in-progress all count. Existing
    live declarations replay without reserving again; resurrecting deleted ones
    reserves afresh. Reduced limits do not invalidate existing declared uploads.
    """
    from flowtrace_server.attachments.models import Attachment

    values = read_runtime_configuration(session).values
    if size_bytes > values.attachment_max_bytes:
        raise ApiError("attachment_file_limit_exceeded", 413)
    used = session.scalar(
        select(func.coalesce(func.sum(Attachment.size_bytes), 0)).where(
            Attachment.created_by == principal.user_id,
            Attachment.status != "deleted",
        )
    )
    if used + size_bytes > values.per_user_attachment_quota_bytes:
        raise ApiError("attachment_quota_exceeded", 409)
