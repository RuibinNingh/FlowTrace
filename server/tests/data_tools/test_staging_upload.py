"""Real PostgreSQL upload/session/job intents; no financial publication claim."""

import hashlib
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import timedelta
from threading import Barrier
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from sync.helpers import actor, epoch

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import User, UserSession
from flowtrace_server.auth.service import now
from flowtrace_server.imports.models import ImportBatch
from flowtrace_server.imports.parsers import digest
from flowtrace_server.imports.schemas import ImportRow
from flowtrace_server.imports.staging import (
    StagePolicy,
    cancel_stage,
    create_stage,
    put_stage_chunk,
    reauthorize_stage,
    seal_stage,
    stage_status,
    stage_work_context,
    update_stage_mapping,
)
from flowtrace_server.imports.staging_models import (
    ImportStage,
    ImportStageRow,
    ImportStageUploadChunk,
)
from flowtrace_server.imports.staging_schemas import (
    STAGE_CHUNK_BYTES,
    StageCreate,
    StageMapping,
    StageMappingUpdate,
    StageParseJob,
    StagePreviewJob,
    StageReauthorize,
    StageSeal,
)
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.jobs.store import claim, enqueue
from flowtrace_server.sync.models import SyncEntity

pytestmark = pytest.mark.postgres


def sha(content):
    return hashlib.sha256(content).hexdigest()


def start(engine, owner, content, *, policy=StagePolicy(), digest=None):
    body = StageCreate(
        client_id=str(owner.principal.client_id),
        sync_epoch=epoch(engine),
        format="flowtrace_json",
        expected_bytes=len(content),
        source_sha256=digest or sha(content),
    )
    with Session(engine) as session:
        return create_stage(session, owner.principal, body, policy=policy)


def upload(engine, owner, stage, index, content, *, version=None, digest=None):
    with Session(engine) as session:
        return put_stage_chunk(
            session,
            owner.principal,
            UUID(stage.stage_id),
            version or stage.stage_version,
            index,
            content,
            digest or sha(content),
        )


def sealed(engine, owner, stage, content):
    with Session(engine) as session:
        return seal_stage(
            session,
            owner.principal,
            UUID(stage.stage_id),
            StageSeal(
                stage_version=stage.stage_version,
                total_bytes=len(content),
                source_sha256=sha(content),
            ),
        )


def stored(engine, stage):
    with Session(engine) as session:
        row = session.get(ImportStage, UUID(stage.stage_id))
        return (
            row.status,
            row.stage_version,
            row.received_chunks,
            row.received_bytes,
            row.parse_job_id,
        )


