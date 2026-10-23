from typing import Annotated, Literal

from pydantic import Field, StringConstraints

from flowtrace_server.sync.schemas import ClosedModel, Identifier, Instant, Revision

from .attachment_sources import AttachmentSource
from .qianji_template import TemplateMapping
from .schemas import ImportDocument

ImportFileFormat = Literal[
    "flowtrace_json", "flowtrace_csv", "flowtrace_xlsx", "qianji_csv", "qianji_xlsx"
]
Digest = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
SafeCode = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_.-]{1,100}$")]


class ParseOptions(ClosedModel):
    source_namespace: Annotated[str, StringConstraints(min_length=1, max_length=80)] = "file-import"
    template_mapping: TemplateMapping | None = None


class RowError(ClosedModel):
    row: int | None = Field(default=None, ge=1)
    field: str | None = Field(default=None, max_length=200)
    code: SafeCode


class MappingRequirement(ClosedModel):
    kind: Literal["account", "category", "tag", "image"]
    source_value: str = Field(min_length=1, max_length=2000)
    rows: list[Annotated[int, Field(ge=2, le=51)]] = Field(min_length=1, max_length=50)


class ParseResult(ClosedModel):
    format: ImportFileFormat
    source_sha256: Digest
    document: ImportDocument | None
    errors: list[RowError]
    mapping_requirements: list[MappingRequirement] = Field(default_factory=list)
    attachment_sources: list[AttachmentSource] = Field(default_factory=list, max_length=1000)


class PreviewRow(ClosedModel):
    row: int = Field(ge=1)
    source_id: Identifier
    entity_id: Identifier
    status: Literal["new", "duplicate", "source_conflict", "previously_undone", "source_modified"]
    warning: (
        Literal["same_content_distinct_source", "possible_existing_content_distinct_source"] | None
    )


class ImportPreview(ClosedModel):
    batch_id: Identifier
    content_hash: Digest
    rows: list[PreviewRow]
    can_apply: bool
    errors: list[RowError]
    fingerprint_scan_complete: bool


class TransferReceipt(ClosedModel):
    attachment_id: Identifier
    from_scope_id: Identifier
    to_scope_id: Identifier
    permission_version: Revision
    sha256: Digest
    size_bytes: int = Field(ge=1, le=10 * 1024 * 1024)
    media_type: Literal["image/jpeg", "image/png", "image/webp"]


class ImportApplied(ClosedModel):
    batch_id: Identifier
    status: Literal["applied", "undone"]
    created: list[Identifier]
    duplicates: list[Identifier]
    commit_id: Identifier | None
    scope_revisions: dict[Identifier, Revision]
    replayed: bool
    attachment_transfers: list[TransferReceipt] = Field(default_factory=list)


class ImportUndone(ClosedModel):
    batch_id: Identifier
    status: Literal["undone"]
    replayed: bool
    commit_id: Identifier | None = None
    scope_revisions: dict[Identifier, Revision] = Field(default_factory=dict)


class EntityUndoConflict(ClosedModel):
    source_id: Identifier
    entity_id: Identifier
    code: Literal["modified_or_deleted"]


class AttachmentUndoConflict(ClosedModel):
    attachment_id: Identifier
    code: Literal["attachment_modified"]


class UndoPreview(ClosedModel):
    batch_id: Identifier
    status: Literal["applied", "undone"]
    conflicts: list[EntityUndoConflict]
    attachment_conflicts: list[AttachmentUndoConflict]
    can_undo: bool
    created_count: int = Field(ge=0)


class ImportHistoryItem(ClosedModel):
    batch_id: Identifier
    status: Literal["applied", "undone"]
    source_namespace: str = Field(min_length=1, max_length=80)
    created_at: Instant
    created_count: int = Field(ge=0)
    duplicate_count: int = Field(ge=0)


class ImportHistory(ClosedModel):
    batches: list[ImportHistoryItem]
    limit: int = Field(ge=1, le=100)
    has_more: bool
    next_cursor: str | None = Field(max_length=256)
