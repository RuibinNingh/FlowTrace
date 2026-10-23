"""Durable source parsing inside the caller's actual completion transaction."""

import hashlib
from uuid import UUID

from sqlalchemy import delete, insert, select

from flowtrace_server.auth.errors import ApiError

from .parsers import ImportFormatError
from .staging import _now, stage_work_context
from .staging_models import ImportStageRow, ImportStageUploadChunk
from .staging_parsers import open_stage_source
from .staging_requirements import RequirementCollector, clear_stage_requirements
from .staging_schemas import STAGE_CHUNK_BYTES, StageMapping, StageParseJob


def verified_stage_bytes(session, stage, *, check_budget):
    """Recheck immutable ordered BYTEA pieces before any parser consumes them."""
    if not callable(check_budget):
        raise TypeError("trusted_budget_callback_required")
    parts, whole, received = [], hashlib.sha256(), 0
    pieces = session.scalars(
        select(ImportStageUploadChunk)
        .where(ImportStageUploadChunk.stage_id == stage.id)
        .order_by(ImportStageUploadChunk.chunk_index)
        .execution_options(yield_per=1)
    )
    for index, piece in enumerate(pieces):
        check_budget()
        content = bytes(piece.content)
        expected = min(STAGE_CHUNK_BYTES, stage.expected_bytes - index * STAGE_CHUNK_BYTES)
        if (
            piece.chunk_index != index
            or len(content) != expected
            or piece.size_bytes != expected
            or hashlib.sha256(content).hexdigest() != piece.sha256
        ):
            raise ApiError("import_stage_source_changed", 409)
        parts.append(content)
        whole.update(content)
        received += len(content)
    if (
        len(parts) != stage.expected_chunks
        or stage.received_chunks != stage.expected_chunks
        or stage.received_bytes != stage.expected_bytes
        or received != stage.expected_bytes
        or whole.hexdigest() != stage.source_sha256
    ):
        raise ApiError("import_stage_source_changed", 409)
    check_budget()
    return b"".join(parts)


def parse_stage_in_transaction(session, actual_job_id, *, check_budget):
    """Write only stage rows; never commits, rolls back or renews the job.

    Root's jobs.complete owns the lease before/after this callback. Format
    failures are completed processing with a safe code and a failed stage.
    Authentication, integrity, lease, budget and database failures propagate.
    """
    if not callable(check_budget):
        raise TypeError("trusted_budget_callback_required")
    check_budget()
    context = stage_work_context(session, actual_job_id)
    if not isinstance(context.intent, StageParseJob):
        raise ApiError("import_stage_job_stale", 409)
    stage = context.stage
    content = verified_stage_bytes(session, stage, check_budget=check_budget)
    mapping = StageMapping.model_validate(stage.mapping)
    session.execute(delete(ImportStageRow).where(ImportStageRow.stage_id == stage.id))
    clear_stage_requirements(session, stage)
    stage.status, stage.row_count, stage.error_count = "parsing", 0, 0
    stage.preview_version, stage.preview_hash = None, None
    stage.required_scopes, stage.permission_versions = [], {}
    code, count, errors, pending, target_status = "import_stage_parsed", 0, 0, [], "parsed"
    collector = RequirementCollector(check_budget=check_budget)
    try:
        with open_stage_source(content, stage.format, mapping, check_budget=check_budget) as source:
            for parsed in source.rows:
                collector.add(parsed)
                count, errors = parsed.position, errors + len(parsed.errors)
                pending.append(
                    {
                        "stage_id": stage.id,
                        "position": parsed.position,
                        "source_line": parsed.source_line,
                        "source_id": UUID(parsed.row.source_id) if parsed.row else None,
                        "row_payload": parsed.row.model_dump(mode="json") if parsed.row else None,
                        "raw_hash": parsed.raw_hash,
                        "parsed_version": stage.stage_version,
                        "preview_version": None,
                        "dependencies": [],
                        "topological_position": None,
                        "target_entity_id": None,
                        "mapped_hash": None,
                        "preview_status": "invalid" if parsed.errors else None,
                        "preview_warning": None,
                        "errors": list(parsed.errors),
                    }
                )
                if len(pending) == 500:
                    check_budget()
                    session.execute(insert(ImportStageRow), pending)
                    pending.clear()
            if pending:
                check_budget()
                session.execute(insert(ImportStageRow), pending)
            collector.persist(session, stage, source.attachment_sources)
        if errors:
            code = "import_stage_parsed_with_errors"
    except ImportFormatError as error:
        session.execute(delete(ImportStageRow).where(ImportStageRow.stage_id == stage.id))
        clear_stage_requirements(session, stage)
        target_status, code, count, errors = "failed", error.code, 0, 1
    # Auth/session/expiry remains a final condition even for malformed files.
    stage_work_context(session, actual_job_id)
    stage.status, stage.row_count, stage.error_count = target_status, count, errors
    stage.updated_at = _now(session)
    check_budget()
    session.flush()
    return {"code": code, "created_count": count}
