"""Atomic import provenance; existing raw sync data and receipts stay unchanged."""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0007_import_batches"
down_revision = "0006_assets_currencies"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "import_batches",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("client_id", sa.Uuid(), nullable=False),
        sa.Column("sync_epoch", sa.Uuid(), nullable=False),
        sa.Column("source_namespace", sa.String(80), nullable=False),
        sa.Column("content_hash", sa.String(64), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("required_scopes", postgresql.JSONB(), nullable=False),
        sa.Column("result", postgresql.JSONB(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("status IN ('applied','undone')", name="ck_import_status"),
    )
    op.create_index("ix_import_batches_user_id", "import_batches", ["user_id"])
    op.create_table(
        "import_items",
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id"), primary_key=True),
        sa.Column("source_namespace", sa.String(80), primary_key=True),
        sa.Column("source_id", sa.Uuid(), primary_key=True),
        sa.Column("batch_id", sa.Uuid(), sa.ForeignKey("import_batches.id"), nullable=False),
        sa.Column("entity_id", sa.Uuid(), sa.ForeignKey("sync_entities.id"), nullable=False),
        sa.Column("entity_type", sa.String(16), nullable=False),
        sa.Column("scope_id", sa.Uuid(), sa.ForeignKey("sync_scopes.id"), nullable=False),
        sa.Column("revision", sa.BigInteger(), nullable=False),
        sa.Column("payload_hash", sa.String(64), nullable=False),
        sa.Column("source_hash", sa.String(64), nullable=False),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.UniqueConstraint("entity_id"),
    )
    op.create_index("ix_import_items_batch_id", "import_items", ["batch_id"])


def downgrade():
    raise RuntimeError("No automatic data downgrade; use reviewed restoration")
