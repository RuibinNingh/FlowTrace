"""Explicit owner discard of unpublished source, independent of old origin.

This desired-state operation never binds the caller as the stage origin. The
only permitted successful state is cancelled with actual retained source gone.
Financial publications, including ambiguous applying states, are never erased.
"""

from uuid import uuid5

from sqlalchemy import delete, or_, select

from flowtrace_server.attachments.models import AttachmentHold
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.sync.common import run_transaction

from .models import ImportBatch
from .staging import JOB_FIELDS, _current, _invalidate, _now, _stage, _status
from .staging_models import (
    ImportPublication,
    ImportStageRequirement,
    ImportStageRow,
    ImportStageUploadChunk,
)
from .staging_schemas import StageDiscard

FINANCIAL_STATES = frozenset({"applying", "applied", "undoing", "undone"})


def _empty_cancelled(session, stage, requested_version, check_budget):
    if (
        stage.received_bytes
        or stage.received_chunks
        or stage.row_count
        or stage.error_count
        or stage.preview_hash is not None
        or stage.preview_version is not None
        or stage.requirements_version is not None
        or stage.requirements_hash is not None
        or stage.requirements_count
        or any(getattr(stage, name) is not None for name in JOB_FIELDS.values())
    ):
        raise ApiError("import_stage_discard_incomplete", 409)
    for model, column in (
        (ImportStageUploadChunk, ImportStageUploadChunk.chunk_index),
        (ImportStageRow, ImportStageRow.position),
        (ImportStageRequirement, ImportStageRequirement.position),
    ):
        check_budget()
        if session.scalar(select(column).where(model.stage_id == stage.id).limit(1)) is not None:
            raise ApiError("import_stage_discard_incomplete", 409)
    own_ids = {
        uuid5(stage.id, f"attachment-hold:v{version}")
        for version in (stage.stage_version, requested_version)
    }
    if (
        session.scalar(
            select(AttachmentHold.hold_id).where(AttachmentHold.hold_id.in_(own_ids)).limit(1)
        )
        is not None
    ):
        raise ApiError("import_stage_discard_incomplete", 409)


def discard_stage(session, principal, stage_id, body, *, check_budget):
    if not isinstance(body, StageDiscard) or not callable(check_budget):
        raise TypeError("closed_stage_discard_and_trusted_budget_required")

    def discard():
        check_budget()
        state = _current(session, principal, epoch=body.sync_epoch, client_id=body.client_id)
        stage = _stage(session, principal, stage_id, state, origin=False, allow_expired=True)
        if body.batch_id != str(stage.batch_id) or body.source_sha256 != stage.source_sha256:
            raise ApiError("import_stage_discard_conflict", 409)
        if stage.status in FINANCIAL_STATES or stage.source_released_at is not None:
            raise ApiError("import_stage_state_conflict", 409)
        if (
            session.get(ImportBatch, stage.batch_id) is not None
            or session.scalar(
                select(ImportPublication.id)
                .where(
                    or_(
                        ImportPublication.stage_id == stage.id,
                        ImportPublication.batch_id == stage.batch_id,
                    )
                )
                .limit(1)
            )
            is not None
        ):
            raise ApiError("import_stage_state_conflict", 409)
        check_budget()
        if stage.status == "cancelled":
            if stage.stage_version not in {body.stage_version, body.stage_version + 1}:
                raise ApiError("import_stage_version_changed", 409)
            _empty_cancelled(session, stage, body.stage_version, check_budget)
        else:
            if stage.stage_version != body.stage_version:
                raise ApiError("import_stage_version_changed", 409)
            _invalidate(session, stage, check_budget=check_budget)
            check_budget()
            session.execute(
                delete(ImportStageUploadChunk).where(ImportStageUploadChunk.stage_id == stage.id)
            )
            check_budget()
            stage.received_bytes = stage.received_chunks = 0
            stage.status, stage.updated_at = "cancelled", _now(session)
        _current(session, principal, epoch=body.sync_epoch, client_id=body.client_id)
        check_budget()
        session.flush()
        check_budget()
        return _status(stage, _now(session))

    return run_transaction(session, discard)
