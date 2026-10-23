"""Persistent deployment identity and synchronization epoch."""

from uuid import uuid4

import sqlalchemy as sa
from alembic import op

revision = "0001_server_state"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    table = op.create_table(
        "server_state",
        sa.Column("singleton_id", sa.Integer(), primary_key=True),
        sa.Column("instance_id", sa.Uuid(), nullable=False),
        sa.Column("sync_epoch", sa.Uuid(), nullable=False),
        sa.CheckConstraint("singleton_id = 1", name="ck_server_state_singleton"),
    )
    op.bulk_insert(table, [{"singleton_id": 1, "instance_id": uuid4(), "sync_epoch": uuid4()}])


def downgrade() -> None:
    raise RuntimeError("No automatic data downgrade; use a reviewed restoration procedure")
