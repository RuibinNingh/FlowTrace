"""Private asset configuration with frozen-command receipts; sync JSON is untouched."""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0006_assets_currencies"
down_revision = "0005_attachment_tickets"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "asset_config_states",
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id"), primary_key=True),
        sa.Column("revision", sa.BigInteger(), nullable=False),
        sa.CheckConstraint("revision >= 0", name="ck_asset_config_revision"),
    )
    op.create_table(
        "asset_groups",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("name", sa.String(80), nullable=False),
        sa.Column("sort_order", sa.Integer(), nullable=False),
        sa.Column("revision", sa.BigInteger(), nullable=False),
        sa.Column("deleted", sa.Boolean(), nullable=False),
        sa.CheckConstraint("revision > 0", name="ck_asset_group_revision"),
        sa.CheckConstraint("sort_order >= 0", name="ck_asset_group_sort"),
    )
    op.create_index("ix_asset_groups_user_id", "asset_groups", ["user_id"])
    op.create_table(
        "currency_preferences",
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id"), primary_key=True),
        sa.Column("base_currency", sa.String(3), nullable=False),
        sa.Column("enabled_codes", postgresql.JSONB(), nullable=False),
        sa.Column("valuation_policy", sa.String(24), nullable=False),
    )
    op.create_table(
        "valuation_rates",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("from_currency", sa.String(3), nullable=False),
        sa.Column("to_currency", sa.String(3), nullable=False),
        sa.Column("effective_date", sa.Date(), nullable=False),
        sa.Column("rate", sa.Numeric(38, 18), nullable=False),
        sa.Column("rate_text", sa.String(39), nullable=False),
        sa.Column("rate_source", sa.String(80), nullable=False),
        sa.Column("revision", sa.BigInteger(), nullable=False),
        sa.Column("deleted", sa.Boolean(), nullable=False),
        sa.CheckConstraint("rate > 0 AND rate < 100000000000000000000", name="ck_valuation_rate"),
        sa.CheckConstraint("from_currency <> to_currency", name="ck_valuation_pair"),
        sa.CheckConstraint("revision > 0", name="ck_valuation_revision"),
    )
    op.create_index("ix_valuation_rates_user_id", "valuation_rates", ["user_id"])
    op.create_index(
        "uq_valuation_pair_date",
        "valuation_rates",
        ["user_id", "from_currency", "to_currency", "effective_date"],
        unique=True,
        postgresql_where=sa.text("NOT deleted"),
    )
    op.create_table(
        "asset_config_receipts",
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id"), primary_key=True),
        sa.Column("operation_id", sa.Uuid(), primary_key=True),
        sa.Column("client_id", sa.Uuid(), nullable=False),
        sa.Column("sync_epoch", sa.Uuid(), nullable=False),
        sa.Column("content_hash", sa.String(64), nullable=False),
        sa.Column("result", postgresql.JSONB(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    raise RuntimeError("No automatic data downgrade; use reviewed restoration")
