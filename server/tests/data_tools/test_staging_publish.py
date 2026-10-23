"""Formal publication rows and ledger effects share the real job completion."""

from datetime import timedelta
from uuid import UUID, uuid4, uuid5

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from sync.helpers import account, actor, epoch, expense, operation, push, revoke, share

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import UserSession
from flowtrace_server.imports.models import ImportBatch
from flowtrace_server.imports.staging_models import (
    ImportPublication,
    ImportPublicationChunk,
    ImportStage,
)
from flowtrace_server.imports.staging_publish import (
    apply_stage_in_transaction,
    request_stage_apply,
    request_stage_undo,
    undo_stage_in_transaction,
)
from flowtrace_server.imports.staging_reauthorize import reauthorize_published_stage
from flowtrace_server.imports.staging_schemas import StageApply, StageReauthorize, StageUndo
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.jobs.store import LeaseLost, claim, complete
from flowtrace_server.sync.models import SyncChange, SyncEntity

from .test_publication import staged_snapshot
from .test_staging_parsers import source_file
from .test_staging_preview import categories, complete_preview, prepare_preview

pytestmark = pytest.mark.postgres


def claim_apply(engine, job_id):
    with Session(engine) as session:
        earliest = session.scalar(select(func.min(BackgroundJob.available_at)))
        session.get(BackgroundJob, UUID(job_id)).available_at = earliest - timedelta(seconds=1)
        session.commit()
    with Session(engine) as session:
        lease = claim(session, uuid4(), ["import_apply"])
        session.commit()
    assert str(lease.job_id) == job_id
    return lease


def ready(engine, owner, content):
    stage, _, preview = prepare_preview(engine, owner, content)
    complete_preview(engine, preview)
    with Session(engine) as session:
        row = session.get(ImportStage, UUID(stage.stage_id))
        body = StageApply(
            stage_version=row.stage_version,
            batch_id=str(row.batch_id),
            preview_hash=row.preview_hash,
        )
        job = request_stage_apply(session, owner.principal, row.id, body)
    return stage, body, job, claim_apply(engine, job.job_id)


def apply(engine, lease, budget=lambda: None):
    with Session(engine) as session:
        result = complete(
            session,
            lease,
            lambda current, job: apply_stage_in_transaction(current, job.id, check_budget=budget),
        )
        session.commit()
        return result


def queued_undo(engine, owner, stage, version=1):
    with Session(engine) as session:
        job = request_stage_undo(
            session,
            owner.principal,
            UUID(stage.stage_id),
            StageUndo(stage_version=version, batch_id=stage.batch_id),
        )
    return job, claim_apply(engine, job.job_id)


def undo(engine, lease):
    with Session(engine) as session:
        result = complete(
            session,
            lease,
            lambda current, job: undo_stage_in_transaction(
                current, job.id, check_budget=lambda: None
            ),
        )
        session.commit()
        return result


def publication_chunks(session, identifier):
    return list(
        session.scalars(
            select(ImportPublicationChunk)
            .where(ImportPublicationChunk.publication_id == identifier)
            .order_by(ImportPublicationChunk.chunk_index)
        )
    )


def test_apply_and_undo_write_real_metadata_with_job_and_never_emit_entity_lists(postgres_engine):
    owner = actor(postgres_engine)
    stage, body, job, lease = ready(
        postgres_engine, owner, source_file("flowtrace_json", categories(owner, 75))
    )
    assert apply(postgres_engine, lease) == {"code": "import_stage_applied", "created_count": 75}
    with Session(postgres_engine) as session:
        row = session.get(ImportStage, UUID(stage.stage_id))
        publication = session.get(ImportPublication, row.id)
        chunks = publication_chunks(session, row.id)
        assert row.status == "applied" and publication.action == "apply"
        assert publication.batch_id == UUID(stage.batch_id) and publication.stage_version == 1
        assert publication.chunk_count == 1 and publication.event_count == 75
        assert len(chunks) == 1 and chunks[0].commit_id == uuid5(row.id, "sync-commit:0")
        assert chunks[0].event_count == 75 and len(chunks[0].sha256) == 64
        assert all(isinstance(value, str) for value in publication.permission_versions.values())
        assert set(publication.checkpoint) == set(publication.permission_versions)
        batch = session.get(ImportBatch, UUID(stage.batch_id))
        assert (
            publication.content_hash == batch.content_hash
            and publication.preview_hash == body.preview_hash
        )
        assert session.get(BackgroundJob, lease.job_id).result == {
            "code": "import_stage_applied",
            "created_count": 75,
        }
        replay = request_stage_apply(session, owner.principal, row.id, body)
        assert replay.job_id == job.job_id and replay.status == "applied"
    undo_job, undo_lease = queued_undo(postgres_engine, owner, stage)
    assert undo(postgres_engine, undo_lease) == {"code": "import_stage_undone", "created_count": 75}
    with Session(postgres_engine) as session:
        row = session.get(ImportStage, UUID(stage.stage_id))
        reverse = session.get(ImportPublication, uuid5(row.id, "undo"))
        assert row.status == "undone" and reverse.action == "undo" and reverse.event_count == 75
        assert publication_chunks(session, reverse.id)[0].commit_id == uuid5(
            uuid5(row.id, "undo"), "sync-commit:0"
        )
        assert session.get(ImportPublication, row.id).preview_hash == body.preview_hash
        assert session.get(ImportBatch, UUID(stage.batch_id)).status == "undone"
        replay = request_stage_undo(
            session, owner.principal, row.id, StageUndo(stage_version=1, batch_id=stage.batch_id)
        )
        assert replay.job_id == undo_job.job_id and replay.status == "undone"


