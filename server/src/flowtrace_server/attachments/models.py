from datetime import datetime
from uuid import UUID

from sqlalchemy import BigInteger, CheckConstraint, DateTime, ForeignKey, Index, String
from sqlalchemy.orm import Mapped, mapped_column

from flowtrace_server.persistence.models import Base


class Attachment(Base):
    __tablename__ = "attachments"
    __table_args__ = (
        CheckConstraint(
            "status IN ('pending','uploaded','ready','deleting','deleted')",
            name="ck_attachment_status",
        ),
        CheckConstraint("size_bytes BETWEEN 1 AND 10485760", name="ck_attachment_size"),
        CheckConstraint(
            "media_type IN ('image/jpeg','image/png','image/webp')", name="ck_attachment_media"
        ),
        Index("ix_attachments_gc", "status", "orphaned_at"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    upload_id: Mapped[UUID] = mapped_column(unique=True)
    scope_id: Mapped[UUID] = mapped_column(ForeignKey("sync_scopes.id"))
    created_by: Mapped[UUID] = mapped_column(ForeignKey("users.id"))
    sha256: Mapped[str] = mapped_column(String(64))
    size_bytes: Mapped[int] = mapped_column(BigInteger)
    media_type: Mapped[str] = mapped_column(String(20))
    storage_key: Mapped[str] = mapped_column(String(64), unique=True)
    status: Mapped[str] = mapped_column(String(16))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    upload_expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    ready_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    orphaned_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    width: Mapped[int | None]
    height: Mapped[int | None]


class AttachmentRef(Base):
    __tablename__ = "attachment_refs"
    bill_id: Mapped[UUID] = mapped_column(ForeignKey("sync_entities.id"), primary_key=True)
    attachment_id: Mapped[UUID] = mapped_column(ForeignKey("attachments.id"), primary_key=True)


class AttachmentHold(Base):
    __tablename__ = "attachment_holds"
    __table_args__ = (CheckConstraint("kind IN ('job','backup')", name="ck_attachment_hold_kind"),)
    hold_id: Mapped[UUID] = mapped_column(primary_key=True)
    attachment_id: Mapped[UUID] = mapped_column(ForeignKey("attachments.id"), primary_key=True)
    kind: Mapped[str] = mapped_column(String(16))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class UploadTicket(Base):
    __tablename__ = "attachment_upload_tickets"
    upload_id: Mapped[UUID] = mapped_column(primary_key=True)
    attachment_id: Mapped[UUID] = mapped_column(ForeignKey("attachments.id"), index=True)
    created_by: Mapped[UUID] = mapped_column(ForeignKey("users.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