def test_chunk_resume_replay_conflict_seal_and_no_financial_rows(postgres_engine):
    owner, outsider = actor(postgres_engine), actor(postgres_engine)
    content = b"a" * STAGE_CHUNK_BYTES + b"final-exact-bytes"
    stage = start(postgres_engine, owner, content)
    assert stage.stage_version == 1 and stage.expected_chunks == 2
    with pytest.raises(ApiError, match="import_stage_chunk_order"):
        upload(postgres_engine, owner, stage, 1, content[STAGE_CHUNK_BYTES:])
    first = upload(postgres_engine, owner, stage, 0, content[:STAGE_CHUNK_BYTES])
    assert not first.replayed and first.next_chunk_index == 1
    with Session(postgres_engine) as session:
        resumed = stage_status(session, owner.principal, UUID(stage.stage_id))
    assert resumed.received_chunks == 1 and resumed.received_bytes == STAGE_CHUNK_BYTES
    again = upload(postgres_engine, owner, stage, 0, content[:STAGE_CHUNK_BYTES])
    assert again.replayed and again.chunk_sha256 == first.chunk_sha256
    with pytest.raises(ApiError, match="import_stage_chunk_conflict"):
        upload(postgres_engine, owner, stage, 0, b"b" * STAGE_CHUNK_BYTES)
    with pytest.raises(ApiError, match="import_stage_chunk_size"):
        upload(postgres_engine, owner, stage, 1, b"wrong-size")
    with pytest.raises(ApiError, match="import_stage_chunk_hash"):
        upload(postgres_engine, owner, stage, 1, content[STAGE_CHUNK_BYTES:], digest="0" * 64)
    assert stored(postgres_engine, stage)[2:4] == (1, STAGE_CHUNK_BYTES)
    last = upload(postgres_engine, owner, stage, 1, content[STAGE_CHUNK_BYTES:])
    assert last.next_chunk_index == 2 and last.received_bytes == len(content)
    job = sealed(postgres_engine, owner, stage, content)
    replay = sealed(postgres_engine, owner, stage, content)
    assert job.job_id == replay.job_id and job.status == "uploaded"
    with Session(postgres_engine) as session:
        chunks = list(
            session.scalars(
                select(ImportStageUploadChunk)
                .where(ImportStageUploadChunk.stage_id == UUID(stage.stage_id))
                .order_by(ImportStageUploadChunk.chunk_index)
            )
        )
        assert b"".join(piece.content for piece in chunks) == content
        record = session.get(BackgroundJob, UUID(job.job_id))
        intent = StageParseJob.model_validate(record.payload)
        assert intent.stage_id == stage.stage_id and intent.source_sha256 == sha(content)
        assert set(record.payload) == {"action", "stage_id", "stage_version", "source_sha256"}
        assert record.owner_user_id == owner.principal.user_id
        assert not session.scalar(
            select(func.count())
            .select_from(ImportBatch)
            .where(ImportBatch.user_id == owner.principal.user_id)
        )
        assert (
            session.scalar(
                select(func.count())
                .select_from(SyncEntity)
                .where(SyncEntity.scope_id == owner.book_id)
            )
            == 1
        )
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_not_found"),
    ):
        stage_status(session, outsider.principal, UUID(stage.stage_id))


def test_seal_checks_whole_source_sha_without_publishing_job(postgres_engine):
    owner = actor(postgres_engine)
    content = b"immutable-upload"
    stage = start(postgres_engine, owner, content, digest="0" * 64)
    upload(postgres_engine, owner, stage, 0, content)
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_source_hash"),
    ):
        seal_stage(
            session,
            owner.principal,
            UUID(stage.stage_id),
            StageSeal(stage_version=1, total_bytes=len(content), source_sha256="0" * 64),
        )
    assert stored(postgres_engine, stage) == ("uploading", 1, 1, len(content), None)


def test_explicit_reauthorization_cancels_old_intent_and_rebinds_real_session(postgres_engine):
    owner = actor(postgres_engine)
    content = b"session-bound-source"
    stage = start(postgres_engine, owner, content)
    upload(postgres_engine, owner, stage, 0, content)
    old_job = sealed(postgres_engine, owner, stage, content)
    renewed = actor(postgres_engine, existing_user=owner.principal.user_id)
    with Session(postgres_engine) as session:
        session.get(UserSession, owner.principal.session_id).revoked_at = now()
        session.commit()
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_reauthorization_required"),
    ):
        stage_status(session, renewed.principal, UUID(stage.stage_id))
    with Session(postgres_engine) as session, pytest.raises(ApiError, match="session_invalid"):
        stage_work_context(session, UUID(old_job.job_id))
    with Session(postgres_engine) as session:
        updated = reauthorize_stage(
            session,
            renewed.principal,
            UUID(stage.stage_id),
            StageReauthorize(
                stage_version=1,
                client_id=str(renewed.principal.client_id),
                sync_epoch=epoch(postgres_engine),
            ),
        )
    assert updated.stage_version == 2 and updated.parse_job_id != old_job.job_id
    with Session(postgres_engine) as session:
        assert session.get(BackgroundJob, UUID(old_job.job_id)).status == "cancelled"
        record = session.get(ImportStage, UUID(stage.stage_id))
        assert record.origin_session_id == renewed.principal.session_id
        assert record.client_id == renewed.principal.client_id and record.source_sha256 == sha(
            content
        )
        job = session.get(BackgroundJob, UUID(updated.parse_job_id))
        # Make this run's own job first without cancelling unrelated retained
        # evidence, including leases from prior runs in this isolated DB.
        earliest = session.scalar(select(func.min(BackgroundJob.available_at)))
        job.available_at = earliest - timedelta(seconds=1)
        session.commit()
    with Session(postgres_engine) as session:
        lease = claim(session, uuid4(), ["import_preview"])
        session.commit()
    assert str(lease.job_id) == updated.parse_job_id
    with Session(postgres_engine) as session:
        context = stage_work_context(session, lease.job_id)
        assert context.principal.session_id == renewed.principal.session_id
        assert context.stage.stage_version == 2 and context.intent.action == "parse"
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_job_stale"),
    ):
        stage_work_context(session, UUID(old_job.job_id))


