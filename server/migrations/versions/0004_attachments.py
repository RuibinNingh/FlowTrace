"""Private attachment states, authoritative bill references and conservative holds."""

import sqlalchemy as sa
from alembic import op

revision = "0004_attachments"
down_revision = "0003_sync_transactions"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "attachments",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("upload_id", sa.Uuid(), nullable=False, unique=True),
        sa.Column("scope_id", sa.Uuid(), sa.ForeignKey("sync_scopes.id"), nullable=False),
        sa.Column("created_by", sa.Uuid(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("sha256", sa.String(64), nullable=False),
        sa.Column("size_bytes", sa.BigInteger(), nullable=False),
        sa.Column("media_type", sa.String(20), nullable=False),
        sa.Column("storage_key", sa.String(64), nullable=False, unique=True),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("upload_expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ready_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("orphaned_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("width", sa.Integer(), nullable=True),
        sa.Column("height", sa.Integer(), nullable=True),
        sa.CheckConstraint(
            "status IN ('pending','uploaded','ready','deleting','deleted')",
            name="ck_attachment_status",
        ),
        sa.CheckConstraint("size_bytes BETWEEN 1 AND 10485760", name="ck_attachment_size"),
        sa.CheckConstraint(
            "media_type IN ('image/jpeg','image/png','image/webp')", name="ck_attachment_media"
        ),
    )
    op.create_index("ix_attachments_gc", "attachments", ["status", "orphaned_at"])
    op.create_table(
        "attachment_refs",
        sa.Column("bill_id", sa.Uuid(), sa.ForeignKey("sync_entities.id"), primary_key=True),
        sa.Column("attachment_id", sa.Uuid(), sa.ForeignKey("attachments.id"), primary_key=True),
    )
    op.create_table(
        "attachment_holds",
        sa.Column("hold_id", sa.Uuid(), primary_key=True),
        sa.Column("attachment_id", sa.Uuid(), sa.ForeignKey("attachments.id"), primary_key=True),
        sa.Column("kind", sa.String(16), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("kind IN ('job','backup')", name="ck_attachment_hold_kind"),
    )


def downgrade() -> None:
    raise RuntimeError("No automatic data downgrade; use reviewed restoration")
