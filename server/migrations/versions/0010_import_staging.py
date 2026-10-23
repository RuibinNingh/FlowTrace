"""Durable import source chunks, versioned rows and publication manifests."""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0010_import_staging"
down_revision = "0009_background_jobs"
branch_labels = None
depends_on = None


def upgrade():

    op.create_table(
        "import_stages",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("batch_id", sa.Uuid(), nullable=False),
        sa.Column("owner_user_id", sa.Uuid(), nullable=False),
        sa.Column("client_id", sa.Uuid(), nullable=False),
        sa.Column("sync_epoch", sa.Uuid(), nullable=False),
        sa.Column("origin_session_id", sa.Uuid(), nullable=False),
        sa.Column("origin_purpose", sa.String(length=16), nullable=False),
        sa.Column("format", sa.String(length=24), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("stage_version", sa.BigInteger(), nullable=False),
        sa.Column("expected_bytes", sa.BigInteger(), nullable=False),
        sa.Column("received_bytes", sa.BigInteger(), nullable=False),
        sa.Column("expected_chunks", sa.Integer(), nullable=False),
        sa.Column("received_chunks", sa.Integer(), nullable=False),
        sa.Column("source_sha256", sa.String(length=64), nullable=False),
        sa.Column("mapping", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("preview_version", sa.BigInteger(), nullable=True),
        sa.Column("preview_hash", sa.String(length=64), nullable=True),
        sa.Column("required_scopes", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("permission_versions", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("row_count", sa.Integer(), nullable=False),
        sa.Column("error_count", sa.Integer(), nullable=False),
        sa.Column("parse_job_id", sa.Uuid(), nullable=True),
        sa.Column("preview_job_id", sa.Uuid(), nullable=True),
        sa.Column("apply_job_id", sa.Uuid(), nullable=True),
        sa.Column("undo_job_id", sa.Uuid(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("sealed_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "format IN ('flowtrace_json','flowtrace_csv','flowtrace_xlsx',"
            "'qianji_csv','qianji_xlsx')",
            name="ck_stage_format",
        ),
        sa.CheckConstraint(
            "jsonb_typeof(mapping)='object' AND jsonb_typeof(permission_versions)='object' "
            "AND jsonb_typeof(required_scopes)='array'",
            name="ck_stage_json_shapes",
        ),
        sa.CheckConstraint("origin_purpose IN ('api_native','api_web')", name="ck_stage_purpose"),
        sa.CheckConstraint(
            "preview_hash IS NULL OR preview_hash ~ '^[0-9a-f]{64}$'", name="ck_stage_preview_hash"
        ),
        sa.CheckConstraint("source_sha256 ~ '^[0-9a-f]{64}$'", name="ck_stage_source_hash"),
        sa.CheckConstraint(
            "status IN ('uploading','uploaded','parsing','parsed','previewing','ready',"
            "'applying','applied','undoing','undone','failed','cancelled','expired')",
            name="ck_stage_status",
        ),
        sa.CheckConstraint(
            "status NOT IN ('ready','applying') OR "
            "(preview_hash IS NOT NULL AND preview_version IS NOT NULL "
            "AND preview_version=stage_version)",
            name="ck_stage_ready_preview",
        ),
        sa.CheckConstraint(
            "expected_bytes BETWEEN 1 AND 52428800 AND received_bytes BETWEEN 0 AND expected_bytes",
            name="ck_stage_bytes",
        ),
        sa.CheckConstraint(
            "expected_chunks = (expected_bytes + 524287) / 524288 "
            "AND received_chunks BETWEEN 0 AND expected_chunks",
            name="ck_stage_chunks",
        ),
        sa.CheckConstraint(
            "expires_at > created_at AND updated_at >= created_at", name="ck_stage_times"
        ),
        sa.CheckConstraint(
            "preview_version IS NULL OR preview_version BETWEEN 1 AND stage_version",
            name="ck_stage_preview_version",
        ),
        sa.CheckConstraint(
            "received_bytes = LEAST(received_chunks::bigint*524288, expected_bytes)",
            name="ck_stage_received_prefix",
        ),
        sa.CheckConstraint(
            "row_count BETWEEN 0 AND 200000 AND error_count BETWEEN 0 AND 20000000",
            name="ck_stage_counts",
        ),
        sa.CheckConstraint("stage_version BETWEEN 1 AND 2147483647", name="ck_stage_version"),
        sa.ForeignKeyConstraint(
            ["apply_job_id"],
            ["background_jobs.id"],
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
            ["parse_job_id"],
            ["background_jobs.id"],
        ),
        sa.ForeignKeyConstraint(
            ["preview_job_id"],
            ["background_jobs.id"],
        ),
        sa.ForeignKeyConstraint(
            ["undo_job_id"],
            ["background_jobs.id"],
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("batch_id"),
        sa.UniqueConstraint("id", "batch_id", name="uq_stage_id_batch"),
    )
    op.create_index(
        "ix_stage_expiry", "import_stages", ["status", "expires_at", "id"], unique=False
    )
    op.create_index(
        "ix_stage_owner_created",
        "import_stages",
        ["owner_user_id", "created_at", "id"],
        unique=False,
    )
    op.create_table(
        "import_publications",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("batch_id", sa.Uuid(), nullable=False),
        sa.Column("stage_id", sa.Uuid(), nullable=False),
        sa.Column("stage_version", sa.BigInteger(), nullable=False),
        sa.Column("action", sa.String(length=8), nullable=False),
        sa.Column("sync_epoch", sa.Uuid(), nullable=False),
        sa.Column("content_hash", sa.String(length=64), nullable=False),
        sa.Column("preview_hash", sa.String(length=64), nullable=False),
        sa.Column("chunk_count", sa.Integer(), nullable=False),
        sa.Column("event_count", sa.BigInteger(), nullable=False),
        sa.Column("events_sha256", sa.String(length=64), nullable=False),
        sa.Column("permission_versions", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("checkpoint", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("published_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("action IN ('apply','undo')", name="ck_publication_action"),
        sa.CheckConstraint(
            "content_hash ~ '^[0-9a-f]{64}$' AND preview_hash ~ '^[0-9a-f]{64}$' "
            "AND events_sha256 ~ '^[0-9a-f]{64}$'",
            name="ck_publication_hashes",
        ),
        sa.CheckConstraint(
            "jsonb_typeof(permission_versions)='object' AND jsonb_typeof(checkpoint)='object'",
            name="ck_publication_vectors",
        ),
        sa.CheckConstraint(
            "chunk_count BETWEEN 0 AND 2000 "
            "AND event_count BETWEEN chunk_count AND chunk_count*200",
            name="ck_publication_counts",
        ),
        sa.CheckConstraint("stage_version BETWEEN 1 AND 2147483647", name="ck_publication_version"),
        sa.ForeignKeyConstraint(
            ["batch_id"],
            ["import_batches.id"],
        ),
        sa.ForeignKeyConstraint(
            ["stage_id", "batch_id"],
            ["import_stages.id", "import_stages.batch_id"],
            name="fk_publication_stage_batch",
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("batch_id", "action", name="uq_import_publication_action"),
    )
    op.create_index(
        "ix_publication_stage_action",
        "import_publications",
        ["stage_id", "action", "id"],
        unique=False,
    )
    op.create_table(
        "import_stage_rows",
        sa.Column("stage_id", sa.Uuid(), nullable=False),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.Column("source_line", sa.Integer(), nullable=False),
        sa.Column("source_id", sa.Uuid(), nullable=True),
        sa.Column(
            "row_payload", postgresql.JSONB(none_as_null=True, astext_type=sa.Text()), nullable=True
        ),
        sa.Column("raw_hash", sa.String(length=64), nullable=False),
        sa.Column("parsed_version", sa.BigInteger(), nullable=False),
        sa.Column("preview_version", sa.BigInteger(), nullable=True),
        sa.Column("dependencies", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("topological_position", sa.Integer(), nullable=True),
        sa.Column("target_entity_id", sa.Uuid(), nullable=True),
        sa.Column("mapped_hash", sa.String(length=64), nullable=True),
        sa.Column("preview_status", sa.String(length=32), nullable=True),
        sa.Column("preview_warning", sa.String(length=64), nullable=True),
        sa.Column("errors", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.CheckConstraint(
            "jsonb_typeof(dependencies)='array' AND jsonb_typeof(errors)='array'",
            name="ck_stage_row_arrays",
        ),
        sa.CheckConstraint(
            "preview_status IS NULL OR preview_status IN ('new','duplicate','source_conflict',"
            "'previously_undone','source_modified','invalid')",
            name="ck_stage_row_status",
        ),
        sa.CheckConstraint(
            "raw_hash ~ '^[0-9a-f]{64}$' "
            "AND (mapped_hash IS NULL OR mapped_hash ~ '^[0-9a-f]{64}$')",
            name="ck_stage_row_hashes",
        ),
        sa.CheckConstraint(
            "row_payload IS NULL OR jsonb_typeof(row_payload)='object'", name="ck_stage_row_payload"
        ),
        sa.CheckConstraint(
            "parsed_version BETWEEN 1 AND 2147483647 "
            "AND (preview_version IS NULL OR preview_version BETWEEN 1 AND 2147483647)",
            name="ck_stage_row_versions",
        ),
        sa.CheckConstraint(
            "position BETWEEN 1 AND 200000 AND source_line >= 1", name="ck_stage_row_position"
        ),
        sa.CheckConstraint(
            "topological_position IS NULL OR topological_position BETWEEN 1 AND 200000",
            name="ck_stage_row_topology",
        ),
        sa.ForeignKeyConstraint(
            ["stage_id"],
            ["import_stages.id"],
        ),
        sa.PrimaryKeyConstraint("stage_id", "position"),
        sa.UniqueConstraint("stage_id", "source_id", name="uq_stage_row_source"),
        sa.UniqueConstraint("stage_id", "topological_position", name="uq_stage_row_topology"),
    )
    op.create_index(
        "ix_stage_row_preview_page",
        "import_stage_rows",
        ["stage_id", "preview_version", "position"],
        unique=False,
    )
    op.create_table(
        "import_stage_upload_chunks",
        sa.Column("stage_id", sa.Uuid(), nullable=False),
        sa.Column("chunk_index", sa.Integer(), nullable=False),
        sa.Column("content", sa.LargeBinary(), nullable=False),
        sa.Column("size_bytes", sa.Integer(), nullable=False),
        sa.Column("sha256", sa.String(length=64), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("sha256 ~ '^[0-9a-f]{64}$'", name="ck_stage_upload_hash"),
        sa.CheckConstraint("chunk_index BETWEEN 0 AND 99", name="ck_stage_upload_index"),
        sa.CheckConstraint(
            "size_bytes BETWEEN 1 AND 524288 AND size_bytes=octet_length(content)",
            name="ck_stage_upload_bytes",
        ),
        sa.ForeignKeyConstraint(
            ["stage_id"],
            ["import_stages.id"],
        ),
        sa.PrimaryKeyConstraint("stage_id", "chunk_index"),
    )
    op.create_table(
        "import_publication_chunks",
        sa.Column("publication_id", sa.Uuid(), nullable=False),
        sa.Column("chunk_index", sa.Integer(), nullable=False),
        sa.Column("commit_id", sa.Uuid(), nullable=False),
        sa.Column("event_count", sa.Integer(), nullable=False),
        sa.Column("sha256", sa.String(length=64), nullable=False),
        sa.CheckConstraint("sha256 ~ '^[0-9a-f]{64}$'", name="ck_publication_chunk_hash"),
        sa.CheckConstraint(
            "chunk_index BETWEEN 0 AND 1999 AND event_count BETWEEN 1 AND 200",
            name="ck_publication_chunk_size",
        ),
        sa.ForeignKeyConstraint(
            ["publication_id"],
            ["import_publications.id"],
        ),
        sa.PrimaryKeyConstraint("publication_id", "chunk_index"),
        sa.UniqueConstraint("commit_id"),
    )


def downgrade():

    op.drop_table("import_publication_chunks")
    op.drop_table("import_stage_upload_chunks")
    op.drop_index("ix_stage_row_preview_page", table_name="import_stage_rows")
    op.drop_table("import_stage_rows")
    op.drop_index("ix_publication_stage_action", table_name="import_publications")
    op.drop_table("import_publications")
    op.drop_index("ix_stage_owner_created", table_name="import_stages")
    op.drop_index("ix_stage_expiry", table_name="import_stages")
    op.drop_table("import_stages")