def test_mapping_change_preserves_source_and_invalidates_old_version(postgres_engine):
    owner = actor(postgres_engine)
    content = b"mapping-source-unchanged"
    stage = start(postgres_engine, owner, content)
    upload(postgres_engine, owner, stage, 0, content)
    old_job = sealed(postgres_engine, owner, stage, content)
    # Seed only the nonfinancial output of the future preview handler. This is
    # invalidation coverage, not evidence that parsing/preview workers exist.
    with Session(postgres_engine) as session:
        row = session.get(ImportStage, UUID(stage.stage_id))
        original = ImportRow(
            source_id=str(uuid4()),
            entity_type="category",
            scope_id=str(owner.book_id),
            payload={
                "name": "合成旧预览",
                "kind": "expense",
                "parent_id": None,
                "icon": "restaurant",
                "sort_order": 0,
            },
        )
        session.add(
            ImportStageRow(
                stage_id=row.id,
                position=1,
                source_line=2,
                source_id=UUID(original.source_id),
                row_payload=original.model_dump(mode="json"),
                raw_hash=digest(original.model_dump()),
                parsed_version=1,
                preview_version=1,
                dependencies=[],
                topological_position=1,
                target_entity_id=uuid4(),
                mapped_hash=digest(original.model_dump()),
                preview_status="new",
                preview_warning=None,
                errors=[],
            )
        )
        parsed_job = session.get(BackgroundJob, UUID(old_job.job_id))
        parsed_job.status, parsed_job.result = "succeeded", {"code": "synthetic_parsed"}
        intent = StagePreviewJob(
            action="preview",
            stage_id=stage.stage_id,
            stage_version=1,
            source_sha256=sha(content),
            mapping_hash=digest(row.mapping),
        )
        previous = enqueue(
            session,
            kind="import_preview",
            occurrence_key=f"synthetic-preview:{row.id}",
            owner_user_id=owner.principal.user_id,
            payload=intent.model_dump(mode="json"),
        )
        previous_id = previous.id
        row.status, row.preview_version, row.preview_hash = "ready", 1, "a" * 64
        row.row_count, row.preview_job_id = 1, previous.id
        row.required_scopes, row.permission_versions = (
            [str(owner.book_id)],
            {str(owner.book_id): "1"},
        )
        session.commit()
    with Session(postgres_engine) as session:
        result = update_stage_mapping(
            session,
            owner.principal,
            UUID(stage.stage_id),
            StageMappingUpdate(
                stage_version=1, mapping=StageMapping(source_namespace="mapped-new-namespace")
            ),
        )
    assert result.stage_version == 2 and result.parse_job_id != old_job.job_id
    with Session(postgres_engine) as session:
        row = session.get(ImportStage, UUID(stage.stage_id))
        assert row.source_sha256 == sha(content) and row.preview_hash is None
        assert row.permission_versions == {} and row.required_scopes == []
        assert row.mapping["source_namespace"] == "mapped-new-namespace"
        assert session.get(ImportStageUploadChunk, (row.id, 0)).content == content
        assert session.get(BackgroundJob, UUID(old_job.job_id)).status == "succeeded"
        assert session.get(BackgroundJob, previous_id).status == "cancelled"
        assert session.get(ImportStageRow, (row.id, 1)) is None and row.row_count == 0
    with pytest.raises(ApiError, match="import_stage_version_changed"):
        upload(postgres_engine, owner, stage, 0, content)


