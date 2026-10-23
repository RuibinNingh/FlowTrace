"""Persistent private uploads and versioned intents, not a public capability.

Public wrappers own one transaction. stage_work_context does not: workers use
it inside their already fenced jobs.complete transaction. Source bytes and
credentials never enter a job; these operations publish no financial rows.
"""

import hashlib
import re
from dataclasses import dataclass
from datetime import timedelta
from uuid import UUID, uuid4

from pydantic import ValidationError
from sqlalchemy import delete, func, select

from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import roles_for
from flowtrace_server.jobs import store as jobs
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.sync.common import require_current_client, run_transaction

from .parsers import digest
from .staging_holds import release_stage_holds
from .staging_models import ImportStage, ImportStageRow, ImportStageUploadChunk
from .staging_requirements import clear_stage_requirements
from .staging_schemas import (
    STAGE_CHUNK_BYTES,
    StageApplyJob,
    StageChunkReceipt,
    StageCreate,
    StageCreated,
    StageJobResponse,
    StageMapping,
    StageMappingUpdate,
    StageParseJob,
    StagePreviewJob,
    StageReauthorize,
    StageSeal,
    StageStatusResponse,
    StageUndoJob,
)

HASH = re.compile(r"[0-9a-f]{64}\Z")
IMMUTABLE_STATES = frozenset({"applying", "applied", "undoing", "undone", "cancelled"})
TERMINAL_STATES = frozenset({"applied", "undone", "cancelled", "expired"})
JOB_FIELDS = {
    "parse": "parse_job_id",
    "preview": "preview_job_id",
    "apply": "apply_job_id",
    "undo": "undo_job_id",
}
JOB_TYPES = {
    "parse": StageParseJob,
    "preview": StagePreviewJob,
    "apply": StageApplyJob,
    "undo": StageUndoJob,
}


@dataclass(frozen=True)
class StagePolicy:
    """Trusted server budget; none of these values are client input."""

    ttl: timedelta = timedelta(days=7)
    max_retained_stages: int = 8
    max_reserved_bytes: int = 200 * 1024 * 1024

    def __post_init__(self):
        if (
            not isinstance(self.ttl, timedelta)
            or not timedelta(seconds=1) <= self.ttl <= timedelta(days=30)
            or type(self.max_retained_stages) is not int
            or not 1 <= self.max_retained_stages <= 10000
            or type(self.max_reserved_bytes) is not int
            or not 1 <= self.max_reserved_bytes < 2**63
        ):
            raise ValueError("stage_policy_invalid")


@dataclass(frozen=True)
class StageWorkContext:
    stage: ImportStage
    principal: Principal
    intent: StageParseJob | StagePreviewJob | StageApplyJob | StageUndoJob


def _now(session):
    return session.scalar(select(func.clock_timestamp()))


def _current(session, principal, *, epoch=None, client_id=None):
    if principal.purpose not in {"api_native", "api_web"}:
        raise ApiError("session_purpose_invalid", 403)
    state, _ = require_current_client(session, principal, epoch, client_id)
    return state