def test_all_duplicate_publication_and_reverse_have_zero_real_chunks(postgres_engine):
    owner = actor(postgres_engine)
    content = source_file("flowtrace_json", categories(owner, 4))
    first, _, _, first_lease = ready(postgres_engine, owner, content)
    apply(postgres_engine, first_lease)
    second, _, _, second_lease = ready(postgres_engine, owner, content)
    assert apply(postgres_engine, second_lease) == {
        "code": "import_stage_applied",
        "created_count": 0,
    }
    _, undo_lease = queued_undo(postgres_engine, owner, second)
    assert undo(postgres_engine, undo_lease)["created_count"] == 0
    with Session(postgres_engine) as session:
        for identifier in (UUID(second.stage_id), uuid5(UUID(second.stage_id), "undo")):
            publication = session.get(ImportPublication, identifier)
            assert publication.chunk_count == publication.event_count == 0
            assert publication_chunks(session, identifier) == []
        assert session.get(ImportStage, UUID(first.stage_id)).status == "applied"
        assert (
            session.scalar(
                select(func.count())
                .select_from(SyncEntity)
                .where(SyncEntity.scope_id == owner.book_id, SyncEntity.deleted.is_(False))
            )
            == 5
        )


def test_second_real_chunk_budget_failure_and_final_lease_loss_publish_nothing(postgres_engine):
    owner = actor(postgres_engine)
    cash = account(postgres_engine, owner, opening="1000000")
    content = source_file(
        "flowtrace_json",
        [row.model_dump() for row in staged_snapshot(postgres_engine, owner, cash).rows],
    )
    stage, _, _, lease = ready(postgres_engine, owner, content)
    with Session(postgres_engine) as session:

        def budget():
            count = session.scalar(
                select(func.count())
                .select_from(SyncChange)
                .where(
                    SyncChange.commit_id.in_(
                        [uuid5(UUID(stage.stage_id), f"sync-commit:{index}") for index in range(3)]
                    )
                )
            )
            if count > 200:
                raise TimeoutError("budget_after_second_real_chunk")

        with pytest.raises(TimeoutError, match="budget_after_second_real_chunk"):
            complete(
                session,
                lease,
                lambda current, job: apply_stage_in_transaction(
                    current, job.id, check_budget=budget
                ),
            )
        session.commit()
    with Session(postgres_engine) as session:
        assert session.get(ImportStage, UUID(stage.stage_id)).status == "ready"
        assert session.get(SyncEntity, cash).balance_minor == 1000000
        assert session.get(ImportBatch, UUID(stage.batch_id)) is None
        assert session.get(ImportPublication, UUID(stage.stage_id)) is None
    with Session(postgres_engine) as session:

        def effect(current, job):
            result = apply_stage_in_transaction(current, job.id, check_budget=lambda: None)
            assert current.get(ImportPublication, UUID(stage.stage_id)) is not None
            job.lease_until = current.scalar(select(func.clock_timestamp())) - timedelta(seconds=1)
            current.flush()
            return result

        with pytest.raises(LeaseLost):
            complete(session, lease, effect)
        session.commit()
    with Session(postgres_engine) as session:
        assert session.get(ImportStage, UUID(stage.stage_id)).status == "ready"
        assert session.get(SyncEntity, cash).balance_minor == 1000000
        assert session.get(ImportPublication, UUID(stage.stage_id)) is None


def test_stale_scope_revision_is_rejected_before_any_financial_job(postgres_engine):
    owner = actor(postgres_engine)
    stage, _, preview = prepare_preview(
        postgres_engine, owner, source_file("flowtrace_json", categories(owner, 4))
    )
    complete_preview(postgres_engine, preview)
    with Session(postgres_engine) as session:
        row = session.get(ImportStage, UUID(stage.stage_id))
        body = StageApply(stage_version=1, batch_id=stage.batch_id, preview_hash=row.preview_hash)
    account(postgres_engine, owner)
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_preview_changed"),
    ):
        request_stage_apply(session, owner.principal, UUID(stage.stage_id), body)