def test_concurrent_quota_reservation_and_cancel_releases_only_deleted_bytes(postgres_engine):
    owner = actor(postgres_engine)
    barrier = Barrier(2)
    policy = StagePolicy(max_retained_stages=1, max_reserved_bytes=64)

    def create_one():
        barrier.wait()
        try:
            return start(postgres_engine, owner, b"quota-reservation", policy=policy)
        except ApiError as error:
            return error.code

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: create_one(), range(2)))
    assert results.count("import_stage_quota_exceeded") == 1
    stage = next(item for item in results if not isinstance(item, str))
    upload(postgres_engine, owner, stage, 0, b"quota-reservation")
    with Session(postgres_engine) as session:
        cancelled = cancel_stage(session, owner.principal, UUID(stage.stage_id), 1)
    assert cancelled.status == "cancelled" and cancelled.received_bytes == 0
    with Session(postgres_engine) as session:
        assert session.get(ImportStageUploadChunk, (UUID(stage.stage_id), 0)) is None
    assert start(postgres_engine, owner, b"released", policy=policy).stage_id != stage.stage_id


@pytest.mark.parametrize("fault", ["client", "epoch", "purpose"])
def test_stage_create_rejects_identity_mismatch_without_stage(postgres_engine, fault):
    owner = actor(postgres_engine)
    body = StageCreate(
        client_id=str(owner.principal.client_id),
        sync_epoch=epoch(postgres_engine),
        format="flowtrace_json",
        expected_bytes=1,
        source_sha256=sha(b"a"),
    )
    principal = owner.principal
    if fault == "client":
        body = body.model_copy(update={"client_id": str(uuid4())})
    elif fault == "epoch":
        body = body.model_copy(update={"sync_epoch": str(uuid4())})
    else:
        principal = replace(principal, purpose="admin")
    with Session(postgres_engine) as session, pytest.raises(ApiError):
        create_stage(session, principal, body)
    with Session(postgres_engine) as session:
        assert not session.scalar(
            select(func.count())
            .select_from(ImportStage)
            .where(ImportStage.owner_user_id == owner.principal.user_id)
        )


def test_seal_rechecks_persisted_chunk_checksum(postgres_engine):
    owner = actor(postgres_engine)
    content = b"raw-byte-checksum"
    stage = start(postgres_engine, owner, content)
    upload(postgres_engine, owner, stage, 0, content)
    with Session(postgres_engine) as session:
        session.get(ImportStageUploadChunk, (UUID(stage.stage_id), 0)).sha256 = "0" * 64
        session.commit()
    with pytest.raises(ApiError, match="import_stage_source_hash"):
        sealed(postgres_engine, owner, stage, content)
    assert stored(postgres_engine, stage) == ("uploading", 1, 1, len(content), None)


def test_expiry_does_not_release_retained_storage_until_actual_cancel(postgres_engine):
    owner = actor(postgres_engine)
    content = b"retained-expired-bytes"
    policy = StagePolicy(max_retained_stages=1, max_reserved_bytes=100)
    stage = start(postgres_engine, owner, content, policy=policy)
    upload(postgres_engine, owner, stage, 0, content)
    with Session(postgres_engine) as session:
        row = session.get(ImportStage, UUID(stage.stage_id))
        row.created_at, row.expires_at = now() - timedelta(days=2), now() - timedelta(days=1)
        session.commit()
    with Session(postgres_engine) as session:
        assert stage_status(session, owner.principal, UUID(stage.stage_id)).status == "expired"
    with pytest.raises(ApiError, match="import_stage_expired"):
        upload(postgres_engine, owner, stage, 0, content)
    with pytest.raises(ApiError, match="import_stage_quota_exceeded"):
        start(postgres_engine, owner, b"replacement", policy=policy)
    with Session(postgres_engine) as session:
        assert cancel_stage(session, owner.principal, UUID(stage.stage_id), 1).status == "cancelled"
    assert start(postgres_engine, owner, b"replacement", policy=policy).stage_version == 1


