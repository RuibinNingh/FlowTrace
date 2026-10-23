"""Fixed-kind durable jobs, fenced attempt history and worker heartbeats."""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0009_background_jobs"
down_revision = "0008_admin_audit_indexes"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "background_jobs",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("kind", sa.String(32), nullable=False),
        sa.Column("occurrence_key", sa.String(200), nullable=False),
        sa.Column("owner_user_id", sa.Uuid(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("scope_id", sa.Uuid(), sa.ForeignKey("sync_scopes.id"), nullable=True),
        sa.Column("sync_epoch", sa.Uuid(), nullable=False),
        sa.Column("rule_revision", sa.BigInteger(), nullable=True),
        sa.Column("payload", postgresql.JSONB(), nullable=False),
        sa.Column("payload_hash", sa.String(64), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("available_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("attempt", sa.Integer(), nullable=False),
        sa.Column("manual_retries", sa.Integer(), nullable=False),
        sa.Column("lease_owner", sa.Uuid(), nullable=True),
        sa.Column("lease_until", sa.DateTime(timezone=True), nullable=True),
        sa.Column("lease_generation", sa.BigInteger(), nullable=False),
        sa.Column("result", postgresql.JSONB(), nullable=True),
        sa.Column("error_code", sa.String(64), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("kind", "occurrence_key", name="uq_job_occurrence"),
        sa.CheckConstraint(
            "status IN ('pending','running','succeeded','retry_wait','failed','cancelled')",
            name="ck_job_status",
        ),
        sa.CheckConstraint(
            "kind IN ('recurring_occurrence','installment_occurrence','import_preview',"
            "'import_apply','export','backup_create','backup_verify','restore_rehearsal')",
            name="ck_job_kind",
        ),
        sa.CheckConstraint("attempt >= 0 AND attempt <= 5", name="ck_job_attempt"),
        sa.CheckConstraint(
            "lease_generation >= 0 AND manual_retries >= 0", name="ck_job_generation"
        ),
        sa.CheckConstraint(
            "(status='running' AND lease_owner IS NOT NULL AND lease_until IS NOT NULL) OR "
            "(status<>'running' AND lease_owner IS NULL AND lease_until IS NULL)",
            name="ck_job_lease",
        ),
    )
    op.create_index("ix_job_available", "background_jobs", ["status", "available_at", "id"])
    op.create_index(
        "ix_job_owner_created", "background_jobs", ["owner_user_id", "created_at", "id"]
    )
    op.create_table(
        "job_attempts",
        sa.Column("job_id", sa.Uuid(), sa.ForeignKey("background_jobs.id"), primary_key=True),
        sa.Column("generation", sa.BigInteger(), primary_key=True),
        sa.Column("worker_id", sa.Uuid(), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("error_code", sa.String(64), nullable=True),
    )
    op.create_table(
        "worker_states",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("version", sa.String(32), nullable=False),
        sa.Column("supported_kinds", postgresql.JSONB(), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("heartbeat_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("active_job_id", sa.Uuid(), sa.ForeignKey("background_jobs.id"), nullable=True),
    )


def downgrade():
    raise RuntimeError("No automatic job-history downgrade; use reviewed restoration")