def test_unrelated_new_record_does_not_permanently_block_stage_undo(postgres_engine):
    owner = actor(postgres_engine)
    stage, _, _, lease = ready(
        postgres_engine, owner, source_file("flowtrace_json", categories(owner, 4))
    )
    apply(postgres_engine, lease)
    unrelated = operation(
        owner.book_id, "category", {**categories(owner, 1)[0]["payload"], "name": "后续无关分类"}
    )
    assert push(postgres_engine, owner, unrelated)[0]["status"] == "applied"
    _, undo_lease = queued_undo(postgres_engine, owner, stage)
    assert undo(postgres_engine, undo_lease)["code"] == "import_stage_undone"
    with Session(postgres_engine) as session:
        assert not session.get(SyncEntity, UUID(unrelated["entity_id"])).deleted
        assert (
            session.scalar(
                select(func.count())
                .select_from(SyncEntity)
                .where(SyncEntity.scope_id == owner.book_id, SyncEntity.deleted.is_(False))
            )
            == 2
        )


@pytest.mark.parametrize("change", ["edit", "reference"])
def test_later_target_edit_or_reference_rejects_whole_stage_undo(postgres_engine, change):
    owner = actor(postgres_engine)
    rows = categories(owner, 4)
    stage, _, _, lease = ready(postgres_engine, owner, source_file("flowtrace_json", rows))
    apply(postgres_engine, lease)
    with Session(postgres_engine) as session:
        target = session.get(ImportBatch, UUID(stage.batch_id)).result["created"][0]
    if change == "edit":
        later = operation(
            owner.book_id,
            "category",
            {**rows[0]["payload"], "name": "合法修改"},
            identifier=target,
            action="update",
            revision="1",
        )
    else:
        later = operation(owner.book_id, "bill", expense(owner.book_id, category_id=target))
    assert push(postgres_engine, owner, later)[0]["status"] == "applied"
    _, undo_lease = queued_undo(postgres_engine, owner, stage)
    with pytest.raises(ApiError):
        undo(postgres_engine, undo_lease)
    with Session(postgres_engine) as session:
        assert session.get(ImportStage, UUID(stage.stage_id)).status == "applied"
        assert session.get(ImportPublication, uuid5(UUID(stage.stage_id), "undo")) is None
        assert not session.get(SyncEntity, UUID(target)).deleted


def test_new_real_session_explicitly_reauthorizes_only_undo_and_old_job_is_fenced(postgres_engine):
    owner = actor(postgres_engine)
    stage, apply_body, _, lease = ready(
        postgres_engine, owner, source_file("flowtrace_json", categories(owner, 4))
    )
    apply(postgres_engine, lease)
    _, stale_undo = queued_undo(postgres_engine, owner, stage)
    renewed = actor(postgres_engine, existing_user=owner.principal.user_id)
    with Session(postgres_engine) as session:
        original = session.get(ImportPublication, UUID(stage.stage_id))
        before = (
            original.content_hash,
            original.preview_hash,
            original.stage_version,
            original.permission_versions,
            original.checkpoint,
        )
        session.get(UserSession, owner.principal.session_id).revoked_at = session.scalar(
            select(func.clock_timestamp())
        )
        # Upload TTL is over; a formal published batch must still be undoable.
        row = session.get(ImportStage, UUID(stage.stage_id))
        row.created_at -= timedelta(days=10)
        row.expires_at = session.scalar(select(func.clock_timestamp())) - timedelta(seconds=1)
        session.commit()
    body = StageReauthorize(
        stage_version=1,
        client_id=str(renewed.principal.client_id),
        sync_epoch=epoch(postgres_engine),
    )
    with Session(postgres_engine) as session:
        rebound = reauthorize_published_stage(
            session, renewed.principal, UUID(stage.stage_id), body, check_budget=lambda: None
        )
    assert rebound.status == "applied" and rebound.stage_version == 2
    with pytest.raises(LeaseLost, match="job_lease_lost"):
        undo(postgres_engine, stale_undo)
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_job_stale"),
    ):
        undo_stage_in_transaction(session, stale_undo.job_id, check_budget=lambda: None)
    with Session(postgres_engine) as session:
        original = session.get(ImportPublication, UUID(stage.stage_id))
        assert (
            original.content_hash,
            original.preview_hash,
            original.stage_version,
            original.permission_versions,
            original.checkpoint,
        ) == before
        assert session.get(BackgroundJob, stale_undo.job_id).status == "cancelled"
    with Session(postgres_engine) as session, pytest.raises(ApiError):
        request_stage_apply(
            session,
            renewed.principal,
            UUID(stage.stage_id),
            apply_body.model_copy(update={"stage_version": 2}),
        )
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_version_changed"),
    ):
        request_stage_undo(
            session,
            renewed.principal,
            UUID(stage.stage_id),
            StageUndo(stage_version=1, batch_id=stage.batch_id),
        )
    _, undo_lease = queued_undo(postgres_engine, renewed, stage, version=2)
    assert undo(postgres_engine, undo_lease)["code"] == "import_stage_undone"
    with Session(postgres_engine) as session:
        assert (
            session.get(ImportPublication, uuid5(UUID(stage.stage_id), "undo")).stage_version == 2
        )
        assert session.get(ImportPublication, UUID(stage.stage_id)).content_hash == before[0]
        assert session.get(ImportBatch, UUID(stage.batch_id)).content_hash == before[0]


