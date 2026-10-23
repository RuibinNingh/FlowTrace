"""Unregistered retention metadata proposal; root owns migration/registry.

An absent control row is protected, never an implicit available registration.
Control version is a CAS fence. Pins/holds can only release once; intents are
append-only and derive mutable execution state from the actual durable job.
"""

from datetime import datetime
from uuid import UUID

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    UniqueConstraint,
    event,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from flowtrace_server.persistence.models import Base


class BackupControl(Base):
    __tablename__ = "backup_controls"
    __table_args__ = (
        CheckConstraint("version>=1", name="ck_backup_control_version"),
        CheckConstraint(
            "state IN ('available','reserved','quarantined','partial','destroyed')",
            name="ck_backup_control_state",
        ),
        CheckConstraint(
            "(state='available' AND intent_id IS NULL) OR "
            "(state<>'available' AND intent_id IS NOT NULL)",
            name="ck_backup_control_intent",
        ),
        CheckConstraint(
            "manifest_sha256 ~ '^[0-9a-f]{64}$' AND tree_sha256 ~ '^[0-9a-f]{64}$'",
            name="ck_backup_control_hashes",
        ),
        CheckConstraint(
            "size_bytes BETWEEN 1 AND 1078984704 AND file_count BETWEEN 3 AND 100002",
            name="ck_backup_control_capacity",
        ),
        Index("ix_backup_control_created", "created_at", "backup_id"),
    )
    backup_id: Mapped[UUID] = mapped_column(primary_key=True)
    version: Mapped[int] = mapped_column(BigInteger, default=1, server_default="1")
    state: Mapped[str] = mapped_column(String(16), default="available", server_default="available")
    intent_id: Mapped[UUID | None] = mapped_column(ForeignKey("backup_retention_intents.id"))
    manifest_sha256: Mapped[str] = mapped_column(String(64))
    tree_sha256: Mapped[str] = mapped_column(String(64))
    instance_id: Mapped[UUID]
    sync_epoch: Mapped[UUID]
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    size_bytes: Mapped[int] = mapped_column(BigInteger)
    file_count: Mapped[int] = mapped_column(Integer)
    registered_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class BackupPin(Base):
    __tablename__ = "backup_pins"
    __table_args__ = (
        CheckConstraint(
            "(version=1 AND released_at IS NULL AND released_by IS NULL "
            "AND release_request_id IS NULL AND release_request_hash IS NULL) OR "
            "(version=2 AND released_at IS NOT NULL AND released_by IS NOT NULL "
            "AND release_request_id IS NOT NULL AND release_request_hash IS NOT NULL)",
            name="ck_backup_pin_lifecycle",
        ),
        CheckConstraint(
            "create_request_hash ~ '^[0-9a-f]{64}$' AND "
            "(release_request_hash IS NULL OR release_request_hash ~ '^[0-9a-f]{64}$')",
            name="ck_backup_pin_hashes",
        ),
        CheckConstraint(
            "released_at IS NULL OR released_at>=created_at", name="ck_backup_pin_time"
        ),
        Index("ix_backup_pin_active", "backup_id", "released_at"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    backup_id: Mapped[UUID] = mapped_column(ForeignKey("backup_controls.backup_id"))
    version: Mapped[int] = mapped_column(BigInteger, default=1, server_default="1")
    created_by: Mapped[UUID] = mapped_column(ForeignKey("users.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    create_request_id: Mapped[UUID] = mapped_column(unique=True)
    create_request_hash: Mapped[str] = mapped_column(String(64))
    released_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    released_by: Mapped[UUID | None] = mapped_column(ForeignKey("users.id"))
    release_request_id: Mapped[UUID | None] = mapped_column(unique=True)
    release_request_hash: Mapped[str | None] = mapped_column(String(64))


class BackupHold(Base):
    __tablename__ = "backup_holds"
    __table_args__ = (
        UniqueConstraint("backup_id", "holder_kind", "holder_id", name="uq_backup_hold_holder"),
        CheckConstraint(
            "holder_kind IN ('job','download','restore_intent')", name="ck_backup_hold_kind"
        ),
        CheckConstraint(
            "(holder_kind='download' AND job_id IS NULL) OR "
            "(holder_kind IN ('job','restore_intent') AND job_id IS NOT NULL "
            "AND job_id=holder_id)",
            name="ck_backup_hold_job",
        ),
        CheckConstraint(
            "(version=1 AND released_at IS NULL AND release_proof IS NULL) OR "
            "(version=2 AND released_at IS NOT NULL AND release_proof IS NOT NULL "
            "AND release_proof IN "
            "('archive_built','job_terminal_verified','explicit_reconcile'))",
            name="ck_backup_hold_lifecycle",
        ),
        CheckConstraint(
            "released_at IS NULL OR released_at>=created_at", name="ck_backup_hold_time"
        ),
        Index("ix_backup_hold_active", "backup_id", "released_at"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    backup_id: Mapped[UUID] = mapped_column(ForeignKey("backup_controls.backup_id"))
    version: Mapped[int] = mapped_column(BigInteger, default=1, server_default="1")
    holder_kind: Mapped[str] = mapped_column(String(24))
    holder_id: Mapped[UUID]
    job_id: Mapped[UUID | None] = mapped_column(ForeignKey("background_jobs.id"))
    owner_user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    released_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    release_proof: Mapped[str | None] = mapped_column(String(32))


class BackupRetentionIntent(Base):
    __tablename__ = "backup_retention_intents"
    __table_args__ = (
        CheckConstraint("config_version>=0", name="ck_backup_intent_version"),
        CheckConstraint(
            "request_hash ~ '^[0-9a-f]{64}$' AND selection_sha256 ~ '^[0-9a-f]{64}$'",
            name="ck_backup_intent_hashes",
        ),
        CheckConstraint(
            "jsonb_typeof(packages)='array' AND jsonb_array_length(packages) BETWEEN 1 AND 20",
            name="ck_backup_intent_packages",
        ),
        Index("ix_backup_intent_actor_created", "actor_id", "created_at"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    preview_id: Mapped[UUID] = mapped_column(unique=True)
    actor_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"))
    origin_session_id: Mapped[UUID] = mapped_column(ForeignKey("sessions.id"))
    request_id: Mapped[UUID] = mapped_column(unique=True)
    request_hash: Mapped[str] = mapped_column(String(64))
    selection_sha256: Mapped[str] = mapped_column(String(64))
    config_version: Mapped[int] = mapped_column(BigInteger)
    source_instance_id: Mapped[UUID]
    source_epoch: Mapped[UUID]
    packages: Mapped[list] = mapped_column(JSONB)
    job_id: Mapped[UUID] = mapped_column(ForeignKey("background_jobs.id"), unique=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


@event.listens_for(BackupRetentionIntent, "before_update")
@event.listens_for(BackupRetentionIntent, "before_delete")
def immutable_intent(mapper, connection, target):
    # The migration must additionally install a PostgreSQL trigger so raw SQL
    # cannot bypass this ORM guard. No migration/registry is installed here.
    raise ValueError("backup_retention_intent_immutable")
