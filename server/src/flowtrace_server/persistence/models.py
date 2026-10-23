from uuid import UUID

from sqlalchemy import CheckConstraint
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


class ServerState(Base):
    __tablename__ = "server_state"
    __table_args__ = (CheckConstraint("singleton_id = 1", name="ck_server_state_singleton"),)

    singleton_id: Mapped[int] = mapped_column(primary_key=True)
    instance_id: Mapped[UUID]
    sync_epoch: Mapped[UUID]
