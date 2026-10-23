"""Internal boundary for validated persistent-stage snapshots.

No HTTP route accepts these models. Stage authorization, immutable upload hash,
preview-version CAS and job fencing must precede construction by the staging
store. The existing public ImportRequest remains limited to its original size.
This module proves server transaction atomicity only; client publication groups
are a separate protocol requirement before exposing large imports to users.
"""

from dataclasses import dataclass, field
from typing import Literal
from uuid import UUID

from pydantic import Field

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.sync.common import run_transaction
from flowtrace_server.sync.schemas import ClosedModel, Identifier, Revision

from .attachment_sources import AttachmentSource
from .http_schemas import ImportPreview, TransferReceipt
from .published_context import PublishedStageContext
from .schemas import HistoricalPosting, ImportDocument, ImportRequest, ImportRow, UndoRequest
from .service import (
    apply_import_in_transaction,
    preview_import_in_transaction,
    undo_import_in_transaction,
)
from .staging_schemas import StageScopeVersion


@dataclass(frozen=True)
class PublicationStageSnapshot:
    """Typed snapshot supplied by the persistent stage store, never raw RPC JSON."""

    stage_id: UUID
    batch_id: UUID
    user_id: UUID
    client_id: UUID
    sync_epoch: UUID
    version: int
    source_sha256: str
    source_namespace: str
    rows: tuple[ImportRow, ...]
    posting_hints: dict[str, HistoricalPosting] = field(default_factory=dict)
    scope_mapping: dict[str, str] = field(default_factory=dict)
    resource_mapping: dict[str, str] = field(default_factory=dict)
    attachment_transfers: dict[str, str] = field(default_factory=dict)
    attachment_sources: tuple[AttachmentSource, ...] = ()


class _PublicationDocument(ImportDocument):
    rows: list[ImportRow] = Field(min_length=1, max_length=200000)
    posting_hints: dict[Identifier, HistoricalPosting] = Field(
        default_factory=dict, max_length=200000
    )


class _PublicationRequest(ImportRequest):
    stage_id: Identifier
    stage_version: int = Field(ge=1, le=2**31 - 1)
    source_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    document: _PublicationDocument
    scope_mapping: dict[Identifier, Identifier] = Field(default_factory=dict, max_length=200000)
    resource_mapping: dict[Identifier, Identifier] = Field(default_factory=dict, max_length=200000)
    attachment_transfers: dict[Identifier, Identifier] = Field(
        default_factory=dict, max_length=200000
    )


def request_from_stage(snapshot: PublicationStageSnapshot, principal):
    if (
        not isinstance(snapshot, PublicationStageSnapshot)
        or snapshot.user_id != principal.user_id
        or snapshot.client_id != principal.client_id
        or any(not isinstance(row, ImportRow) for row in snapshot.rows)
    ):
        raise ApiError("import_stage_forbidden", 403)
    # Ordinary full validation retains raw payload presence and every original
    # six-entity financial rule. No model_construct, oversized HTTP input, or
    # post-validation replacement is used to bypass the public row limit.
    return _PublicationRequest(
        stage_id=str(snapshot.stage_id),
        stage_version=snapshot.version,
        source_sha256=snapshot.source_sha256,
        batch_id=str(snapshot.batch_id),
        client_id=str(snapshot.client_id),
        sync_epoch=str(snapshot.sync_epoch),
        document=_PublicationDocument(
            format="flowtrace-data-v1",
            source_namespace=snapshot.source_namespace,
            rows=list(snapshot.rows),
            posting_hints=snapshot.posting_hints,
        ),
        scope_mapping=snapshot.scope_mapping,
        resource_mapping=snapshot.resource_mapping,
        attachment_transfers=snapshot.attachment_transfers,
    )


class PublicationApplied(ClosedModel):
    batch_id: Identifier
    publication_id: Identifier
    status: Literal["applied", "undone"]
    created: list[Identifier]
    duplicates: list[Identifier]
    # There is no single sync commit for the complete publication.
    commit_id: None
    commit_ids: list[Identifier]
    scope_revisions: dict[Identifier, Revision]
    replayed: bool
    attachment_transfers: list[TransferReceipt]


class PublicationUndone(ClosedModel):
    batch_id: Identifier
    publication_id: Identifier
    status: Literal["undone"]
    replayed: bool
    commit_id: None = None
    commit_ids: list[Identifier] = Field(default_factory=list)
    scope_revisions: dict[Identifier, Revision] = Field(default_factory=dict)


class PublicationPreview(ImportPreview):
    stage_id: Identifier
    stage_version: int = Field(ge=1, le=2**31 - 1)
    scope_versions: dict[Identifier, StageScopeVersion]


def preview_publication_in_transaction(session, principal, snapshot, *, check_budget):
    request = request_from_stage(snapshot, principal)
    return PublicationPreview(
        stage_id=str(snapshot.stage_id),
        stage_version=snapshot.version,
        **preview_import_in_transaction(
            session, principal, request, publication_id=snapshot.stage_id, check_budget=check_budget
        ),
    )


def apply_publication_in_transaction(session, principal, snapshot, **hooks):
    request = request_from_stage(snapshot, principal)
    return PublicationApplied.model_validate(
        apply_import_in_transaction(
            session,
            principal,
            request,
            publication_id=snapshot.stage_id,
            **hooks,
        )
    )


def apply_publication(session, principal, snapshot, **hooks):
    return run_transaction(
        session,
        lambda: apply_publication_in_transaction(
            session,
            principal,
            snapshot,
            **hooks,
        ),
    )


def undo_publication_in_transaction(session, principal, snapshot, **hooks):
    request_from_stage(snapshot, principal)
    request = UndoRequest(client_id=str(snapshot.client_id), sync_epoch=str(snapshot.sync_epoch))
    return PublicationUndone.model_validate(
        undo_import_in_transaction(
            session,
            principal,
            snapshot.batch_id,
            request,
            publication_id=snapshot.stage_id,
            **hooks,
        )
    )


def undo_published_in_transaction(session, principal, context, **hooks):
    """Formal stage undo needs its persisted batch, never the old source file."""
    if (
        not isinstance(context, PublishedStageContext)
        or context.user_id != principal.user_id
        or context.client_id != principal.client_id
    ):
        raise ApiError("import_stage_forbidden", 403)
    request = UndoRequest(client_id=str(context.client_id), sync_epoch=str(context.sync_epoch))
    return PublicationUndone.model_validate(
        undo_import_in_transaction(
            session,
            principal,
            context.batch_id,
            request,
            publication_id=context.stage_id,
            **hooks,
        )
    )


def undo_publication(session, principal, snapshot, **hooks):
    return run_transaction(
        session,
        lambda: undo_publication_in_transaction(
            session,
            principal,
            snapshot,
            **hooks,
        ),
    )
