from datetime import datetime
from uuid import UUID

from sqlalchemy import BigInteger, CheckConstraint, DateTime, ForeignKey, Index, String
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from flowtrace_server.persistence.models import Base

PUBLIC_KEYS = (
    "registration_enabled",
    "invitation_default_days",
    "attachment_max_bytes",
    "per_user_attachment_quota_bytes",
    "orphan_retention_days",
    "diagnostics_enabled",
    "worker_poll_seconds",
    "backup_retention_days",
    "ocr_provider",
    "ai_provider",
)
SECRET_KEYS = ("ocr_api_key", "ai_api_key")
PUBLIC_ARRAY = "ARRAY[" + ",".join(f"'{key}'" for key in PUBLIC_KEYS) + "]::text[]"
SECRET_ARRAY = "ARRAY['ocr_api_key','ai_api_key']::text[]"
PUBLIC_SHAPE = (
    f"jsonb_typeof(public_values)='object' AND public_values ?& {PUBLIC_ARRAY} "
    f"AND public_values - {PUBLIC_ARRAY} = '{{}}'::jsonb"
)
SECRET_SHAPE = (
    f"jsonb_typeof(secret_refs)='object' AND secret_refs ?& {SECRET_ARRAY} "
    f"AND secret_refs - {SECRET_ARRAY} = '{{}}'::jsonb"
)
SECRET_UUIDS = " AND ".join(
    f"(jsonb_typeof(secret_refs->'{key}')='null' OR "
    f"(jsonb_typeof(secret_refs->'{key}')='string' AND "
    f"secret_refs->>'{key}' ~ '^[0-9a-f]{{8}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-"
    f"[0-9a-f]{{4}}-[0-9a-f]{{12}}$'))"
    for key in SECRET_KEYS
)


class ConfigurationHead(Base):
    __tablename__ = "service_configuration"
    __table_args__ = (
        CheckConstraint("id=1", name="ck_configuration_singleton"),
        CheckConstraint("current_version >= 0", name="ck_configuration_head_version"),
        CheckConstraint(PUBLIC_SHAPE, name="ck_configuration_head_public_keys"),
        CheckConstraint(SECRET_SHAPE, name="ck_configuration_head_secret_keys"),
        CheckConstraint(SECRET_UUIDS, name="ck_configuration_head_secret_uuids"),
    )
    id: Mapped[int] = mapped_column(primary_key=True)
    current_version: Mapped[int] = mapped_column(BigInteger)
    public_values: Mapped[dict] = mapped_column(JSONB)
    secret_refs: Mapped[dict] = mapped_column(JSONB)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class ConfigurationRevision(Base):
    __tablename__ = "service_configuration_revisions"
    __table_args__ = (
        CheckConstraint(
            "version >= 1 AND base_version >= 0 AND base_version < version",
            name="ck_configuration_revision_versions",
        ),
        CheckConstraint("request_hash ~ '^[0-9a-f]{64}$'", name="ck_configuration_request_hash"),
        CheckConstraint(
            "change_kind IN ('update','rollback')", name="ck_configuration_change_kind"
        ),
        CheckConstraint(
            "(change_kind='update' AND rollback_target_version IS NULL) OR "
            "(change_kind='rollback' AND rollback_target_version IS NOT NULL "
            "AND rollback_target_version >= 0 "
            "AND rollback_target_version < version)",
            name="ck_configuration_rollback_target",
        ),
        CheckConstraint(PUBLIC_SHAPE, name="ck_configuration_revision_public_keys"),
        CheckConstraint(SECRET_SHAPE, name="ck_configuration_revision_secret_keys"),
        CheckConstraint(SECRET_UUIDS, name="ck_configuration_revision_secret_uuids"),
        Index("ix_configuration_actor_created", "actor_user_id", "created_at", "version"),
    )
    version: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    base_version: Mapped[int] = mapped_column(BigInteger)
    request_id: Mapped[UUID] = mapped_column(unique=True)
    request_hash: Mapped[str] = mapped_column(String(64))
    actor_user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"))
    change_kind: Mapped[str] = mapped_column(String(12))
    rollback_target_version: Mapped[int | None] = mapped_column(BigInteger)
    public_values: Mapped[dict] = mapped_column(JSONB)
    secret_refs: Mapped[dict] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
