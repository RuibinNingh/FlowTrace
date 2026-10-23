"""Closed future staging inputs; not mounted by the public data-tools router."""

from typing import Annotated, Literal

from pydantic import Field, StringConstraints, TypeAdapter, model_validator

from flowtrace_server.jobs.store import SafeCode
from flowtrace_server.sync.schemas import (
    ClosedModel,
    Identifier,
    Instant,
    Name,
    Revision,
    TimezoneName,
)

from .attachment_sources import AttachmentSource
from .http_schemas import Digest, ImportFileFormat, RowError
from .qianji_template import TemplateMapping
from .schemas import ImportRow

STAGE_CHUNK_BYTES = 512 * 1024
STAGE_MAX_SOURCE_BYTES = 50 * 1024 * 1024
STAGE_MAX_CHUNKS = STAGE_MAX_SOURCE_BYTES // STAGE_CHUNK_BYTES
STAGE_MAX_ROWS = 200000
STAGE_MAX_REQUIREMENTS = 200000
_IDENTIFIER_ADAPTER = TypeAdapter(Identifier)
PUBLICATION_MAX_EVENTS = STAGE_MAX_ROWS * 2
PUBLICATION_MAX_CHUNKS = PUBLICATION_MAX_EVENTS // 200

StageVersion = Annotated[int, Field(ge=1, le=2**31 - 1)]
StageStatus = Literal[
    "uploading",
    "uploaded",
    "parsing",
    "parsed",
    "previewing",
    "ready",
    "applying",
    "applied",
    "undoing",
    "undone",
    "failed",
    "cancelled",
    "expired",
]
StageRowStatus = Literal[
    "new",
    "duplicate",
    "source_conflict",
    "previously_undone",
    "source_modified",
    "invalid",
]


class StageTemplateMapping(TemplateMapping):
    account_names: dict[str, Identifier] = Field(default_factory=dict, max_length=STAGE_MAX_ROWS)
    category_names: dict[str, Identifier] = Field(default_factory=dict, max_length=STAGE_MAX_ROWS)
    tag_names: dict[str, Identifier] = Field(default_factory=dict, max_length=STAGE_MAX_ROWS)
    image_urls: dict[str, Identifier] = Field(default_factory=dict, max_length=STAGE_MAX_ROWS)

    @model_validator(mode="after")
    def bounded_source_names(self):
        for mapping in (self.account_names, self.category_names, self.tag_names, self.image_urls):
            if any(not 1 <= len(name) <= 2000 or "\x00" in name for name in mapping):
                raise ValueError("stage_mapping_name_invalid")
        return self


class StageMapping(ClosedModel):
    source_namespace: str = Field(default="file-import", min_length=1, max_length=80)
    template_mapping: StageTemplateMapping | None = None
    scope_mapping: dict[Identifier, Identifier] = Field(
        default_factory=dict, max_length=STAGE_MAX_ROWS
    )
    resource_mapping: dict[Identifier, Identifier] = Field(
        default_factory=dict, max_length=STAGE_MAX_ROWS
    )
    attachment_transfers: dict[Identifier, Identifier] = Field(
        default_factory=dict, max_length=STAGE_MAX_ROWS
    )


class StageCreate(ClosedModel):
    # New clients persist this UUID before sending create, then recover by GET.
    # None remains accepted for the earlier internal service callers.
    stage_id: Identifier | None = None
    client_id: Identifier
    sync_epoch: Identifier
    format: ImportFileFormat
    expected_bytes: int = Field(ge=1, le=STAGE_MAX_SOURCE_BYTES)
    source_sha256: Digest
    mapping: StageMapping = Field(default_factory=StageMapping)


class StageCreateRequest(StageCreate):
    """HTTP clients persist the fixed identity before their first POST."""

    stage_id: Identifier


class StageVersionInput(ClosedModel):
    stage_version: StageVersion


class StageScopeVersion(ClosedModel):
    """Stage-only preflight state, not a publication permission/checkpoint map."""

    permission_version: Revision
    revision: Revision


class StageSeal(StageVersionInput):
    total_bytes: int = Field(ge=1, le=STAGE_MAX_SOURCE_BYTES)
    source_sha256: Digest


class StageMappingUpdate(StageVersionInput):
    mapping: StageMapping


class StageApply(StageVersionInput):
    batch_id: Identifier
    preview_hash: Digest


class StageUndo(StageVersionInput):
    batch_id: Identifier


class StageDiscard(StageVersionInput):
    """Explicit owner abandonment of an unpublished original, never undo."""

    batch_id: Identifier
    client_id: Identifier
    sync_epoch: Identifier
    source_sha256: Digest


