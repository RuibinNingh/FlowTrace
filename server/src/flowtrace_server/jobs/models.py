from datetime import datetime
from uuid import UUID

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    String,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from flowtrace_server.persistence.models import Base


class BackgroundJob(Base):
    __tablename__ = "background_jobs"
    __table_args__ = (
        UniqueConstraint("kind", "occurrence_key", name="uq_job_occurrence"),
        CheckConstraint(
            "status IN ('pending','running','succeeded','retry_wait','failed','cancelled')",
            name="ck_job_status",
        ),
        CheckConstraint(
            "kind IN ('recurring_occurrence','installment_occurrence','import_preview',"
            "'import_apply','export','backup_create','backup_verify','restore_rehearsal',"
            "'backup_quarantine')",
            name="ck_job_kind",
        ),
        CheckConstraint("attempt >= 0 AND attempt <= 5", name="ck_job_attempt"),
        CheckConstraint("lease_generation >= 0 AND manual_retries >= 0", name="ck_job_generation"),
        CheckConstraint(
            "(status='running' AND lease_owner IS NOT NULL AND lease_until IS NOT NULL) OR "
            "(status<>'running' AND lease_owner IS NULL AND lease_until IS NULL)",
            name="ck_job_lease",
        ),
        Index("ix_job_available", "status", "available_at", "id"),
        Index("ix_job_owner_created", "owner_user_id", "created_at", "id"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    kind: Mapped[str] = mapped_column(String(32))
    occurrence_key: Mapped[str] = mapped_column(String(200))
    owner_user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"))
    scope_id: Mapped[UUID | None] = mapped_column(ForeignKey("sync_scopes.id"))
    sync_epoch: Mapped[UUID]
    rule_revision: Mapped[int | None] = mapped_column(BigInteger)
    payload: Mapped[dict] = mapped_column(JSONB)
    payload_hash: Mapped[str] = mapped_column(String(64))
    status: Mapped[str] = mapped_column(String(16))
    available_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    attempt: Mapped[int] = mapped_column(default=0)
    manual_retries: Mapped[int] = mapped_column(default=0)
    lease_owner: Mapped[UUID | None]
    lease_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    lease_generation: Mapped[int] = mapped_column(BigInteger, default=0)
    result: Mapped[dict | None] = mapped_column(JSONB)
    error_code: Mapped[str | None] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class JobAttempt(Base):
    __tablename__ = "job_attempts"
    job_id: Mapped[UUID] = mapped_column(ForeignKey("background_jobs.id"), primary_key=True)
    generation: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    worker_id: Mapped[UUID]
    status: Mapped[str] = mapped_column(String(20))
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    error_code: Mapped[str | None] = mapped_column(String(64))


class WorkerState(Base):
    __tablename__ = "worker_states"
    id: Mapped[UUID] = mapped_column(primary_key=True)
    version: Mapped[str] = mapped_column(String(32))
    supported_kinds: Mapped[list] = mapped_column(JSONB)
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    heartbeat_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    active_job_id: Mapped[UUID | None] = mapped_column(ForeignKey("background_jobs.id"))
