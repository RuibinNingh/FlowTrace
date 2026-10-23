"""Bounded administrator audit pagination and filtered lookup indexes."""

from alembic import op

revision = "0008_admin_audit_indexes"
down_revision = "0007_import_batches"
branch_labels = None
depends_on = None


def upgrade():
    op.create_index("ix_admin_audit_created_id", "admin_audit", ["created_at", "id"])
    op.create_index("ix_admin_audit_actor_created", "admin_audit", ["actor_id", "created_at"])
    op.create_index("ix_admin_audit_action_created", "admin_audit", ["action", "created_at"])


def downgrade():
    op.drop_index("ix_admin_audit_action_created", table_name="admin_audit")
    op.drop_index("ix_admin_audit_actor_created", table_name="admin_audit")
    op.drop_index("ix_admin_audit_created_id", table_name="admin_audit")