class StageReauthorize(StageVersionInput):
    # Session ID and purpose are always read from the authenticated request.
    client_id: Identifier
    sync_epoch: Identifier


class StageSourceReleaseRequest(StageVersionInput):
    """Persist the complete request before explicitly releasing a stage source."""

    request_id: Identifier
    batch_id: Identifier
    client_id: Identifier
    sync_epoch: Identifier
    source_sha256: Digest


class StageSourceReleaseReceipt(ClosedModel):
    stage_id: Identifier
    batch_id: Identifier
    request_id: Identifier
    # The version at release; reauthorization may later advance the live stage.
    stage_version: StageVersion
    source_released: Literal[True] = True
    source_released_at: Instant
    reserved_bytes_released: int = Field(ge=1, le=STAGE_MAX_SOURCE_BYTES)
    deleted_source_bytes: int = Field(ge=0, le=STAGE_MAX_SOURCE_BYTES)
    deleted_source_chunks: int = Field(ge=0, le=STAGE_MAX_CHUNKS)
    deleted_preview_rows: int = Field(ge=0, le=STAGE_MAX_ROWS)
    deleted_requirement_rows: int = Field(default=0, ge=0, le=STAGE_MAX_REQUIREMENTS)
    replayed: bool

    @model_validator(mode="after")
    def released_capacity(self):
        if self.deleted_source_bytes > self.reserved_bytes_released:
            raise ValueError("source_release_size_invalid")
        if (
            self.deleted_source_chunks
            > (self.reserved_bytes_released + STAGE_CHUNK_BYTES - 1) // STAGE_CHUNK_BYTES
        ):
            raise ValueError("source_release_size_invalid")
        if self.deleted_source_chunks == 0:
            if self.deleted_source_bytes:
                raise ValueError("source_release_size_invalid")
        elif (
            not self.deleted_source_chunks
            <= self.deleted_source_bytes
            <= (self.deleted_source_chunks * STAGE_CHUNK_BYTES)
        ):
            raise ValueError("source_release_size_invalid")
        return self


class StageCreated(ClosedModel):
    stage_id: Identifier
    batch_id: Identifier
    stage_version: StageVersion
    chunk_bytes: Literal[524288] = STAGE_CHUNK_BYTES
    expected_chunks: int = Field(ge=1, le=STAGE_MAX_CHUNKS)
    expires_at: Instant


class StageChunkReceipt(ClosedModel):
    stage_id: Identifier
    stage_version: StageVersion
    chunk_index: int = Field(ge=0, lt=STAGE_MAX_CHUNKS)
    chunk_sha256: Digest
    size_bytes: int = Field(ge=1, le=STAGE_CHUNK_BYTES)
    next_chunk_index: int = Field(ge=1, le=STAGE_MAX_CHUNKS)
    received_bytes: int = Field(ge=1, le=STAGE_MAX_SOURCE_BYTES)
    expected_bytes: int = Field(ge=1, le=STAGE_MAX_SOURCE_BYTES)
    replayed: bool

    @model_validator(mode="after")
    def received_progress(self):
        if self.received_bytes > self.expected_bytes or self.chunk_index >= self.next_chunk_index:
            raise ValueError("stage_chunk_progress_invalid")
        expected_chunks = (self.expected_bytes + STAGE_CHUNK_BYTES - 1) // STAGE_CHUNK_BYTES
        if self.next_chunk_index > expected_chunks:
            raise ValueError("stage_chunk_progress_invalid")
        if self.size_bytes != min(
            STAGE_CHUNK_BYTES, self.expected_bytes - self.chunk_index * STAGE_CHUNK_BYTES
        ) or self.received_bytes != min(
            self.next_chunk_index * STAGE_CHUNK_BYTES, self.expected_bytes
        ):
            raise ValueError("stage_chunk_progress_invalid")
        return self


