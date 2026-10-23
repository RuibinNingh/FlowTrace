"""Financial effects and complete private publication metadata in one job fence."""

import hashlib
from uuid import UUID, uuid5

from sqlalchemy import select

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.books.models import SyncScope
from flowtrace_server.books.permissions import authorize_scope
from flowtrace_server.jobs import store as jobs
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.sync.common import lock_scopes, run_transaction
from flowtrace_server.sync.models import SyncChange

from .models import ImportBatch
from .parsers import canonical
from .publication import (
    apply_publication_in_transaction,
    request_from_stage,
    undo_published_in_transaction,
)
from .published_context import published_stage_context
from .service import request_content_hash
from .staging import _current, _now, _stage, stage_work_context
from .staging_holds import release_stage_holds, validate_original_sources
from .staging_models import ImportPublication, ImportPublicationChunk
from .staging_preview import lock_preview_scope_versions, snapshot_from_stage
from .staging_schemas import StageApply, StageApplyJob, StageJobResponse, StageUndo, StageUndoJob


def _response(stage, job):
    return StageJobResponse(
        stage_id=str(stage.id),
        stage_version=stage.stage_version,
        job_id=str(job.id),
        status=stage.status,
    )


def _existing_job(session, stage, action, intent):
    identifier = getattr(stage, f"{action}_job_id")
    if identifier is None:
        return None
    job = session.get(BackgroundJob, identifier)
    if (
        job is None
        or job.owner_user_id != stage.owner_user_id
        or job.payload != intent.model_dump(mode="json")
    ):
        raise ApiError("import_stage_job_stale", 409)
    return job


def _queue(session, stage, intent):
    job = jobs.enqueue(
        session,
        kind="import_apply",
        occurrence_key=f"import:{stage.id}:v{stage.stage_version}:{intent.action}",
        owner_user_id=stage.owner_user_id,
        payload=intent.model_dump(mode="json"),
    )
    setattr(stage, f"{intent.action}_job_id", job.id)
    stage.updated_at = _now(session)
    session.flush()
    return _response(stage, job)


def request_stage_apply(session, principal, stage_id, body):
    if not isinstance(body, StageApply):
        raise TypeError("closed_stage_apply_required")

    def request():
        state = _current(session, principal)
        stage = _stage(session, principal, stage_id, state, version=body.stage_version)
        if body.batch_id != str(stage.batch_id) or body.preview_hash != stage.preview_hash:
            raise ApiError("import_stage_preview_changed", 409)
        intent = StageApplyJob(
            action="apply",
            stage_id=str(stage.id),
            stage_version=stage.stage_version,
            batch_id=str(stage.batch_id),
            preview_hash=stage.preview_hash,
        )
        old = _existing_job(session, stage, "apply", intent)
        if old is not None:
            return _response(stage, old)
        if (
            stage.status != "ready"
            or stage.preview_version != stage.stage_version
            or stage.error_count
        ):
            raise ApiError("import_stage_state_conflict", 409)
        lock_preview_scope_versions(session, principal, stage, check_budget=lambda: None)
        return _queue(session, stage, intent)

    return run_transaction(session, request)


def _current_batch_scopes(session, principal, stage):
    batch = session.get(ImportBatch, stage.batch_id)
    if (
        batch is None
        or batch.user_id != principal.user_id
        or batch.result.get("publication_id") != str(stage.id)
    ):
        raise ApiError("import_not_found", 404)
    scopes = lock_scopes(session, {UUID(identifier) for identifier in batch.required_scopes})
    for identifier in scopes:
        authorize_scope(session, principal, identifier, write=True)
    return batch, scopes


def request_stage_undo(session, principal, stage_id, body):
    if not isinstance(body, StageUndo):
        raise TypeError("closed_stage_undo_required")

    def request():
        state = _current(session, principal)
        stage = _stage(session, principal, stage_id, state, version=body.stage_version)
        if body.batch_id != str(stage.batch_id):
            raise ApiError("import_stage_batch_changed", 409)
        intent = StageUndoJob(
            action="undo",
            stage_id=str(stage.id),
            stage_version=stage.stage_version,
            batch_id=str(stage.batch_id),
        )
        old = _existing_job(session, stage, "undo", intent)
        if old is not None:
            return _response(stage, old)
        if stage.status != "applied":
            raise ApiError("import_stage_state_conflict", 409)
        _current_batch_scopes(session, principal, stage)
        return _queue(session, stage, intent)

    return run_transaction(session, request)


def publication_event(change):
    """Private canonical full event. A viewer's projection must rehash its own data."""
    return {
        "scope_id": str(change.scope_id),
        "scope_revision": str(change.scope_revision),
        "event_index": change.event_index,
        "entity_type": change.entity_type,
        "entity_id": str(change.entity_id),
        "revision": str(change.revision),
        "deleted": change.deleted,
        "data": change.data,
    }


