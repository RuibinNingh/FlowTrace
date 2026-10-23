"""Staging/publication tables registered by the 0010 migration.

JSONB columns hold only data validated by staging_schemas. Cross-row upload
continuity, total SHA, current authority and state CAS require stage services;
these CHECK constraints do not pretend to enforce aggregate invariants alone.
"""

from datetime import datetime
from uuid import UUID

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    DateTime,
    ForeignKey,
    ForeignKeyConstraint,
    Index,
    LargeBinary,
    String,
    Text,
    UniqueConstraint,
    event,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from flowtrace_server.persistence.models import Base


class ImportStage(Base):
    __tablename__ = "import_stages"
    __table_args__ = (
        UniqueConstraint("id", "batch_id", name="uq_stage_id_batch"),
        ForeignKeyConstraint(
            ["id", "source_released_at"],
            ["import_stage_source_releases.stage_id", "import_stage_source_releases.released_at"],
            name="fk_stage_source_release_receipt",
            use_alter=True,
        ),
        CheckConstraint("origin_purpose IN ('api_native','api_web')", name="ck_stage_purpose"),
        CheckConstraint(
            "format IN ('flowtrace_json','flowtrace_csv','flowtrace_xlsx',"
            "'qianji_csv','qianji_xlsx')",
            name="ck_stage_format",
        ),
        CheckConstraint(
            "status IN ('uploading','uploaded','parsing','parsed','previewing','ready',"
            "'applying','applied','undoing','undone','failed','cancelled','expired')",
            name="ck_stage_status",
        ),
        CheckConstraint("stage_version BETWEEN 1 AND 2147483647", name="ck_stage_version"),
        CheckConstraint(
            "expected_bytes BETWEEN 1 AND 52428800 AND received_bytes BETWEEN 0 AND expected_bytes",
            name="ck_stage_bytes",
        ),
        CheckConstraint(
            "expected_chunks = (expected_bytes + 524287) / 524288 "
            "AND received_chunks BETWEEN 0 AND expected_chunks",
            name="ck_stage_chunks",
        ),
        CheckConstraint(
            "row_count BETWEEN 0 AND 200000 AND error_count BETWEEN 0 AND 20000000",
            name="ck_stage_counts",
        ),
        CheckConstraint("source_sha256 ~ '^[0-9a-f]{64}$'", name="ck_stage_source_hash"),
        CheckConstraint(
            "preview_hash IS NULL OR preview_hash ~ '^[0-9a-f]{64}$'", name="ck_stage_preview_hash"
        ),
        CheckConstraint(
            "status NOT IN ('ready','applying') OR "
            "(preview_hash IS NOT NULL AND preview_version IS NOT NULL "
            "AND preview_version=stage_version)",
            name="ck_stage_ready_preview",
        ),
        CheckConstraint(
            "preview_version IS NULL OR preview_version BETWEEN 1 AND stage_version",
            name="ck_stage_preview_version",
        ),
        CheckConstraint(
            "received_bytes = LEAST(received_chunks::bigint*524288, expected_bytes)",
            name="ck_stage_received_prefix",
        ),
        CheckConstraint(
            "jsonb_typeof(mapping)='object' AND jsonb_typeof(permission_versions)='object' "
            "AND jsonb_typeof(required_scopes)='array'",
            name="ck_stage_json_shapes",
        ),
        CheckConstraint(
            "expires_at > created_at AND updated_at >= created_at", name="ck_stage_times"
        ),
        CheckConstraint(
            "source_released_at IS NULL OR "
            "(status IN ('applied','undoing','undone') AND sealed_at IS NOT NULL "
            "AND received_bytes=expected_bytes AND received_chunks=expected_chunks "
            "AND source_released_at>=created_at)",
            name="ck_stage_source_release",
        ),
        CheckConstraint(
            "requirements_count BETWEEN 0 AND 200000 AND "
            "((requirements_version IS NULL AND requirements_hash IS NULL "
            "AND requirements_count=0) OR "
            "(requirements_version IS NOT NULL "
            "AND requirements_version BETWEEN 1 AND stage_version "
            "AND requirements_hash IS NOT NULL "
            "AND requirements_hash ~ '^[0-9a-f]{64}$'))",
            name="ck_stage_requirements",
        ),
        CheckConstraint(
            "source_released_at IS NULL OR "
            "(requirements_version IS NULL AND requirements_hash IS NULL "
            "AND requirements_count=0)",
            name="ck_stage_released_requirements",
        ),
        Index("ix_stage_owner_created", "owner_user_id", "created_at", "id"),
        Index("ix_stage_expiry", "status", "expires_at", "id"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    batch_id: Mapped[UUID] = mapped_column(unique=True)
    owner_user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"))
    client_id: Mapped[UUID]
    sync_epoch: Mapped[UUID]
    origin_session_id: Mapped[UUID] = mapped_column(ForeignKey("sessions.id"))
    origin_purpose: Mapped[str] = mapped_column(String(16))
    format: Mapped[str] = mapped_column(String(24))
    status: Mapped[str] = mapped_column(String(16))
    stage_version: Mapped[int] = mapped_column(BigInteger)
    expected_bytes: Mapped[int] = mapped_column(BigInteger)
    received_bytes: Mapped[int] = mapped_column(BigInteger)
    expected_chunks: Mapped[int]
    received_chunks: Mapped[int]
    source_sha256: Mapped[str] = mapped_column(String(64))
    mapping: Mapped[dict] = mapped_column(JSONB)
    preview_version: Mapped[int | None] = mapped_column(BigInteger)
    preview_hash: Mapped[str | None] = mapped_column(String(64))
    required_scopes: Mapped[list] = mapped_column(JSONB)
    permission_versions: Mapped[dict] = mapped_column(JSONB)
    row_count: Mapped[int]
    error_count: Mapped[int]
    parse_job_id: Mapped[UUID | None] = mapped_column(ForeignKey("background_jobs.id"))
    preview_job_id: Mapped[UUID | None] = mapped_column(ForeignKey("background_jobs.id"))
    apply_job_id: Mapped[UUID | None] = mapped_column(ForeignKey("background_jobs.id"))
    undo_job_id: Mapped[UUID | None] = mapped_column(ForeignKey("background_jobs.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    sealed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    source_released_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    requirements_version: Mapped[int | None] = mapped_column(BigInteger)
    requirements_hash: Mapped[str | None] = mapped_column(String(64))
    requirements_count: Mapped[int] = mapped_column(default=0, server_default="0")


class ImportStageSourceRelease(Base):
    """Append-only proof of actual source deletion, never financial undo data."""

    __tablename__ = "import_stage_source_releases"
    __table_args__ = (
        ForeignKeyConstraint(
            ["stage_id", "batch_id"],
            ["import_stages.id", "import_stages.batch_id"],
            name="fk_source_release_stage_batch",
        ),
        UniqueConstraint("stage_id", "released_at", name="uq_source_release_marker"),
        UniqueConstraint("owner_user_id", "request_id", name="uq_source_release_request"),
        CheckConstraint(
            "origin_purpose IN ('api_native','api_web')", name="ck_source_release_purpose"
        ),
        CheckConstraint("stage_version BETWEEN 1 AND 2147483647", name="ck_source_release_version"),
        CheckConstraint(
            "request_hash ~ '^[0-9a-f]{64}$' AND source_sha256 ~ '^[0-9a-f]{64}$' "
            "AND preview_hash ~ '^[0-9a-f]{64}$'",
            name="ck_source_release_hashes",
        ),
        CheckConstraint(
            "reserved_bytes_released BETWEEN 1 AND 52428800 "
            "AND received_bytes_snapshot=reserved_bytes_released "
            "AND received_chunks_snapshot=(reserved_bytes_released+524287)/524288",
            name="ck_source_release_received",
        ),
        CheckConstraint(
            "deleted_source_chunks BETWEEN 0 AND received_chunks_snapshot "
            "AND deleted_source_bytes BETWEEN 0 AND received_bytes_snapshot "
            "AND ((deleted_source_chunks=0 AND deleted_source_bytes=0) OR "
            "(deleted_source_chunks>0 AND deleted_source_bytes BETWEEN "
            "deleted_source_chunks AND deleted_source_chunks::bigint*524288))",
            name="ck_source_release_actual_bytes",
        ),
        CheckConstraint(
            "source_rows_snapshot BETWEEN 1 AND 200000 "
            "AND deleted_preview_rows BETWEEN 0 AND source_rows_snapshot",
            name="ck_source_release_rows",
        ),
        CheckConstraint(
            "deleted_requirement_rows BETWEEN 0 AND 200000",
            name="ck_source_release_requirements",
        ),
        Index("ix_source_release_owner_time", "owner_user_id", "released_at", "stage_id"),
    )
    stage_id: Mapped[UUID] = mapped_column(primary_key=True)
    batch_id: Mapped[UUID] = mapped_column(ForeignKey("import_batches.id"))
    owner_user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"))
    origin_session_id: Mapped[UUID] = mapped_column(ForeignKey("sessions.id"))
    origin_purpose: Mapped[str] = mapped_column(String(16))
    client_id: Mapped[UUID]
    sync_epoch: Mapped[UUID]
    stage_version: Mapped[int] = mapped_column(BigInteger)
    request_id: Mapped[UUID]
    request_hash: Mapped[str] = mapped_column(String(64))
    source_sha256: Mapped[str] = mapped_column(String(64))
    preview_hash: Mapped[str] = mapped_column(String(64))
    reserved_bytes_released: Mapped[int] = mapped_column(BigInteger)
    received_bytes_snapshot: Mapped[int] = mapped_column(BigInteger)
    received_chunks_snapshot: Mapped[int]
    source_rows_snapshot: Mapped[int]
    deleted_source_bytes: Mapped[int] = mapped_column(BigInteger)
    deleted_source_chunks: Mapped[int]
    deleted_preview_rows: Mapped[int]
    deleted_requirement_rows: Mapped[int] = mapped_column(default=0, server_default="0")
    released_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


@event.listens_for(ImportStageSourceRelease, "before_update")
@event.listens_for(ImportStageSourceRelease, "before_delete")
def immutable_source_release(mapper, connection, target):
    raise ValueError("import_stage_source_release_immutable")


class ImportStageUploadChunk(Base):
    __tablename__ = "import_stage_upload_chunks"
    __table_args__ = (
        CheckConstraint("chunk_index BETWEEN 0 AND 99", name="ck_stage_upload_index"),
        CheckConstraint(
            "size_bytes BETWEEN 1 AND 524288 AND size_bytes=octet_length(content)",
            name="ck_stage_upload_bytes",
        ),
        CheckConstraint("sha256 ~ '^[0-9a-f]{64}$'", name="ck_stage_upload_hash"),
    )
    stage_id: Mapped[UUID] = mapped_column(ForeignKey("import_stages.id"), primary_key=True)
    chunk_index: Mapped[int] = mapped_column(primary_key=True)
    content: Mapped[bytes] = mapped_column(LargeBinary)
    size_bytes: Mapped[int]
    sha256: Mapped[str] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class ImportStageRow(Base):
    __tablename__ = "import_stage_rows"
    __table_args__ = (
        UniqueConstraint("stage_id", "source_id", name="uq_stage_row_source"),
        UniqueConstraint("stage_id", "topological_position", name="uq_stage_row_topology"),
        CheckConstraint(
            "position BETWEEN 1 AND 200000 AND source_line >= 1", name="ck_stage_row_position"
        ),
        CheckConstraint(
            "parsed_version BETWEEN 1 AND 2147483647 AND "
            "(preview_version IS NULL OR preview_version BETWEEN 1 AND 2147483647)",
            name="ck_stage_row_versions",
        ),
        CheckConstraint(
            "topological_position IS NULL OR topological_position BETWEEN 1 AND 200000",
            name="ck_stage_row_topology",
        ),
        CheckConstraint(
            "raw_hash ~ '^[0-9a-f]{64}$' "
            "AND (mapped_hash IS NULL OR mapped_hash ~ '^[0-9a-f]{64}$')",
            name="ck_stage_row_hashes",
        ),
        CheckConstraint(
            "row_payload IS NULL OR jsonb_typeof(row_payload)='object'", name="ck_stage_row_payload"
        ),
        CheckConstraint(
            "jsonb_typeof(dependencies)='array' AND jsonb_typeof(errors)='array'",
            name="ck_stage_row_arrays",
        ),
        CheckConstraint(
            "preview_status IS NULL OR preview_status IN ('new','duplicate','source_conflict',"
            "'previously_undone','source_modified','invalid')",
            name="ck_stage_row_status",
        ),
        Index("ix_stage_row_preview_page", "stage_id", "preview_version", "position"),
    )
    stage_id: Mapped[UUID] = mapped_column(ForeignKey("import_stages.id"), primary_key=True)
    position: Mapped[int] = mapped_column(primary_key=True)
    source_line: Mapped[int]
    source_id: Mapped[UUID | None]
    row_payload: Mapped[dict | None] = mapped_column(JSONB(none_as_null=True))
    raw_hash: Mapped[str] = mapped_column(String(64))
    parsed_version: Mapped[int] = mapped_column(BigInteger)
    preview_version: Mapped[int | None] = mapped_column(BigInteger)
    dependencies: Mapped[list] = mapped_column(JSONB)
    topological_position: Mapped[int | None]
    target_entity_id: Mapped[UUID | None]
    mapped_hash: Mapped[str | None] = mapped_column(String(64))
    preview_status: Mapped[str | None] = mapped_column(String(32))
    preview_warning: Mapped[str | None] = mapped_column(String(64))
    errors: Mapped[list] = mapped_column(JSONB)


class ImportStageRequirement(Base):
    """Only explicit source references, never source financial text or rights."""

    __tablename__ = "import_stage_requirements"
    __table_args__ = (
        UniqueConstraint(
            "stage_id", "parsed_version", "key_sha256", name="uq_stage_requirement_key"
        ),
        CheckConstraint(
            "position BETWEEN 1 AND 200000 AND first_line>=1 "
            "AND parsed_version BETWEEN 1 AND 2147483647",
            name="ck_stage_requirement_position",
        ),
        CheckConstraint(
            "kind IN ('account','category','tag','image','scope','resource') "
            "AND source_kind IN ('name','identifier') "
            "AND (resource_type IS NULL OR resource_type IN "
            "('book','account','category','tag','bill','budget','account_group','user'))",
            name="ck_stage_requirement_types",
        ),
        CheckConstraint(
            "char_length(source_key) BETWEEN 1 AND 2000 "
            "AND key_sha256 ~ '^[0-9a-f]{64}$'",
            name="ck_stage_requirement_key",
        ),
        CheckConstraint(
            "(source_kind='name' AND kind IN ('account','category','tag','image') "
            "AND resource_type IS NULL) OR "
            "(source_kind='identifier' AND kind IN ('scope','resource','image') "
            "AND source_key ~ "
            "'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' "
            "AND ((kind='image' AND resource_type IS NULL) OR "
            "(kind='scope' AND resource_type IS NOT NULL "
            "AND resource_type IN ('book','user')) OR "
            "(kind='resource' AND resource_type IS NOT NULL AND resource_type IN "
            "('book','account','category','tag','bill','budget','account_group'))))",
            name="ck_stage_requirement_source",
        ),
        CheckConstraint(
            "(attachment_sha256 IS NULL AND attachment_size_bytes IS NULL "
            "AND attachment_media_type IS NULL) OR "
            "(kind='image' AND source_kind='identifier' AND resource_type IS NULL "
            "AND attachment_sha256 IS NOT NULL "
            "AND attachment_sha256 ~ '^[0-9a-f]{64}$' "
            "AND attachment_size_bytes IS NOT NULL "
            "AND attachment_size_bytes BETWEEN 1 AND 10485760 "
            "AND attachment_media_type IS NOT NULL "
            "AND attachment_media_type IN ('image/png','image/jpeg','image/webp'))",
            name="ck_stage_requirement_attachment",
        ),
    )
    stage_id: Mapped[UUID] = mapped_column(ForeignKey("import_stages.id"), primary_key=True)
    position: Mapped[int] = mapped_column(primary_key=True)
    parsed_version: Mapped[int] = mapped_column(BigInteger)
    kind: Mapped[str] = mapped_column(String(16))
    source_kind: Mapped[str] = mapped_column(String(16))
    source_key: Mapped[str] = mapped_column(Text)
    resource_type: Mapped[str | None] = mapped_column(String(16))
    key_sha256: Mapped[str] = mapped_column(String(64))
    first_line: Mapped[int] = mapped_column(BigInteger)
    attachment_sha256: Mapped[str | None] = mapped_column(String(64))
    attachment_size_bytes: Mapped[int | None]
    attachment_media_type: Mapped[str | None] = mapped_column(String(16))


class ImportPublication(Base):
    __tablename__ = "import_publications"
    __table_args__ = (
        ForeignKeyConstraint(
            ["stage_id", "batch_id"],
            ["import_stages.id", "import_stages.batch_id"],
            name="fk_publication_stage_batch",
        ),
        UniqueConstraint("batch_id", "action", name="uq_import_publication_action"),
        CheckConstraint("action IN ('apply','undo')", name="ck_publication_action"),
        CheckConstraint("stage_version BETWEEN 1 AND 2147483647", name="ck_publication_version"),
        CheckConstraint(
            "chunk_count BETWEEN 0 AND 2000 "
            "AND event_count BETWEEN chunk_count AND chunk_count*200",
            name="ck_publication_counts",
        ),
        CheckConstraint(
            "content_hash ~ '^[0-9a-f]{64}$' AND preview_hash ~ '^[0-9a-f]{64}$' "
            "AND events_sha256 ~ '^[0-9a-f]{64}$'",
            name="ck_publication_hashes",
        ),
        CheckConstraint(
            "jsonb_typeof(permission_versions)='object' AND jsonb_typeof(checkpoint)='object'",
            name="ck_publication_vectors",
        ),
        Index("ix_publication_stage_action", "stage_id", "action", "id"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    batch_id: Mapped[UUID] = mapped_column(ForeignKey("import_batches.id"))
    stage_id: Mapped[UUID]
    stage_version: Mapped[int] = mapped_column(BigInteger)
    action: Mapped[str] = mapped_column(String(8))
    sync_epoch: Mapped[UUID]
    content_hash: Mapped[str] = mapped_column(String(64))
    preview_hash: Mapped[str] = mapped_column(String(64))
    chunk_count: Mapped[int]
    event_count: Mapped[int] = mapped_column(BigInteger)
    events_sha256: Mapped[str] = mapped_column(String(64))
    permission_versions: Mapped[dict] = mapped_column(JSONB)
    checkpoint: Mapped[dict] = mapped_column(JSONB)
    published_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class ImportPublicationChunk(Base):
    __tablename__ = "import_publication_chunks"
    __table_args__ = (
        CheckConstraint(
            "chunk_index BETWEEN 0 AND 1999 AND event_count BETWEEN 1 AND 200",
            name="ck_publication_chunk_size",
        ),
        CheckConstraint("sha256 ~ '^[0-9a-f]{64}$'", name="ck_publication_chunk_hash"),
    )
    publication_id: Mapped[UUID] = mapped_column(
        ForeignKey("import_publications.id"), primary_key=True
    )
    chunk_index: Mapped[int] = mapped_column(primary_key=True)
    # sync_changes.commit_id is not unique, so this is deliberately no fake FK.
    commit_id: Mapped[UUID] = mapped_column(unique=True)
    event_count: Mapped[int]
    sha256: Mapped[str] = mapped_column(String(64))
