from datetime import datetime
from uuid import UUID

from sqlalchemy import BigInteger, CheckConstraint, DateTime, ForeignKey, String
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from flowtrace_server.persistence.models import Base


class ImportBatch(Base):
    __tablename__ = "import_batches"
    __table_args__ = (CheckConstraint("status IN ('applied','undone')", name="ck_import_status"),)
    id: Mapped[UUID] = mapped_column(primary_key=True)
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    client_id: Mapped[UUID]
    sync_epoch: Mapped[UUID]
    source_namespace: Mapped[str] = mapped_column(String(80))
    content_hash: Mapped[str] = mapped_column(String(64))
    status: Mapped[str] = mapped_column(String(16))
    required_scopes: Mapped[list] = mapped_column(JSONB)
    result: Mapped[dict] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class ImportItem(Base):
    __tablename__ = "import_items"
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    source_namespace: Mapped[str] = mapped_column(String(80), primary_key=True)
    source_id: Mapped[UUID] = mapped_column(primary_key=True)
    batch_id: Mapped[UUID] = mapped_column(ForeignKey("import_batches.id"), index=True)
    entity_id: Mapped[UUID] = mapped_column(ForeignKey("sync_entities.id"), unique=True)
    entity_type: Mapped[str] = mapped_column(String(16))
    scope_id: Mapped[UUID] = mapped_column(ForeignKey("sync_scopes.id"))
    revision: Mapped[int] = mapped_column(BigInteger)
    payload_hash: Mapped[str] = mapped_column(String(64))
    source_hash: Mapped[str] = mapped_column(String(64))
    position: Mapped[int]
