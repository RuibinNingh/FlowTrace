from datetime import datetime
from uuid import UUID

from sqlalchemy import BigInteger, CheckConstraint, DateTime, ForeignKey, String
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from flowtrace_server.persistence.models import Base


class AssetConfigState(Base):
    __tablename__ = "asset_config_states"
    __table_args__ = (CheckConstraint("revision >= 0", name="ck_asset_config_revision"),)
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    revision: Mapped[int] = mapped_column(BigInteger, default=0)


class AssetGroup(Base):
    __tablename__ = "asset_groups"
    __table_args__ = (
        CheckConstraint("revision > 0", name="ck_asset_group_revision"),
        CheckConstraint("sort_order >= 0", name="ck_asset_group_sort"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    name: Mapped[str] = mapped_column(String(80))
    sort_order: Mapped[int]
    revision: Mapped[int] = mapped_column(BigInteger)
    deleted: Mapped[bool] = mapped_column(default=False)


class AssetConfigReceipt(Base):
    __tablename__ = "asset_config_receipts"
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    operation_id: Mapped[UUID] = mapped_column(primary_key=True)
    client_id: Mapped[UUID]
    sync_epoch: Mapped[UUID]
    content_hash: Mapped[str] = mapped_column(String(64))
    result: Mapped[dict] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
