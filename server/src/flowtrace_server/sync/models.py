"""PostgreSQL synchronization state, projections and exact account postings."""

from datetime import date, datetime
from uuid import UUID

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    Index,
    String,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from flowtrace_server.persistence.models import Base


class SyncClient(Base):
    __tablename__ = "sync_clients"
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    client_id: Mapped[UUID] = mapped_column(primary_key=True)
    sync_epoch: Mapped[UUID]
    valid_until: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    frozen: Mapped[bool] = mapped_column(default=False)
    known_scope_ids: Mapped[list] = mapped_column(JSONB, default=list)


class SyncEntity(Base):
    __tablename__ = "sync_entities"
    __table_args__ = (
        CheckConstraint("revision >= 0", name="ck_entity_revision"),
        CheckConstraint(
            "entity_type IN ('book','account','category','tag','bill','budget')",
            name="ck_entity_type",
        ),
        Index("ix_sync_entities_scope", "scope_id", "entity_type"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    scope_id: Mapped[UUID] = mapped_column(ForeignKey("sync_scopes.id"))
    entity_type: Mapped[str] = mapped_column(String(16))
    revision: Mapped[int] = mapped_column(BigInteger, default=1)
    deleted: Mapped[bool] = mapped_column(default=False)
    payload: Mapped[dict] = mapped_column(JSONB)
    balance_minor: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class LedgerEntry(Base):
    __tablename__ = "ledger_entries"
    __table_args__ = (
        UniqueConstraint("bill_id", "account_id", "component", name="uq_entry_component"),
        Index("ix_ledger_entries_account", "account_id"),
        CheckConstraint("amount_minor <> 0", name="ck_entry_nonzero"),
        CheckConstraint("currency_scale BETWEEN 0 AND 6", name="ck_entry_scale"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    bill_id: Mapped[UUID] = mapped_column(ForeignKey("sync_entities.id"))
    account_id: Mapped[UUID] = mapped_column(ForeignKey("sync_entities.id"))
    book_id: Mapped[UUID] = mapped_column(ForeignKey("books.id"))
    component: Mapped[str] = mapped_column(String(16))
    amount_minor: Mapped[int] = mapped_column(BigInteger)
    currency: Mapped[str] = mapped_column(String(3))
    currency_scale: Mapped[int]
    business_date: Mapped[date] = mapped_column(Date)


class SyncReceipt(Base):
    __tablename__ = "sync_receipts"
    __table_args__ = (
        CheckConstraint("status IN ('applied','rejected')", name="ck_receipt_status"),
    )
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    client_id: Mapped[UUID] = mapped_column(primary_key=True)
    operation_id: Mapped[UUID] = mapped_column(primary_key=True)
    content_hash: Mapped[str] = mapped_column(String(64))
    status: Mapped[str] = mapped_column(String(16))
    result: Mapped[dict] = mapped_column(JSONB)
    required_scope_ids: Mapped[list] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class SyncChange(Base):
    __tablename__ = "sync_changes"
    __table_args__ = (
        CheckConstraint("scope_revision >= 0", name="ck_change_revision"),
        CheckConstraint("event_index BETWEEN 0 AND 199", name="ck_change_index"),
        Index("ix_sync_changes_commit", "commit_id"),
    )
    scope_id: Mapped[UUID] = mapped_column(ForeignKey("sync_scopes.id"), primary_key=True)
    scope_revision: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    event_index: Mapped[int] = mapped_column(primary_key=True)
    commit_id: Mapped[UUID]
    entity_type: Mapped[str] = mapped_column(String(16))
    entity_id: Mapped[UUID]
    revision: Mapped[int] = mapped_column(BigInteger)
    deleted: Mapped[bool]
    data: Mapped[dict | None] = mapped_column(JSONB, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class PullSession(Base):
    __tablename__ = "sync_pull_sessions"
    id: Mapped[UUID] = mapped_column(primary_key=True)
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"))
    client_id: Mapped[UUID]
    sync_epoch: Mapped[UUID]
    control_version: Mapped[int] = mapped_column(BigInteger)
    permission_versions: Mapped[dict] = mapped_column(JSONB)
    checkpoint: Mapped[dict] = mapped_column(JSONB)
    cursors: Mapped[dict] = mapped_column(JSONB)
    page_limit: Mapped[int]
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class PullPage(Base):
    __tablename__ = "sync_pull_pages"
    token_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    pull_id: Mapped[UUID] = mapped_column(ForeignKey("sync_pull_sessions.id"))
    page_index: Mapped[int]
    response: Mapped[dict] = mapped_column(JSONB)


class SyncSnapshot(Base):
    __tablename__ = "sync_snapshots"
    id: Mapped[UUID] = mapped_column(primary_key=True)
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"))
    client_id: Mapped[UUID]
    sync_epoch: Mapped[UUID]
    control_version: Mapped[int] = mapped_column(BigInteger)
    permission_versions: Mapped[dict] = mapped_column(JSONB)
    status: Mapped[str] = mapped_column(String(16))
    manifest: Mapped[dict] = mapped_column(JSONB)
    manifest_sha256: Mapped[str] = mapped_column(String(64))
    first_page_token: Mapped[str] = mapped_column(String(128))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class SnapshotPage(Base):
    __tablename__ = "sync_snapshot_pages"
    token_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    snapshot_id: Mapped[UUID] = mapped_column(ForeignKey("sync_snapshots.id"))
    page_index: Mapped[int]
    response: Mapped[dict] = mapped_column(JSONB)
