from datetime import datetime
from uuid import UUID

from sqlalchemy import BigInteger, CheckConstraint, DateTime, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column

from flowtrace_server.persistence.models import Base


class Book(Base):
    __tablename__ = "books"
    id: Mapped[UUID] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(100))
    currency: Mapped[str] = mapped_column(String(3), default="CNY")
    timezone: Mapped[str] = mapped_column(String(64), default="Asia/Shanghai")
    month_start_day: Mapped[int] = mapped_column(default=1)
    owner_user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"))
    shared: Mapped[bool] = mapped_column(default=False)
    deleted: Mapped[bool] = mapped_column(default=False, server_default="false")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class BookMembership(Base):
    __tablename__ = "book_memberships"
    __table_args__ = (
        CheckConstraint("role IN ('owner','editor','viewer')", name="ck_member_role"),
    )
    book_id: Mapped[UUID] = mapped_column(ForeignKey("books.id"), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    role: Mapped[str] = mapped_column(String(16))
    active: Mapped[bool] = mapped_column(default=True)


class SyncScope(Base):
    __tablename__ = "sync_scopes"
    __table_args__ = (CheckConstraint("kind IN ('user','book')", name="ck_scope_kind"),)
    id: Mapped[UUID] = mapped_column(primary_key=True)
    kind: Mapped[str] = mapped_column(String(16))
    owner_user_id: Mapped[UUID | None] = mapped_column(ForeignKey("users.id"))
    book_id: Mapped[UUID | None] = mapped_column(ForeignKey("books.id"))
    revision: Mapped[int] = mapped_column(BigInteger, default=0)
    permission_version: Mapped[int] = mapped_column(BigInteger, default=1)


class BookInvite(Base):
    __tablename__ = "book_invites"
    id: Mapped[UUID] = mapped_column(primary_key=True)
    book_id: Mapped[UUID] = mapped_column(ForeignKey("books.id"))
    token_hash: Mapped[str] = mapped_column(String(64), unique=True)
    role: Mapped[str] = mapped_column(String(16))
    created_by: Mapped[UUID] = mapped_column(ForeignKey("users.id"))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    consumed_by: Mapped[UUID | None] = mapped_column(ForeignKey("users.id"))