@pytest.mark.parametrize("expired", ["access", "full", "idle", "disabled"])
def test_origin_session_expiry_never_falls_back_to_worker_authority(postgres_engine, expired):
    owner = actor(postgres_engine)
    content = b"origin-expiry-source"
    stage = start(postgres_engine, owner, content)
    upload(postgres_engine, owner, stage, 0, content)
    job = sealed(postgres_engine, owner, stage, content)
    with Session(postgres_engine) as session:
        record = session.get(UserSession, owner.principal.session_id)
        if expired == "disabled":
            session.get(User, owner.principal.user_id).enabled = False
        else:
            field = {
                "access": "access_expires_at",
                "full": "expires_at",
                "idle": "idle_expires_at",
            }[expired]
            setattr(record, field, now() - timedelta(seconds=1))
        session.commit()
    with Session(postgres_engine) as session, pytest.raises(ApiError, match="session_invalid"):
        stage_work_context(session, UUID(job.job_id))
    with Session(postgres_engine) as session:
        assert session.get(BackgroundJob, UUID(job.job_id)).status == "pending"
        assert session.get(ImportStage, UUID(stage.stage_id)).status == "uploaded"


@pytest.mark.parametrize("status", ["applying", "applied", "undoing", "undone"])
def test_financial_publication_states_reject_mapping_replacement(postgres_engine, status):
    owner = actor(postgres_engine)
    content = b"financial-phase-source"
    stage = start(postgres_engine, owner, content)
    upload(postgres_engine, owner, stage, 0, content)
    job = sealed(postgres_engine, owner, stage, content)
    with Session(postgres_engine) as session:
        row = session.get(ImportStage, UUID(stage.stage_id))
        row.status, row.preview_version, row.preview_hash = status, 1, "a" * 64
        session.commit()
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_state_conflict"),
    ):
        update_stage_mapping(
            session,
            owner.principal,
            UUID(stage.stage_id),
            StageMappingUpdate(stage_version=1, mapping=StageMapping(source_namespace="forbidden")),
        )
    assert stored(postgres_engine, stage) == (status, 1, 1, len(content), UUID(job.job_id))


def fixed_create(engine, owner, identifier):
    return StageCreate(
        stage_id=str(identifier),
        client_id=str(owner.principal.client_id),
        sync_epoch=epoch(engine),
        format="flowtrace_json",
        expected_bytes=12,
        source_sha256=sha(b"fixed-source"),
    )


def test_concurrent_same_fixed_create_id_recovers_one_stage_and_batch(postgres_engine):
    owner = actor(postgres_engine)
    identifier = uuid4()
    body = fixed_create(postgres_engine, owner, identifier)
    policy = StagePolicy(max_retained_stages=1, max_reserved_bytes=12)
    barrier = Barrier(2)

    def request():
        barrier.wait()
        with Session(postgres_engine) as session:
            return create_stage(session, owner.principal, body, policy=policy)

    with ThreadPoolExecutor(max_workers=2) as pool:
        first, second = list(pool.map(lambda _: request(), range(2)))
    assert first.model_dump() == second.model_dump()
    assert first.stage_id == str(identifier)
    with Session(postgres_engine) as session:
        assert (
            session.scalar(
                select(func.count())
                .select_from(ImportStage)
                .where(ImportStage.owner_user_id == owner.principal.user_id)
            )
            == 1
        )
    # Defaults written explicitly normalize identically to omitted defaults.
    explicit = StageCreate.model_validate(body.model_dump(mode="json"))
    with Session(postgres_engine) as session:
        replay = create_stage(session, owner.principal, explicit, policy=policy)
    assert replay.model_dump() == first.model_dump()