def _stage(session, principal, stage_id, state, *, version=None, origin=True, allow_expired=False):
    row = session.scalar(
        select(ImportStage)
        .where(ImportStage.id == stage_id, ImportStage.owner_user_id == principal.user_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if row is None:
        raise ApiError("import_stage_not_found", 404)
    if row.sync_epoch != state.sync_epoch:
        raise ApiError("epoch_changed", 409)
    if version is not None and (type(version) is not int or version != row.stage_version):
        raise ApiError("import_stage_version_changed", 409)
    if origin and (
        row.origin_session_id != principal.session_id
        or row.client_id != principal.client_id
        or row.origin_purpose != principal.purpose
    ):
        raise ApiError("import_stage_reauthorization_required", 409)
    if (
        not allow_expired
        and row.status not in {"applied", "undoing", "undone"}
        and row.expires_at <= _now(session)
    ):
        raise ApiError("import_stage_expired", 410)
    return row


def _status(row, stamp):
    status = row.status
    if row.expires_at <= stamp and status not in TERMINAL_STATES:
        status = "expired"
    values = {
        key: getattr(row, key)
        for key in (
            "stage_version",
            "format",
            "expected_bytes",
            "received_bytes",
            "received_chunks",
            "row_count",
            "error_count",
            "preview_hash",
        )
    }
    values["source_released"] = row.source_released_at is not None
    values["source_released_at"] = (
        row.source_released_at.isoformat() if row.source_released_at else None
    )
    values["requirements_version"] = row.requirements_version
    values["requirements_hash"] = row.requirements_hash
    values["requirements_count"] = row.requirements_count
    values["mapping_hash"] = digest(
        StageMapping.model_validate(row.mapping).model_dump(mode="json")
    )
    return StageStatusResponse(
        stage_id=str(row.id),
        batch_id=str(row.batch_id),
        status=status,
        **values,
        **{
            key: str(getattr(row, key)) if getattr(row, key) else None
            for key in JOB_FIELDS.values()
        },
        **{
            key: getattr(row, key).isoformat() for key in ("created_at", "updated_at", "expires_at")
        },
    )


def create_stage(session, principal, body, *, policy=StagePolicy()):
    if not isinstance(body, StageCreate) or not isinstance(policy, StagePolicy):
        raise TypeError("closed_stage_create_and_trusted_policy_required")

    def create():
        state = _current(session, principal, epoch=body.sync_epoch, client_id=body.client_id)
        if not body.format.startswith("qianji_") and body.mapping.template_mapping is not None:
            raise ApiError("template_mapping_not_applicable", 422)
        identifier = UUID(body.stage_id) if body.stage_id is not None else uuid4()
        if body.stage_id is not None:
            existing = session.scalar(
                select(ImportStage)
                .where(ImportStage.id == identifier)
                .with_for_update()
                .execution_options(populate_existing=True)
            )
            if existing is not None:
                # The original normalized create body is exactly recoverable
                # while v1 is unchanged. Later versions require GET recovery;
                # never relabel a new mapping/session as the original request.
                if (
                    existing.owner_user_id != principal.user_id
                    or existing.origin_session_id != principal.session_id
                    or existing.origin_purpose != principal.purpose
                    or existing.client_id != principal.client_id
                    or existing.sync_epoch != state.sync_epoch
                    or existing.stage_version != 1
                    or existing.format != body.format
                    or existing.expected_bytes != body.expected_bytes
                    or existing.source_sha256 != body.source_sha256
                    or existing.mapping != body.mapping.model_dump(mode="json")
                ):
                    raise ApiError("import_stage_create_conflict", 409)
                return _created(existing)
        # User lock serializes reservations. Expiry alone does not remove bytes.
        retained, reserved = session.execute(
            select(func.count(), func.coalesce(func.sum(ImportStage.expected_bytes), 0)).where(
                ImportStage.owner_user_id == principal.user_id,
                ImportStage.status.not_in(("cancelled", "expired")),
                ImportStage.source_released_at.is_(None),
            )
        ).one()
        if (
            retained >= policy.max_retained_stages
            or reserved + body.expected_bytes > policy.max_reserved_bytes
        ):
            raise ApiError("import_stage_quota_exceeded", 409)
        stamp = _now(session)
        row = ImportStage(
            id=identifier,
            batch_id=uuid4(),
            owner_user_id=principal.user_id,
            client_id=principal.client_id,
            sync_epoch=state.sync_epoch,
            origin_session_id=principal.session_id,
            origin_purpose=principal.purpose,
            format=body.format,
            status="uploading",
            stage_version=1,
            expected_bytes=body.expected_bytes,
            received_bytes=0,
            expected_chunks=(body.expected_bytes + STAGE_CHUNK_BYTES - 1) // STAGE_CHUNK_BYTES,
            received_chunks=0,
            source_sha256=body.source_sha256,
            mapping=body.mapping.model_dump(mode="json"),
            preview_version=None,
            preview_hash=None,
            required_scopes=[],
            permission_versions={},
            row_count=0,
            error_count=0,
            parse_job_id=None,
            preview_job_id=None,
            apply_job_id=None,
            undo_job_id=None,
            created_at=stamp,
            updated_at=stamp,
            expires_at=stamp + policy.ttl,
            sealed_at=None,
        )
        session.add(row)
        session.flush()
        return _created(row)

    return run_transaction(session, create)


def _created(row):
    return StageCreated(
        stage_id=str(row.id),
        batch_id=str(row.batch_id),
        stage_version=row.stage_version,
        expected_chunks=row.expected_chunks,
        expires_at=row.expires_at.isoformat(),
    )


def stage_status(session, principal, stage_id):
    def read():
        state = _current(session, principal)
        row = _stage(session, principal, stage_id, state, allow_expired=True)
        return _status(row, _now(session))

    return run_transaction(session, read)


def put_stage_chunk(session, principal, stage_id, stage_version, chunk_index, content, sha256):
    if type(content) is not bytes or not 1 <= len(content) <= STAGE_CHUNK_BYTES:
        raise ApiError("import_stage_chunk_size", 422)
    if type(chunk_index) is not int or not 0 <= chunk_index < 100:
        raise ApiError("import_stage_chunk_order", 409)
    if not isinstance(sha256, str) or HASH.fullmatch(sha256) is None:
        raise ApiError("import_stage_chunk_hash", 422)

    def put():
        state = _current(session, principal)
        row = _stage(session, principal, stage_id, state, version=stage_version)
        expected = min(STAGE_CHUNK_BYTES, row.expected_bytes - chunk_index * STAGE_CHUNK_BYTES)
        if len(content) != expected:
            raise ApiError("import_stage_chunk_size", 422)
        if hashlib.sha256(content).hexdigest() != sha256:
            raise ApiError("import_stage_chunk_hash", 422)
        old = session.get(ImportStageUploadChunk, (row.id, chunk_index))
        replayed = old is not None
        if old is not None:
            if old.sha256 != sha256 or old.size_bytes != len(content) or old.content != content:
                raise ApiError("import_stage_chunk_conflict", 409)
        else:
            if chunk_index != row.received_chunks:
                raise ApiError("import_stage_chunk_order", 409)
            if row.status != "uploading":
                raise ApiError("import_stage_state_conflict", 409)
            stamp = _now(session)
            session.add(
                ImportStageUploadChunk(
                    stage_id=row.id,
                    chunk_index=chunk_index,
                    content=content,
                    size_bytes=len(content),
                    sha256=sha256,
                    created_at=stamp,
                )
            )
            row.received_chunks += 1
            row.received_bytes += len(content)
            row.updated_at = stamp
            session.flush()
        return StageChunkReceipt(
            stage_id=str(row.id),
            stage_version=row.stage_version,
            chunk_index=chunk_index,
            chunk_sha256=sha256,
            size_bytes=len(content),
            next_chunk_index=row.received_chunks,
            received_bytes=row.received_bytes,
            expected_bytes=row.expected_bytes,
            replayed=replayed,
        )

    return run_transaction(session, put)


def _queue_parse(session, row):
    intent = StageParseJob(
        action="parse",
        stage_id=str(row.id),
        stage_version=row.stage_version,
        source_sha256=row.source_sha256,
    )
    job = jobs.enqueue(
        session,
        kind="import_preview",
        occurrence_key=f"import:{row.id}:v{row.stage_version}:parse",
        owner_user_id=row.owner_user_id,
        payload=intent.model_dump(mode="json"),
    )
    row.parse_job_id = job.id
    session.flush()
    return job


def seal_stage(session, principal, stage_id, body):
    if not isinstance(body, StageSeal):
        raise TypeError("closed_stage_seal_required")

    def seal():
        state = _current(session, principal)
        row = _stage(session, principal, stage_id, state, version=body.stage_version)
        if body.total_bytes != row.expected_bytes or body.source_sha256 != row.source_sha256:
            raise ApiError("import_stage_source_hash", 422)
        if row.received_chunks != row.expected_chunks or row.received_bytes != row.expected_bytes:
            raise ApiError("import_stage_upload_incomplete", 409)
        if row.parse_job_id is not None and row.sealed_at is not None:
            return StageJobResponse(
                stage_id=str(row.id),
                stage_version=row.stage_version,
                job_id=str(row.parse_job_id),
                status=row.status,
            )
        if row.status != "uploading":
            raise ApiError("import_stage_state_conflict", 409)
        checksum, count, total = hashlib.sha256(), 0, 0
        pieces = session.scalars(
            select(ImportStageUploadChunk)
            .where(ImportStageUploadChunk.stage_id == row.id)
            .order_by(ImportStageUploadChunk.chunk_index)
            .execution_options(yield_per=1)
        )
        for piece in pieces:
            expected = min(STAGE_CHUNK_BYTES, row.expected_bytes - count * STAGE_CHUNK_BYTES)
            if (
                piece.chunk_index != count
                or piece.size_bytes != expected
                or len(piece.content) != expected
                or hashlib.sha256(piece.content).hexdigest() != piece.sha256
            ):
                raise ApiError("import_stage_source_hash", 422)
            checksum.update(piece.content)
            count, total = count + 1, total + piece.size_bytes
        if (
            count != row.expected_chunks
            or total != row.expected_bytes
            or checksum.hexdigest() != row.source_sha256
        ):
            raise ApiError("import_stage_source_hash", 422)
        stamp = _now(session)
        if row.expires_at <= stamp:
            raise ApiError("import_stage_expired", 410)
        row.status, row.sealed_at, row.updated_at = "uploaded", stamp, stamp
        job = _queue_parse(session, row)
        return StageJobResponse(
            stage_id=str(row.id),
            stage_version=row.stage_version,
            job_id=str(job.id),
            status=row.status,
        )

    return run_transaction(session, seal)


def _invalidate(session, row, *, check_budget=lambda: None):
    check_budget()
    if row.status in IMMUTABLE_STATES:
        raise ApiError("import_stage_state_conflict", 409)
    if row.stage_version >= 2**31 - 1:
        raise ApiError("import_stage_version_exhausted", 409)
    release_stage_holds(session, row, check_budget=check_budget)
    # Same-owner transactions acquire the user lock before touching jobs.
    for identifier in sorted({getattr(row, key) for key in JOB_FIELDS.values()} - {None}, key=str):
        check_budget()
        old = session.get(BackgroundJob, identifier)
        if (
            old is None
            or old.owner_user_id != row.owner_user_id
            or old.payload.get("stage_id") != str(row.id)
        ):
            raise ApiError("import_stage_job_stale", 409)
        if old.status != "succeeded":
            jobs.cancel(session, identifier)
    session.execute(delete(ImportStageRow).where(ImportStageRow.stage_id == row.id))
    check_budget()
    clear_stage_requirements(session, row)
    check_budget()
    row.stage_version += 1
    row.preview_version = row.preview_hash = None
    row.row_count = row.error_count = 0
    row.required_scopes, row.permission_versions = [], {}
    for key in JOB_FIELDS.values():
        setattr(row, key, None)
    row.status = "uploaded" if row.sealed_at is not None else "uploading"
    row.updated_at = _now(session)


def update_stage_mapping(session, principal, stage_id, body):
    if not isinstance(body, StageMappingUpdate):
        raise TypeError("closed_stage_mapping_required")

    def update():
        state = _current(session, principal)
        row = _stage(session, principal, stage_id, state, version=body.stage_version)
        if not row.format.startswith("qianji_") and body.mapping.template_mapping is not None:
            raise ApiError("template_mapping_not_applicable", 422)
        _invalidate(session, row)
        row.mapping = body.mapping.model_dump(mode="json")
        if row.sealed_at is not None:
            _queue_parse(session, row)
        session.flush()
        return _status(row, _now(session))

    return run_transaction(session, update)


def reauthorize_stage(session, principal, stage_id, body):
    if not isinstance(body, StageReauthorize):
        raise TypeError("closed_stage_reauthorization_required")

    def reauthorize():
        state = _current(session, principal, epoch=body.sync_epoch, client_id=body.client_id)
        row = _stage(session, principal, stage_id, state, version=body.stage_version, origin=False)
        _invalidate(session, row)
        row.origin_session_id, row.origin_purpose = principal.session_id, principal.purpose
        row.client_id = principal.client_id
        if row.sealed_at is not None:
            _queue_parse(session, row)
        session.flush()
        return _status(row, _now(session))

    return run_transaction(session, reauthorize)


def cancel_stage(session, principal, stage_id, stage_version):
    def cancel():
        state = _current(session, principal)
        row = _stage(session, principal, stage_id, state, version=stage_version, allow_expired=True)
        if row.status != "cancelled":
            _invalidate(session, row)
            session.execute(
                delete(ImportStageUploadChunk).where(ImportStageUploadChunk.stage_id == row.id)
            )
            row.received_bytes = row.received_chunks = 0
            row.status = "cancelled"
            session.flush()
        return _status(row, _now(session))

    return run_transaction(session, cancel)


def stage_work_context(session, job_id):
    """Rehydrate a real origin in the caller's jobs.complete lease fence.

    This check alone never authorizes executing a job. jobs.complete must still
    check its actual lease before and after the handler's effect.
    """
    job = session.get(BackgroundJob, job_id)
    if job is None or not isinstance(job.payload, dict):
        raise ApiError("import_stage_job_stale", 409)
    action = job.payload.get("action")
    expected = JOB_TYPES.get(action)
    if expected is None:
        raise ApiError("import_stage_job_stale", 409)
    try:
        intent = expected.model_validate(job.payload)
    except ValidationError:
        raise ApiError("import_stage_job_stale", 409) from None
    candidate = session.get(ImportStage, UUID(intent.stage_id))
    if candidate is None or candidate.owner_user_id != job.owner_user_id:
        raise ApiError("import_stage_job_stale", 409)
    principal = Principal(
        candidate.owner_user_id,
        candidate.origin_session_id,
        candidate.client_id,
        candidate.origin_purpose,
        roles_for(session, candidate.owner_user_id),
    )
    state = _current(
        session, principal, epoch=str(candidate.sync_epoch), client_id=str(candidate.client_id)
    )
    job = session.scalar(
        select(BackgroundJob)
        .where(BackgroundJob.id == job_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if job is None or job.status != "running":
        raise ApiError("import_stage_job_stale", 409)
    row = _stage(session, principal, candidate.id, state, version=intent.stage_version)
    kind = "import_preview" if action in {"parse", "preview"} else "import_apply"
    if (
        job.status != "running"
        or job.kind != kind
        or job.sync_epoch != row.sync_epoch
        or job.owner_user_id != row.owner_user_id
        or job.payload != intent.model_dump(mode="json")
        or getattr(row, JOB_FIELDS[action]) != job.id
    ):
        raise ApiError("import_stage_job_stale", 409)
    if action in {"parse", "preview"} and intent.source_sha256 != row.source_sha256:
        raise ApiError("import_stage_job_stale", 409)
    if action == "preview" and intent.mapping_hash != digest(row.mapping):
        raise ApiError("import_stage_job_stale", 409)
    if action in {"apply", "undo"} and intent.batch_id != str(row.batch_id):
        raise ApiError("import_stage_job_stale", 409)
    if action == "apply" and (
        intent.preview_hash != row.preview_hash or row.preview_version != row.stage_version
    ):
        raise ApiError("import_stage_job_stale", 409)
    allowed = {
        "parse": {"uploaded", "parsing"},
        "preview": {"parsed", "previewing"},
        "apply": {"ready", "applying"},
        "undo": {"applied", "undoing"},
    }
    if row.status not in allowed[action]:
        raise ApiError("import_stage_job_stale", 409)
    return StageWorkContext(row, principal, intent)
