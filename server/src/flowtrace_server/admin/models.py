from datetime import datetime
from uuid import UUID

from sqlalchemy import JSON, CheckConstraint, DateTime, ForeignKey, Index, String
from sqlalchemy.orm import Mapped, mapped_column

from flowtrace_server.persistence.models import Base


class AdminControl(Base):
    __tablename__ = "admin_control"
    __table_args__ = (CheckConstraint("id=1", name="ck_admin_control_singleton"),)
    id: Mapped[int] = mapped_column(primary_key=True)


class AdminAudit(Base):
    __tablename__ = "admin_audit"
    __table_args__ = (
        Index("ix_admin_audit_created_id", "created_at", "id"),
        Index("ix_admin_audit_actor_created", "actor_id", "created_at"),
        Index("ix_admin_audit_action_created", "action", "created_at"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    actor_id: Mapped[UUID | None] = mapped_column(ForeignKey("users.id"))
    action: Mapped[str] = mapped_column(String(64))
    target_id: Mapped[UUID | None]
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    summary: Mapped[dict] = mapped_column(JSON, default=dict)