@pytest.mark.parametrize("difference", ["size", "hash", "format", "mapping"])
def test_same_fixed_create_id_rejects_different_body(postgres_engine, difference):
    owner = actor(postgres_engine)
    body = fixed_create(postgres_engine, owner, uuid4())
    with Session(postgres_engine) as session:
        created = create_stage(session, owner.principal, body)
    changed = body.model_dump(mode="json")
    if difference == "size":
        changed["expected_bytes"] += 1
    elif difference == "hash":
        changed["source_sha256"] = "0" * 64
    elif difference == "format":
        changed["format"] = "qianji_csv"
    else:
        changed["mapping"]["source_namespace"] = "different-namespace"
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_create_conflict"),
    ):
        create_stage(session, owner.principal, StageCreate.model_validate(changed))
    with Session(postgres_engine) as session:
        assert create_stage(session, owner.principal, body).batch_id == created.batch_id


@pytest.mark.parametrize("relationship", ["other_owner", "new_origin"])
def test_fixed_create_id_never_recovers_another_origin(postgres_engine, relationship):
    owner = actor(postgres_engine)
    body = fixed_create(postgres_engine, owner, uuid4())
    with Session(postgres_engine) as session:
        original = create_stage(session, owner.principal, body)
    visitor = actor(
        postgres_engine,
        existing_user=owner.principal.user_id if relationship == "new_origin" else None,
    )
    incoming = fixed_create(postgres_engine, visitor, UUID(original.stage_id))
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_create_conflict"),
    ):
        create_stage(session, visitor.principal, incoming)
    with Session(postgres_engine) as session:
        row = session.get(ImportStage, UUID(original.stage_id))
        assert (
            row.origin_session_id == owner.principal.session_id
            and str(row.batch_id) == original.batch_id
        )


def test_advanced_version_uses_get_recovery_not_old_create_replay(postgres_engine):
    owner = actor(postgres_engine)
    body = fixed_create(postgres_engine, owner, uuid4())
    with Session(postgres_engine) as session:
        original = create_stage(session, owner.principal, body)
    with Session(postgres_engine) as session:
        advanced = update_stage_mapping(
            session,
            owner.principal,
            UUID(original.stage_id),
            StageMappingUpdate(
                stage_version=1, mapping=StageMapping(source_namespace="explicit-new-mapping")
            ),
        )
    assert advanced.stage_version == 2
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_create_conflict"),
    ):
        create_stage(session, owner.principal, body)
    with Session(postgres_engine) as session:
        current = stage_status(session, owner.principal, UUID(original.stage_id))
    assert current.stage_version == 2 and current.batch_id == original.batch_id


def test_different_owners_racing_fixed_id_get_one_create_one_safe_conflict(postgres_engine):
    owners = [actor(postgres_engine), actor(postgres_engine)]
    identifier = uuid4()
    bodies = [fixed_create(postgres_engine, owner, identifier) for owner in owners]
    barrier = Barrier(2)

    def request(index):
        barrier.wait()
        try:
            with Session(postgres_engine) as session:
                return create_stage(session, owners[index].principal, bodies[index])
        except ApiError as error:
            return error.code

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(request, range(2)))
    assert results.count("import_stage_create_conflict") == 1
    winner = next(value for value in results if not isinstance(value, str))
    with Session(postgres_engine) as session:
        row = session.get(ImportStage, identifier)
        assert str(row.batch_id) == winner.batch_id
        assert (
            session.scalar(
                select(func.count()).select_from(ImportStage).where(ImportStage.id == identifier)
            )
            == 1
        )