class StageStatusResponse(ClosedModel):
    stage_id: Identifier
    batch_id: Identifier
    stage_version: StageVersion
    format: ImportFileFormat
    status: StageStatus
    expected_bytes: int = Field(ge=1, le=STAGE_MAX_SOURCE_BYTES)
    received_bytes: int = Field(ge=0, le=STAGE_MAX_SOURCE_BYTES)
    received_chunks: int = Field(ge=0, le=STAGE_MAX_CHUNKS)
    row_count: int = Field(ge=0, le=STAGE_MAX_ROWS)
    error_count: int = Field(ge=0, le=STAGE_MAX_ROWS * 100)
    preview_hash: Digest | None
    parse_job_id: Identifier | None
    preview_job_id: Identifier | None
    apply_job_id: Identifier | None
    undo_job_id: Identifier | None
    created_at: Instant
    updated_at: Instant
    expires_at: Instant
    source_released: bool = False
    source_released_at: Instant | None = None
    requirements_version: StageVersion | None = None
    requirements_hash: Digest | None = None
    requirements_count: int = Field(default=0, ge=0, le=STAGE_MAX_REQUIREMENTS)
    # Current normalized desired state, never proof of financial authorization.
    mapping_hash: Digest | None = None

    @model_validator(mode="after")
    def progress_is_bounded(self):
        expected_chunks = (self.expected_bytes + STAGE_CHUNK_BYTES - 1) // STAGE_CHUNK_BYTES
        if self.received_bytes > self.expected_bytes or self.received_chunks > expected_chunks:
            raise ValueError("stage_progress_invalid")
        if self.status in {"ready", "applying"} and self.preview_hash is None:
            raise ValueError("stage_preview_required")
        if self.source_released != (self.source_released_at is not None) or (
            self.source_released and self.status not in {"applied", "undoing", "undone"}
        ):
            raise ValueError("stage_source_release_status_invalid")
        if self.source_released and (
            self.received_bytes != self.expected_bytes or self.received_chunks != expected_chunks
        ):
            raise ValueError("stage_source_release_status_invalid")
        if (self.requirements_version is None) != (self.requirements_hash is None) or (
            self.requirements_version is None and self.requirements_count != 0
        ):
            raise ValueError("stage_requirements_status_invalid")
        if self.requirements_version is not None and (
            self.requirements_version > self.stage_version or self.source_released
        ):
            raise ValueError("stage_requirements_status_invalid")
        return self


class StageJobResponse(ClosedModel):
    stage_id: Identifier
    stage_version: StageVersion
    job_id: Identifier
    status: StageStatus


class StageJobMetadata(ClosedModel):
    action: Literal["parse", "preview", "apply", "undo"]
    job_id: Identifier
    stage_version: StageVersion
    status: Literal["pending", "running", "succeeded", "retry_wait", "failed", "cancelled"]
    attempt: int = Field(ge=0, le=5)
    error_code: SafeCode | None
    available_at: Instant
    lease_until: Instant | None


class StageJobsMetadata(ClosedModel):
    stage_id: Identifier
    stage_version: StageVersion
    jobs: list[StageJobMetadata] = Field(max_length=4)

    @model_validator(mode="after")
    def unique_actions(self):
        if (
            len({job.action for job in self.jobs}) != len(self.jobs)
            or len({job.job_id for job in self.jobs}) != len(self.jobs)
            or any(job.stage_version > self.stage_version for job in self.jobs)
        ):
            raise ValueError("stage_jobs_metadata_invalid")
        return self


class StageReauthorizationMetadata(ClosedModel):
    """Source-owner proof before explicit reauthorization, never write rights."""

    stage_id: Identifier
    batch_id: Identifier
    stage_version: StageVersion
    format: ImportFileFormat
    expected_bytes: int = Field(ge=1, le=STAGE_MAX_SOURCE_BYTES)
    source_sha256: Digest
    mapping_hash: Digest
    # Persisted phase; expired separately reports the source TTL, including
    # published stages whose formal reauthorization/undo is not blocked by it.
    status: StageStatus
    source_released: bool
    expired: bool

    @model_validator(mode="after")
    def release_phase(self):
        if self.source_released and self.status not in {"applied", "undoing", "undone"}:
            raise ValueError("stage_source_release_status_invalid")
        return self


class StageRowPreview(ClosedModel):
    position: int = Field(ge=1, le=STAGE_MAX_ROWS)
    source_line: int = Field(ge=1)
    source_id: Identifier | None
    row: ImportRow | None
    target_entity_id: Identifier | None
    # "parsed" is response-only: no domain preview/classification yet.
    status: StageRowStatus | Literal["parsed"]
    warning: (
        Literal["same_content_distinct_source", "possible_existing_content_distinct_source"] | None
    )
    errors: list[RowError] = Field(max_length=100)

    @model_validator(mode="after")
    def original_row_identity(self):
        if self.row is not None and self.source_id != self.row.source_id:
            raise ValueError("stage_row_identity_mismatch")
        if self.status == "invalid" and not self.errors:
            raise ValueError("stage_row_error_required")
        return self


class StageRowsPage(ClosedModel):
    stage_id: Identifier
    stage_version: StageVersion
    rows: list[StageRowPreview] = Field(max_length=100)
    has_more: bool
    next_cursor: Annotated[str, StringConstraints(min_length=1, max_length=256)] | None

    @model_validator(mode="after")
    def page_complete(self):
        if self.has_more != (self.next_cursor is not None):
            raise ValueError("stage_page_cursor_invalid")
        positions = [row.position for row in self.rows]
        if positions != sorted(set(positions)) or (self.has_more and not self.rows):
            raise ValueError("stage_page_order_invalid")
        return self