def test_published_reauthorization_does_not_restore_lost_write_permission(postgres_engine):
    owner, member = actor(postgres_engine), actor(postgres_engine)
    share(postgres_engine, owner, member)
    stage, _, _, lease = ready(
        postgres_engine, member, source_file("flowtrace_json", categories(owner, 4))
    )
    apply(postgres_engine, lease)
    revoke(postgres_engine, owner, member)
    renewed = actor(postgres_engine, existing_user=member.principal.user_id)
    with Session(postgres_engine) as session, pytest.raises(ApiError, match="scope_forbidden"):
        reauthorize_published_stage(
            session,
            renewed.principal,
            UUID(stage.stage_id),
            StageReauthorize(
                stage_version=1,
                client_id=str(renewed.principal.client_id),
                sync_epoch=epoch(postgres_engine),
            ),
            check_budget=lambda: None,
        )
    with Session(postgres_engine) as session:
        assert session.get(ImportStage, UUID(stage.stage_id)).stage_version == 1


def test_undo_metadata_and_domain_changes_roll_back_on_final_lease_loss(postgres_engine):
    owner = actor(postgres_engine)
    stage, _, _, lease = ready(
        postgres_engine, owner, source_file("flowtrace_json", categories(owner, 4))
    )
    apply(postgres_engine, lease)
    _, undo_lease = queued_undo(postgres_engine, owner, stage)
    with Session(postgres_engine) as session:

        def effect(current, job):
            result = undo_stage_in_transaction(current, job.id, check_budget=lambda: None)
            assert current.get(ImportPublication, uuid5(UUID(stage.stage_id), "undo")) is not None
            job.lease_until = current.scalar(select(func.clock_timestamp())) - timedelta(seconds=1)
            current.flush()
            return result

        with pytest.raises(LeaseLost):
            complete(session, undo_lease, effect)
        session.commit()
    with Session(postgres_engine) as session:
        assert session.get(ImportStage, UUID(stage.stage_id)).status == "applied"
        assert session.get(ImportPublication, uuid5(UUID(stage.stage_id), "undo")) is None
        assert (
            session.scalar(
                select(func.count())
                .select_from(SyncEntity)
                .where(SyncEntity.scope_id == owner.book_id, SyncEntity.deleted.is_(False))
            )
            == 5
        )
    assert undo(postgres_engine, undo_lease)["code"] == "import_stage_undone"


def test_undone_metadata_reauthorization_never_revives_apply_or_old_scope(postgres_engine):
    owner = actor(postgres_engine)
    stage, apply_body, _, lease = ready(
        postgres_engine, owner, source_file("flowtrace_json", categories(owner, 2))
    )
    apply(postgres_engine, lease)
    _, undo_lease = queued_undo(postgres_engine, owner, stage)
    undo(postgres_engine, undo_lease)
    renewed = actor(postgres_engine, existing_user=owner.principal.user_id)
    with Session(postgres_engine) as session:
        result = reauthorize_published_stage(
            session,
            renewed.principal,
            UUID(stage.stage_id),
            StageReauthorize(
                stage_version=1,
                client_id=str(renewed.principal.client_id),
                sync_epoch=epoch(postgres_engine),
            ),
            check_budget=lambda: None,
        )
        assert result.status == "undone" and result.stage_version == 2
    with Session(postgres_engine) as session, pytest.raises(ApiError):
        request_stage_apply(
            session,
            renewed.principal,
            UUID(stage.stage_id),
            apply_body.model_copy(update={"stage_version": 2}),
        )
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_state_conflict"),
    ):
        request_stage_undo(
            session,
            renewed.principal,
            UUID(stage.stage_id),
            StageUndo(stage_version=2, batch_id=stage.batch_id),
        )
