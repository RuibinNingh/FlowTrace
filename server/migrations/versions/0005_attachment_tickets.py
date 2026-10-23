"""Renewed uploads have separate tickets; old tickets cannot overwrite new attempts."""

import sqlalchemy as sa
from alembic import op

revision = "0005_attachment_tickets"
down_revision = "0004_attachments"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "attachment_upload_tickets",
        sa.Column("upload_id", sa.Uuid(), primary_key=True),
        sa.Column("attachment_id", sa.Uuid(), sa.ForeignKey("attachments.id"), nullable=False),
        sa.Column("created_by", sa.Uuid(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index(
        "ix_attachment_upload_tickets_attachment_id", "attachment_upload_tickets", ["attachment_id"]
    )
    op.execute(
        sa.text("""
        INSERT INTO attachment_upload_tickets(
            upload_id, attachment_id, created_by, created_at, expires_at)
        SELECT upload_id,id,created_by,created_at,upload_expires_at FROM attachments
    """)
    )


def downgrade() -> None:
    raise RuntimeError("No automatic data downgrade; use reviewed restoration")