def _record_publication(session, stage, batch, result, action, *, check_budget):
    identifier = stage.id if action == "apply" else uuid5(stage.id, "undo")
    commits = [UUID(value) for value in result.commit_ids]
    if len(commits) > 2000 or len(commits) != len(set(commits)):
        raise ApiError("import_publication_invalid", 409)
    whole, total, chunks = hashlib.sha256(), 0, []
    whole.update(b"[")
    for index, commit in enumerate(commits):
        check_budget()
        if commit != uuid5(identifier, f"sync-commit:{index}"):
            raise ApiError("import_publication_invalid", 409)
        changes = list(
            session.scalars(
                select(SyncChange)
                .where(SyncChange.commit_id == commit)
                .order_by(SyncChange.scope_id, SyncChange.scope_revision, SyncChange.event_index)
            )
        )
        if not 1 <= len(changes) <= 200 or not {str(value.scope_id) for value in changes}.issubset(
            batch.required_scopes
        ):
            raise ApiError("import_publication_invalid", 409)
        events = []
        for change in changes:
            check_budget()
            event = publication_event(change)
            if total:
                whole.update(b",")
            whole.update(canonical(event))
            total += 1
            events.append(event)
        chunks.append(
            ImportPublicationChunk(
                publication_id=identifier,
                chunk_index=index,
                commit_id=commit,
                event_count=len(events),
                sha256=hashlib.sha256(canonical(events)).hexdigest(),
            )
        )
    whole.update(b"]")
    permissions, checkpoint = {}, {}
    for value in sorted(batch.required_scopes):
        check_budget()
        scope = session.get(SyncScope, UUID(value))
        if scope is None:
            raise ApiError("import_publication_invalid", 409)
        permissions[value], checkpoint[value] = str(scope.permission_version), str(scope.revision)
    record = ImportPublication(
        id=identifier,
        batch_id=batch.id,
        stage_id=stage.id,
        stage_version=stage.stage_version,
        action=action,
        sync_epoch=stage.sync_epoch,
        content_hash=batch.content_hash,
        preview_hash=stage.preview_hash,
        chunk_count=len(chunks),
        event_count=total,
        events_sha256=whole.hexdigest(),
        permission_versions=permissions,
        checkpoint=checkpoint,
        published_at=_now(session),
    )
    session.add(record)
    session.flush()
    for chunk in chunks:
        check_budget()
        session.add(chunk)
    session.flush()
    check_budget()
    return record


def apply_stage_in_transaction(session, actual_job_id, *, check_budget):
    if not callable(check_budget):
        raise TypeError("trusted_budget_callback_required")
    check_budget()
    context = stage_work_context(session, actual_job_id)
    if not isinstance(context.intent, StageApplyJob):
        raise ApiError("import_stage_job_stale", 409)
    stage = context.stage
    lock_preview_scope_versions(session, context.principal, stage, check_budget=check_budget)
    snapshot = snapshot_from_stage(session, context, check_budget=check_budget)
    validate_original_sources(session, context.principal, snapshot, check_budget=check_budget)
    stage.status = "applying"
    release_stage_holds(session, stage, check_budget=check_budget)
    result = apply_publication_in_transaction(
        session, context.principal, snapshot, check_budget=check_budget
    )
    batch = session.get(ImportBatch, stage.batch_id)
    if (
        result.replayed
        or result.status != "applied"
        or batch is None
        or batch.content_hash
        != request_content_hash(request_from_stage(snapshot, context.principal))
    ):
        raise ApiError("import_stage_publication_conflict", 409)
    _record_publication(session, stage, batch, result, "apply", check_budget=check_budget)
    stage_work_context(session, actual_job_id)
    check_budget()
    stage.status, stage.updated_at = "applied", _now(session)
    session.flush()
    return {"code": "import_stage_applied", "created_count": len(result.created)}


def undo_stage_in_transaction(session, actual_job_id, *, check_budget):
    if not callable(check_budget):
        raise TypeError("trusted_budget_callback_required")
    check_budget()
    context = stage_work_context(session, actual_job_id)
    if not isinstance(context.intent, StageUndoJob):
        raise ApiError("import_stage_job_stale", 409)
    stage = context.stage
    batch, _ = _current_batch_scopes(session, context.principal, stage)
    published = published_stage_context(
        session, context.principal, stage, check_budget=check_budget
    )
    stage.status = "undoing"
    # The original undo writer checks every created item, current references,
    # permission and attachment state. Unrelated additions remain allowed.
    result = undo_published_in_transaction(
        session, context.principal, published, check_budget=check_budget
    )
    if result.replayed:
        raise ApiError("import_stage_publication_conflict", 409)
    _record_publication(session, stage, batch, result, "undo", check_budget=check_budget)
    stage_work_context(session, actual_job_id)
    check_budget()
    stage.status, stage.updated_at = "undone", _now(session)
    session.flush()
    return {"code": "import_stage_undone", "created_count": published.created_count}