class StageSourceBook(ClosedModel):
    """Original book definitions for explicit image destination selection."""

    position: int = Field(ge=1, le=STAGE_MAX_ROWS)
    source_id: Identifier
    name: Name
    currency: Annotated[str, StringConstraints(pattern=r"^[A-Z]{3}$")]
    timezone: TimezoneName


class StageSourceBooksPage(ClosedModel):
    stage_id: Identifier
    stage_version: StageVersion
    count: int = Field(ge=0, le=STAGE_MAX_ROWS)
    items: list[StageSourceBook] = Field(max_length=100)
    has_more: bool
    next_cursor: Annotated[str, StringConstraints(min_length=1, max_length=512)] | None

    @model_validator(mode="after")
    def page_complete(self):
        positions = [item.position for item in self.items]
        if (
            self.has_more != (self.next_cursor is not None)
            or positions != sorted(set(positions))
            or self.count < len(positions)
            or self.has_more
            and not positions
            or len({item.source_id for item in self.items}) != len(positions)
        ):
            raise ValueError("stage_source_books_page_invalid")
        return self


class StageRequirement(ClosedModel):
    position: int = Field(ge=1, le=STAGE_MAX_REQUIREMENTS)
    kind: Literal["account", "category", "tag", "image", "scope", "resource"]
    source_kind: Literal["name", "identifier"]
    source_key: Annotated[str, StringConstraints(min_length=1, max_length=2000)]
    resource_type: (
        Literal["book", "account", "category", "tag", "bill", "budget", "account_group", "user"]
        | None
    ) = None
    # Physical CSV/XLSX line can exceed STAGE_MAX_ROWS due to multiline cells.
    first_line: int = Field(ge=1, le=2**63 - 1)
    attachment_source: AttachmentSource | None = None

    @model_validator(mode="after")
    def explicit_source_reference(self):
        if "\x00" in self.source_key:
            raise ValueError("stage_requirement_source_invalid")
        if self.source_kind == "name":
            if self.kind not in {"account", "category", "tag", "image"} or (
                self.resource_type is not None or self.attachment_source is not None
            ):
                raise ValueError("stage_requirement_source_invalid")
        else:
            _IDENTIFIER_ADAPTER.validate_python(self.source_key, strict=True)
            if self.kind not in {"scope", "resource", "image"}:
                raise ValueError("stage_requirement_source_invalid")
            valid_type = (
                self.kind == "image"
                and self.resource_type is None
                or self.kind == "scope"
                and self.resource_type in {"book", "user"}
                or self.kind == "resource"
                and self.resource_type
                in {"book", "account", "category", "tag", "bill", "budget", "account_group"}
            )
            if not valid_type:
                raise ValueError("stage_requirement_source_invalid")
        if self.attachment_source is not None and (
            self.kind != "image"
            or self.source_kind != "identifier"
            or self.resource_type is not None
            or self.attachment_source.source_id != self.source_key
        ):
            raise ValueError("stage_requirement_attachment_invalid")
        return self


class StageRequirementsPage(ClosedModel):
    stage_id: Identifier
    stage_version: StageVersion
    requirements_hash: Digest
    items: list[StageRequirement] = Field(max_length=100)
    has_more: bool
    next_cursor: Annotated[str, StringConstraints(min_length=1, max_length=512)] | None

    @model_validator(mode="after")
    def page_complete(self):
        positions = [item.position for item in self.items]
        if self.has_more != (self.next_cursor is not None) or (self.has_more and not self.items):
            raise ValueError("stage_requirements_cursor_invalid")
        if positions != sorted(set(positions)):
            raise ValueError("stage_requirements_order_invalid")
        return self


class StageParseJob(ClosedModel):
    action: Literal["parse"]
    stage_id: Identifier
    stage_version: StageVersion
    source_sha256: Digest


class StagePreviewJob(ClosedModel):
    action: Literal["preview"]
    stage_id: Identifier
    stage_version: StageVersion
    source_sha256: Digest
    mapping_hash: Digest


class StageApplyJob(ClosedModel):
    action: Literal["apply"]
    stage_id: Identifier
    stage_version: StageVersion
    batch_id: Identifier
    preview_hash: Digest


class StageUndoJob(ClosedModel):
    action: Literal["undo"]
    stage_id: Identifier
    stage_version: StageVersion
    batch_id: Identifier
