"""Owner-only formal publication identity, independent of upload/preview bytes.

This is a read-only internal metadata proof, not current financial authority.
Callers authenticate/fence the real session and lock/authorize current scopes;
the undo writer verifies every current item, payload, reference and attachment.
Historical SyncChange payload SHA verification belongs to the group reader.
"""

import hashlib
import re
from dataclasses import dataclass
from uuid import UUID, uuid5

from sqlalchemy import func, select
from sqlalchemy.inspection import inspect

from flowtrace_server.auth.errors import ApiError

from .models import ImportBatch, ImportItem
from .staging_models import ImportPublication, ImportPublicationChunk, ImportStage


@dataclass(frozen=True)
class PublishedStageContext:
    """Built only from persisted formal rows; no external request accepts it."""

    stage_id: UUID
    batch_id: UUID
    user_id: UUID
    client_id: UUID
    sync_epoch: UUID
    version: int
    original_apply_version: int
    content_hash: str
    preview_hash: str
    batch_status: str
    created_count: int


def _invalid():
    raise ApiError("import_publication_invalid", 409)


def _identifier(value):
    try:
        return isinstance(value, str) and str(UUID(value)) == value
    except ValueError:
        return False


def _revision(value):
    return isinstance(value, str) and re.fullmatch(r"(?:0|[1-9][0-9]{0,18})", value) is not None


def _pieces(session, publication, *, check_budget):
    # At most 2000 tiny metadata records, never a 400k-event payload replay.
    pieces = list(
        session.scalars(
            select(ImportPublicationChunk)
            .where(ImportPublicationChunk.publication_id == publication.id)
            .order_by(ImportPublicationChunk.chunk_index)
            .limit(2001)
        )
    )
    if len(pieces) != publication.chunk_count:
        _invalid()
    count, commits = 0, []
    for index, piece in enumerate(pieces):
        check_budget()
        if (
            piece.chunk_index != index
            or piece.commit_id != uuid5(publication.id, f"sync-commit:{index}")
            or not 1 <= piece.event_count <= 200
        ):
            _invalid()
        commits.append(str(piece.commit_id))
        count += piece.event_count
    if count != publication.event_count or (
        not pieces and publication.events_sha256 != hashlib.sha256(b"[]").hexdigest()
    ):
        _invalid()
    return commits


def published_stage_context(session, principal, stage, *, check_budget):
    """Read formal consistency without reading source chunks, rows or events.

    This function deliberately neither calls require_current_client nor writes any
    row: the owner-specific callers already perform current-session checks under
    their own transaction/fence. It cannot grant a shared viewer financial access.
    """
    if not isinstance(stage, ImportStage) or not callable(check_budget):
        raise TypeError("persisted_published_stage_and_trusted_budget_required")
    if inspect(stage).session is not session or not inspect(stage).persistent:
        raise TypeError("stage_from_current_persistence_session_required")
    check_budget()
    if stage.owner_user_id != principal.user_id:
        raise ApiError("import_not_found", 404)
    batch = session.get(ImportBatch, stage.batch_id)
    if batch is None or batch.user_id != principal.user_id:
        raise ApiError("import_not_found", 404)
    publication = session.get(ImportPublication, stage.id)
    if (
        stage.status not in {"applied", "undoing", "undone"}
        or batch.status != ("undone" if stage.status == "undone" else "applied")
        or publication is None
        or publication.action != "apply"
        or publication.stage_id != stage.id
        or publication.batch_id != batch.id
        or publication.sync_epoch != stage.sync_epoch
        or batch.sync_epoch != stage.sync_epoch
        or publication.content_hash != batch.content_hash
        or publication.preview_hash != stage.preview_hash
        or publication.stage_version != stage.preview_version
        or not 1 <= publication.stage_version <= stage.stage_version
    ):
        _invalid()
    receipt = batch.result
    if (
        not isinstance(receipt, dict)
        or receipt.get("batch_id") != str(batch.id)
        or receipt.get("publication_id") != str(stage.id)
        or receipt.get("status") != "applied"
        or receipt.get("commit_id") is not None
        or receipt.get("replayed") is not False
        or not isinstance(receipt.get("created"), list)
        or not isinstance(receipt.get("duplicates"), list)
        or len(receipt["created"]) + len(receipt["duplicates"]) != stage.row_count
    ):
        _invalid()
    check_budget()
    # ImportItems are the durable undo index. A missing index entry must not
    # silently mark an untouched imported entity as successfully undone.
    item_count = session.scalar(
        select(func.count()).select_from(ImportItem).where(ImportItem.batch_id == batch.id)
    )
    if item_count != len(receipt["created"]):
        _invalid()
    if not isinstance(batch.required_scopes, list):
        _invalid()
    required = set()
    for index, identifier in enumerate(batch.required_scopes):
        if index % 500 == 0:
            check_budget()
        if not _identifier(identifier) or identifier in required:
            _invalid()
        required.add(identifier)
    if set(publication.permission_versions) != required or set(publication.checkpoint) != required:
        _invalid()
    for index, identifier in enumerate(required):
        if index % 500 == 0:
            check_budget()
        if not _revision(publication.permission_versions[identifier]) or not _revision(
            publication.checkpoint[identifier]
        ):
            _invalid()
    if receipt.get("commit_ids") != _pieces(session, publication, check_budget=check_budget):
        _invalid()
    # Execution was fenced when these formal rows were created. An archived
    # historical BackgroundJob must not become a new prerequisite for undo.
    reverse = session.get(ImportPublication, uuid5(stage.id, "undo"))
    if batch.status == "undone":
        if (
            reverse is None
            or reverse.action != "undo"
            or reverse.stage_id != stage.id
            or reverse.batch_id != batch.id
            or reverse.sync_epoch != stage.sync_epoch
            or reverse.content_hash != batch.content_hash
            or reverse.preview_hash != stage.preview_hash
            or not publication.stage_version <= reverse.stage_version <= stage.stage_version
        ):
            _invalid()
        _pieces(session, reverse, check_budget=check_budget)
    elif reverse is not None:
        _invalid()
    check_budget()
    return PublishedStageContext(
        stage_id=stage.id,
        batch_id=batch.id,
        user_id=principal.user_id,
        client_id=principal.client_id,
        sync_epoch=stage.sync_epoch,
        version=stage.stage_version,
        original_apply_version=publication.stage_version,
        content_hash=batch.content_hash,
        preview_hash=publication.preview_hash,
        batch_status=batch.status,
        created_count=item_count,
    )
