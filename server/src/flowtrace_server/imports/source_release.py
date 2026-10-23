"""Explicit owner-authorized source release; no timer or financial rewriting."""

from uuid import UUID

from sqlalchemy import delete, func, select

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.sync.common import run_transaction

from .parsers import digest
from .published_context import published_stage_context
from .staging import _current, _now, _stage
from .staging_models import (
    ImportStageRequirement,
    ImportStageRow,
    ImportStageSourceRelease,
    ImportStageUploadChunk,
)
from .staging_publish import _current_batch_scopes
from .staging_requirements import clear_stage_requirements
from .staging_schemas import StageSourceReleaseReceipt, StageSourceReleaseRequest


def _receipt(audit, *, replayed):
    return StageSourceReleaseReceipt(
        stage_id=str(audit.stage_id),
        batch_id=str(audit.batch_id),
        request_id=str(audit.request_id),
        stage_version=audit.stage_version,
        source_released_at=audit.released_at.isoformat(),
        reserved_bytes_released=audit.reserved_bytes_released,
        deleted_source_bytes=audit.deleted_source_bytes,
        deleted_source_chunks=audit.deleted_source_chunks,
        deleted_preview_rows=audit.deleted_preview_rows,
        deleted_requirement_rows=audit.deleted_requirement_rows,
        replayed=replayed,
    )


def _audit_matches(audit, stage, principal, body, request_hash):
    return (
        audit.stage_id == stage.id
        and audit.batch_id == stage.batch_id
        and audit.owner_user_id == principal.user_id
        and audit.origin_session_id == principal.session_id
        and audit.origin_purpose == principal.purpose
        and audit.client_id == principal.client_id
        and audit.sync_epoch == stage.sync_epoch
        and audit.request_id == UUID(body.request_id)
        and audit.request_hash == request_hash
        and audit.stage_version == body.stage_version
        and audit.source_sha256 == stage.source_sha256
        and audit.preview_hash == stage.preview_hash
        and audit.reserved_bytes_released == stage.expected_bytes
        and audit.received_bytes_snapshot == stage.received_bytes
        and audit.received_chunks_snapshot == stage.received_chunks
        and audit.source_rows_snapshot == stage.row_count
        and audit.released_at == stage.source_released_at
    )


def release_stage_source(session, principal, stage_id, body, *, check_budget):
    """Delete this confirmed stage source, then atomically mark/audit it.

    Stage version is a confirmation CAS; it does not advance or cancel queued
    formal undo. Deleted bytes are distinct from the released reservation.
    Current authority and formal proof precede even a replay. The caller never
    supplies an audit/session/path or execution budget.
    """
    if not isinstance(body, StageSourceReleaseRequest) or not callable(check_budget):
        raise TypeError("closed_source_release_and_trusted_budget_required")
    request_hash = digest({"stage_id": str(stage_id), "request": body.model_dump(mode="json")})

    def release():
        check_budget()
        state = _current(session, principal, epoch=body.sync_epoch, client_id=body.client_id)
        stage = _stage(
            session, principal, stage_id, state, version=body.stage_version, allow_expired=True
        )
        if stage.status not in {"applied", "undone"}:
            raise ApiError("import_stage_state_conflict", 409)
        if body.batch_id != str(stage.batch_id) or body.source_sha256 != stage.source_sha256:
            raise ApiError("import_stage_source_release_conflict", 409)
        if stage.status == "applied":
            _current_batch_scopes(session, principal, stage)
        # Undone batches need no resurrected book permission to release only
        # the owner's original upload. Formal reverse proof remains intact.
        published_stage_context(session, principal, stage, check_budget=check_budget)
        audit = session.get(ImportStageSourceRelease, stage.id)
        used = session.scalar(
            select(ImportStageSourceRelease.stage_id).where(
                ImportStageSourceRelease.owner_user_id == principal.user_id,
                ImportStageSourceRelease.request_id == UUID(body.request_id),
            )
        )
        if audit is not None or stage.source_released_at is not None:
            if audit is None or not _audit_matches(audit, stage, principal, body, request_hash):
                raise ApiError("import_stage_source_release_conflict", 409)
            check_budget()
            return _receipt(audit, replayed=True)
        if used is not None:
            raise ApiError("import_stage_source_release_conflict", 409)
        check_budget()
        chunks, byte_count = session.execute(
            select(
                func.count(), func.coalesce(func.sum(ImportStageUploadChunk.size_bytes), 0)
            ).where(ImportStageUploadChunk.stage_id == stage.id)
        ).one()
        rows = session.scalar(
            select(func.count())
            .select_from(ImportStageRow)
            .where(ImportStageRow.stage_id == stage.id)
        )
        requirements = session.scalar(
            select(func.count()).select_from(ImportStageRequirement).where(
                ImportStageRequirement.stage_id == stage.id
            )
        )
        if (
            chunks > stage.received_chunks
            or byte_count > stage.received_bytes
            or rows > stage.row_count
            or requirements != stage.requirements_count
        ):
            raise ApiError("import_stage_source_release_invalid", 409)
        check_budget()
        removed_chunks = session.execute(
            delete(ImportStageUploadChunk).where(ImportStageUploadChunk.stage_id == stage.id)
        ).rowcount
        check_budget()
        removed_rows = session.execute(
            delete(ImportStageRow).where(ImportStageRow.stage_id == stage.id)
        ).rowcount
        if removed_chunks != chunks or removed_rows != rows:
            raise ApiError("import_stage_source_release_changed", 409)
        check_budget()
        if clear_stage_requirements(session, stage) != requirements:
            raise ApiError("import_stage_source_release_changed", 409)
        check_budget()
        stamp = _now(session)
        audit = ImportStageSourceRelease(
            stage_id=stage.id,
            batch_id=stage.batch_id,
            owner_user_id=principal.user_id,
            origin_session_id=principal.session_id,
            origin_purpose=principal.purpose,
            client_id=principal.client_id,
            sync_epoch=stage.sync_epoch,
            stage_version=stage.stage_version,
            request_id=UUID(body.request_id),
            request_hash=request_hash,
            source_sha256=stage.source_sha256,
            preview_hash=stage.preview_hash,
            reserved_bytes_released=stage.expected_bytes,
            received_bytes_snapshot=stage.received_bytes,
            received_chunks_snapshot=stage.received_chunks,
            source_rows_snapshot=stage.row_count,
            deleted_source_bytes=byte_count,
            deleted_source_chunks=chunks,
            deleted_preview_rows=rows,
            deleted_requirement_rows=requirements,
            released_at=stamp,
        )
        session.add(audit)
        # The marker FK is immediate; persist its append-only target first.
        session.flush()
        _current(session, principal, epoch=body.sync_epoch, client_id=body.client_id)
        check_budget()
        stage.source_released_at, stage.updated_at = stamp, stamp
        session.flush()
        check_budget()
        return _receipt(audit, replayed=False)

    return run_transaction(session, release)
