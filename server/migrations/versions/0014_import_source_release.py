"""Release import source with an append-only deletion receipt."""

import sqlalchemy as sa
from alembic import op

revision = "0014_import_source_release"
down_revision = "0013_backup_retention"
branch_labels = None
depends_on = None

LIFECYCLE_UP = r"""-- Frozen candidate; root alone installs it with the 0014 schema migration.
-- Composite marker FK pairs its non-NULL timestamp with the append-only audit.
CREATE FUNCTION public.flowtrace_import_source_release_immutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $guard$
BEGIN
    RAISE EXCEPTION USING
        ERRCODE = '55000', MESSAGE = 'import_stage_source_release_immutable';
END;
$guard$;

CREATE FUNCTION public.flowtrace_import_source_marker_immutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $guard$
BEGIN
    IF OLD.source_released_at IS NOT NULL
       AND NEW.source_released_at IS DISTINCT FROM OLD.source_released_at THEN
        RAISE EXCEPTION USING
            ERRCODE = '55000', MESSAGE = 'import_stage_source_marker_immutable';
    END IF;
    RETURN NEW;
END;
$guard$;

CREATE TRIGGER tr_import_source_release_immutable
BEFORE UPDATE OR DELETE ON public.import_stage_source_releases
FOR EACH ROW EXECUTE FUNCTION public.flowtrace_import_source_release_immutable();

CREATE TRIGGER tr_import_source_release_no_truncate
BEFORE TRUNCATE ON public.import_stage_source_releases
FOR EACH STATEMENT EXECUTE FUNCTION public.flowtrace_import_source_release_immutable();

CREATE TRIGGER tr_import_source_marker_immutable
BEFORE UPDATE ON public.import_stages
FOR EACH ROW EXECUTE FUNCTION public.flowtrace_import_source_marker_immutable();
"""

LIFECYCLE_DOWN = r"""DROP TRIGGER tr_import_source_marker_immutable ON public.import_stages;
DROP TRIGGER tr_import_source_release_no_truncate ON public.import_stage_source_releases;
DROP TRIGGER tr_import_source_release_immutable ON public.import_stage_source_releases;
DROP FUNCTION public.flowtrace_import_source_marker_immutable();
DROP FUNCTION public.flowtrace_import_source_release_immutable();
"""


def upgrade():
    op.add_column(
        "import_stages",
        sa.Column("source_released_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_table(
        "import_stage_source_releases",
        sa.Column("stage_id", sa.Uuid(), nullable=False),
        sa.Column("batch_id", sa.Uuid(), nullable=False),
        sa.Column("owner_user_id", sa.Uuid(), nullable=False),
        sa.Column("origin_session_id", sa.Uuid(), nullable=False),
        sa.Column("origin_purpose", sa.String(length=16), nullable=False),
        sa.Column("client_id", sa.Uuid(), nullable=False),
        sa.Column("sync_epoch", sa.Uuid(), nullable=False),
        sa.Column("stage_version", sa.BigInteger(), nullable=False),
        sa.Column("request_id", sa.Uuid(), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("source_sha256", sa.String(length=64), nullable=False),
        sa.Column("preview_hash", sa.String(length=64), nullable=False),
        sa.Column("reserved_bytes_released", sa.BigInteger(), nullable=False),
        sa.Column("received_bytes_snapshot", sa.BigInteger(), nullable=False),
        sa.Column("received_chunks_snapshot", sa.Integer(), nullable=False),
        sa.Column("source_rows_snapshot", sa.Integer(), nullable=False),
        sa.Column("deleted_source_bytes", sa.BigInteger(), nullable=False),
        sa.Column("deleted_source_chunks", sa.Integer(), nullable=False),
        sa.Column("deleted_preview_rows", sa.Integer(), nullable=False),
        sa.Column("released_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "origin_purpose IN ('api_native','api_web')",
            name="ck_source_release_purpose",
        ),
        sa.CheckConstraint(
            "request_hash ~ '^[0-9a-f]{64}$' AND source_sha256 ~ '^[0-9a-f]{64}$' AND preview_hash ~ '^[0-9a-f]{64}$'",
            name="ck_source_release_hashes",
        ),
        sa.CheckConstraint(
            "deleted_source_chunks BETWEEN 0 AND received_chunks_snapshot AND deleted_source_bytes BETWEEN 0 AND received_bytes_snapshot AND ((deleted_source_chunks=0 AND deleted_source_bytes=0) OR (deleted_source_chunks>0 AND deleted_source_bytes BETWEEN deleted_source_chunks AND deleted_source_chunks::bigint*524288))",
            name="ck_source_release_actual_bytes",
        ),
        sa.CheckConstraint(
            "reserved_bytes_released BETWEEN 1 AND 52428800 AND received_bytes_snapshot=reserved_bytes_released AND received_chunks_snapshot=(reserved_bytes_released+524287)/524288",
            name="ck_source_release_received",
        ),
        sa.CheckConstraint(
            "source_rows_snapshot BETWEEN 1 AND 200000 AND deleted_preview_rows BETWEEN 0 AND source_rows_snapshot",
            name="ck_source_release_rows",
        ),
        sa.CheckConstraint(
            "stage_version BETWEEN 1 AND 2147483647", name="ck_source_release_version"
        ),
        sa.ForeignKeyConstraint(
            ["batch_id"],
            ["import_batches.id"],
        ),
        sa.ForeignKeyConstraint(
            ["origin_session_id"],
            ["sessions.id"],
        ),
        sa.ForeignKeyConstraint(
            ["owner_user_id"],
            ["users.id"],
        ),
        sa.ForeignKeyConstraint(
            ["stage_id", "batch_id"],
            ["import_stages.id", "import_stages.batch_id"],
            name="fk_source_release_stage_batch",
        ),
        sa.PrimaryKeyConstraint("stage_id"),
        sa.UniqueConstraint(
            "owner_user_id", "request_id", name="uq_source_release_request"
        ),
        sa.UniqueConstraint("stage_id", "released_at", name="uq_source_release_marker"),
    )
    op.create_index(
        "ix_source_release_owner_time",
        "import_stage_source_releases",
        ["owner_user_id", "released_at", "stage_id"],
        unique=False,
    )
    op.create_check_constraint(
        "ck_stage_source_release",
        "import_stages",
        "source_released_at IS NULL OR (status IN ('applied','undoing','undone') AND sealed_at IS NOT NULL AND received_bytes=expected_bytes AND received_chunks=expected_chunks AND source_released_at>=created_at)",
    )
    op.create_foreign_key(
        "fk_stage_source_release_receipt",
        "import_stages",
        "import_stage_source_releases",
        ["id", "source_released_at"],
        ["stage_id", "released_at"],
        use_alter=True,
    )
    op.execute(sa.text(LIFECYCLE_UP))


def downgrade():
    op.execute(sa.text(LIFECYCLE_DOWN))
    op.drop_constraint(
        "fk_stage_source_release_receipt", "import_stages", type_="foreignkey"
    )
    op.drop_table("import_stage_source_releases")
    op.drop_constraint("ck_stage_source_release", "import_stages", type_="check")
    op.drop_column("import_stages", "source_released_at")
