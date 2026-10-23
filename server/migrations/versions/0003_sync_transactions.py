"""Exact account postings, immutable receipts and bounded materialized sync pages."""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0003_sync_transactions"
down_revision = "0002_identity_books"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "books", sa.Column("deleted", sa.Boolean(), nullable=False, server_default=sa.false())
    )
    op.create_table(
        "sync_clients",
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id"), primary_key=True),
        sa.Column("client_id", sa.Uuid(), primary_key=True),
        sa.Column("sync_epoch", sa.Uuid(), nullable=False),
        sa.Column("valid_until", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("frozen", sa.Boolean(), nullable=False),
        sa.Column("known_scope_ids", postgresql.JSONB(), nullable=False),
    )
    op.create_table(
        "sync_entities",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("scope_id", sa.Uuid(), sa.ForeignKey("sync_scopes.id"), nullable=False),
        sa.Column("entity_type", sa.String(16), nullable=False),
        sa.Column("revision", sa.BigInteger(), nullable=False),
        sa.Column("deleted", sa.Boolean(), nullable=False),
        sa.Column("payload", postgresql.JSONB(), nullable=False),
        sa.Column("balance_minor", sa.BigInteger(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("revision >= 0", name="ck_entity_revision"),
        sa.CheckConstraint(
            "entity_type IN ('book','account','category','tag','bill','budget')",
            name="ck_entity_type",
        ),
    )
    op.create_index("ix_sync_entities_scope", "sync_entities", ["scope_id", "entity_type"])
    op.create_table(
        "ledger_entries",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("bill_id", sa.Uuid(), sa.ForeignKey("sync_entities.id"), nullable=False),
        sa.Column("account_id", sa.Uuid(), sa.ForeignKey("sync_entities.id"), nullable=False),
        sa.Column("book_id", sa.Uuid(), sa.ForeignKey("books.id"), nullable=False),
        sa.Column("component", sa.String(16), nullable=False),
        sa.Column("amount_minor", sa.BigInteger(), nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("currency_scale", sa.Integer(), nullable=False),
        sa.Column("business_date", sa.Date(), nullable=False),
        sa.UniqueConstraint("bill_id", "account_id", "component", name="uq_entry_component"),
        sa.CheckConstraint("amount_minor <> 0", name="ck_entry_nonzero"),
        sa.CheckConstraint("currency_scale BETWEEN 0 AND 6", name="ck_entry_scale"),
    )
    op.create_index("ix_ledger_entries_account", "ledger_entries", ["account_id"])
    op.create_table(
        "sync_receipts",
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id"), primary_key=True),
        sa.Column("client_id", sa.Uuid(), primary_key=True),
        sa.Column("operation_id", sa.Uuid(), primary_key=True),
        sa.Column("content_hash", sa.String(64), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("result", postgresql.JSONB(), nullable=False),
        sa.Column("required_scope_ids", postgresql.JSONB(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("status IN ('applied','rejected')", name="ck_receipt_status"),
    )
    op.create_table(
        "sync_changes",
        sa.Column("scope_id", sa.Uuid(), sa.ForeignKey("sync_scopes.id"), primary_key=True),
        sa.Column("scope_revision", sa.BigInteger(), primary_key=True),
        sa.Column("event_index", sa.Integer(), primary_key=True),
        sa.Column("commit_id", sa.Uuid(), nullable=False),
        sa.Column("entity_type", sa.String(16), nullable=False),
        sa.Column("entity_id", sa.Uuid(), nullable=False),
        sa.Column("revision", sa.BigInteger(), nullable=False),
        sa.Column("deleted", sa.Boolean(), nullable=False),
        sa.Column("data", postgresql.JSONB(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("scope_revision >= 0", name="ck_change_revision"),
        sa.CheckConstraint("event_index BETWEEN 0 AND 199", name="ck_change_index"),
    )
    op.create_index("ix_sync_changes_commit", "sync_changes", ["commit_id"])
    op.create_table(
        "sync_pull_sessions",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("client_id", sa.Uuid(), nullable=False),
        sa.Column("sync_epoch", sa.Uuid(), nullable=False),
        sa.Column("control_version", sa.BigInteger(), nullable=False),
        sa.Column("permission_versions", postgresql.JSONB(), nullable=False),
        sa.Column("checkpoint", postgresql.JSONB(), nullable=False),
        sa.Column("cursors", postgresql.JSONB(), nullable=False),
        sa.Column("page_limit", sa.Integer(), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "sync_pull_pages",
        sa.Column("token_hash", sa.String(64), primary_key=True),
        sa.Column("pull_id", sa.Uuid(), sa.ForeignKey("sync_pull_sessions.id"), nullable=False),
        sa.Column("page_index", sa.Integer(), nullable=False),
        sa.Column("response", postgresql.JSONB(), nullable=False),
    )
    op.create_table(
        "sync_snapshots",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("client_id", sa.Uuid(), nullable=False),
        sa.Column("sync_epoch", sa.Uuid(), nullable=False),
        sa.Column("control_version", sa.BigInteger(), nullable=False),
        sa.Column("permission_versions", postgresql.JSONB(), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("manifest", postgresql.JSONB(), nullable=False),
        sa.Column("manifest_sha256", sa.String(64), nullable=False),
        sa.Column("first_page_token", sa.String(128), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "sync_snapshot_pages",
        sa.Column("token_hash", sa.String(64), primary_key=True),
        sa.Column("snapshot_id", sa.Uuid(), sa.ForeignKey("sync_snapshots.id"), nullable=False),
        sa.Column("page_index", sa.Integer(), nullable=False),
        sa.Column("response", postgresql.JSONB(), nullable=False),
    )
    # Existing books have no historical sync event. Their revision-zero baseline
    # is included in snapshots. Runtime creation uses initialize_book_sync -> 1.
    op.execute(
        sa.text("""
        INSERT INTO sync_entities
              (id, scope_id, entity_type, revision, deleted, payload,
               balance_minor, created_at, updated_at)
        SELECT id, id, 'book', 0, false,
          jsonb_build_object('name', name, 'currency', currency, 'timezone', timezone,
                             'month_start_day', month_start_day),
          NULL, created_at, created_at
        FROM books
    """)
    )


def downgrade() -> None:
    raise RuntimeError("No automatic data downgrade; use reviewed restoration")
