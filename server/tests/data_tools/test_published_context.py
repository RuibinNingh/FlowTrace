"""New synthetic sources may disappear; formal undo never reconstructs apply."""

from copy import deepcopy
from uuid import UUID, uuid4, uuid5

import pytest
from sqlalchemy import delete, event, select
from sqlalchemy.orm import Session
from sync.helpers import actor, epoch, operation, push

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.imports.models import ImportBatch, ImportItem
from flowtrace_server.imports.published_context import published_stage_context
from flowtrace_server.imports.staging_models import (
    ImportPublication,
    ImportPublicationChunk,
    ImportStage,
    ImportStageRow,
    ImportStageUploadChunk,
)
from flowtrace_server.imports.staging_publish import request_stage_apply
from flowtrace_server.imports.staging_reauthorize import reauthorize_published_stage
from flowtrace_server.imports.staging_schemas import StageReauthorize
from flowtrace_server.sync.models import SyncEntity

from .test_staging_parsers import source_file
from .test_staging_preview import categories
from .test_staging_publish import apply, queued_undo, ready, undo

pytestmark = pytest.mark.postgres


@pytest.fixture
def published(postgres_engine):
    owner = actor(postgres_engine)
    stage, body, _, lease = ready(
        postgres_engine, owner, source_file("flowtrace_json", categories(owner, 4))
    )
    apply(postgres_engine, lease)
    return owner, stage, body


def omit_new_synthetic_source(engine, stage):
    # Only the newly generated fixture's bytes/rows are removed, never existing
    # user/test sources. This is a missing-source failure simulation, NOT GC.
    with Session(engine) as session, session.begin():
        identifier = UUID(stage.stage_id)
        session.execute(
            delete(ImportStageUploadChunk).where(ImportStageUploadChunk.stage_id == identifier)
        )
        session.execute(delete(ImportStageRow).where(ImportStageRow.stage_id == identifier))


def no_parser(*_, **__):
    raise AssertionError("published operation must not parse an ImportDocument")


def test_context_is_formal_metadata_read_only_and_never_reads_event_payloads(
    postgres_engine, published, monkeypatch
):
    owner, stage, _ = published
    monkeypatch.setattr("flowtrace_server.imports.staging_preview.open_stage_source", no_parser)

    def reject_history(_, __, statement, ___, ____, _____):
        assert "sync_changes" not in statement.lower()
        assert "background_jobs" not in statement.lower()

    event.listen(postgres_engine, "before_cursor_execute", reject_history)
    try:
        with Session(postgres_engine) as session:
            row = session.get(ImportStage, UUID(stage.stage_id))
            context = published_stage_context(
                session, owner.principal, row, check_budget=lambda: None
            )
            assert context.stage_id == row.id and context.batch_id == row.batch_id
            assert context.created_count == 4 and context.batch_status == "applied"
            assert context.original_apply_version == 1 and context.version == 1
            assert not session.new and not session.dirty and not session.deleted
    finally:
        event.remove(postgres_engine, "before_cursor_execute", reject_history)


def test_missing_synthetic_source_still_undoes_real_items_without_reapplying(
    postgres_engine, published, monkeypatch
):
    owner, stage, body = published
    omit_new_synthetic_source(postgres_engine, stage)
    monkeypatch.setattr("flowtrace_server.imports.staging_preview.open_stage_source", no_parser)
    with Session(postgres_engine) as session:
        before = deepcopy(session.get(ImportBatch, UUID(stage.batch_id)).result)
        replay = request_stage_apply(session, owner.principal, UUID(stage.stage_id), body)
        assert replay.status == "applied"
    _, lease = queued_undo(postgres_engine, owner, stage)
    assert undo(postgres_engine, lease) == {"code": "import_stage_undone", "created_count": 4}
    with Session(postgres_engine) as session:
        assert session.get(ImportBatch, UUID(stage.batch_id)).result == before
        assert session.get(ImportStage, UUID(stage.stage_id)).status == "undone"
        assert session.get(ImportPublication, uuid5(UUID(stage.stage_id), "undo")) is not None
        for identifier in before["created"]:
            assert session.get(SyncEntity, UUID(identifier)).deleted


def test_missing_source_explicit_new_origin_reauth_only_undo_and_preserves_original(
    postgres_engine, published, monkeypatch
):
    owner, stage, body = published
    omit_new_synthetic_source(postgres_engine, stage)
    renewed = actor(postgres_engine, owner.principal.user_id)
    monkeypatch.setattr("flowtrace_server.imports.staging_preview.open_stage_source", no_parser)
    with Session(postgres_engine) as session:
        publication = session.get(ImportPublication, UUID(stage.stage_id))
        before = (publication.content_hash, publication.preview_hash, publication.stage_version)
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
        assert result.status == "applied" and result.stage_version == 2
    with Session(postgres_engine) as session, pytest.raises(ApiError):
        request_stage_apply(
            session,
            renewed.principal,
            UUID(stage.stage_id),
            body.model_copy(update={"stage_version": 2}),
        )
    _, lease = queued_undo(postgres_engine, renewed, stage, version=2)
    assert undo(postgres_engine, lease)["created_count"] == 4
    with Session(postgres_engine) as session:
        publication = session.get(ImportPublication, UUID(stage.stage_id))
        assert (
            publication.content_hash,
            publication.preview_hash,
            publication.stage_version,
        ) == before
        assert session.get(ImportBatch, UUID(stage.batch_id)).content_hash == before[0]


def test_missing_source_keeps_real_current_item_conflict_protection(postgres_engine, published):
    owner, stage, _ = published
    omit_new_synthetic_source(postgres_engine, stage)
    with Session(postgres_engine) as session:
        item = session.scalar(select(ImportItem).where(ImportItem.batch_id == UUID(stage.batch_id)))
        entity = session.get(SyncEntity, item.entity_id)
        identifier, payload, revision = (
            entity.id,
            entity.payload | {"name": "后续合法更名"},
            entity.revision,
        )
    push(
        postgres_engine,
        owner,
        [
            operation(
                owner.book_id,
                "category",
                payload,
                identifier=identifier,
                action="update",
                revision=str(revision),
            )
        ],
    )
    _, lease = queued_undo(postgres_engine, owner, stage)
    with pytest.raises(ApiError, match="import_undo_conflict"):
        undo(postgres_engine, lease)
    with Session(postgres_engine) as session:
        assert not session.get(SyncEntity, identifier).deleted
        assert session.get(ImportStage, UUID(stage.stage_id)).status == "applied"
        assert session.get(ImportPublication, uuid5(UUID(stage.stage_id), "undo")) is None


@pytest.mark.parametrize(
    "damage",
    [
        "batch_hash",
        "preview_hash",
        "event_count",
        "commit_id",
        "receipt_commits",
        "missing_item",
        "scope_shape",
    ],
)
def test_formal_metadata_disagreement_rejects_without_any_financial_effect(
    postgres_engine, published, damage
):
    owner, stage, _ = published
    with Session(postgres_engine) as session, session.begin():
        batch = session.get(ImportBatch, UUID(stage.batch_id))
        publication = session.get(ImportPublication, UUID(stage.stage_id))
        piece = session.get(ImportPublicationChunk, (publication.id, 0))
        if damage == "batch_hash":
            batch.content_hash = "0" * 64
        elif damage == "preview_hash":
            publication.preview_hash = "0" * 64
        elif damage == "event_count":
            publication.event_count += 1
        elif damage == "commit_id":
            piece.commit_id = uuid4()
        elif damage == "receipt_commits":
            batch.result = batch.result | {"commit_ids": [str(uuid4())]}
        elif damage == "missing_item":
            item = session.scalar(select(ImportItem).where(ImportItem.batch_id == batch.id))
            session.delete(item)
        else:
            batch.required_scopes = [{"invalid": "not-an-identifier"}]
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_publication_invalid"),
    ):
        published_stage_context(
            session,
            owner.principal,
            session.get(ImportStage, UUID(stage.stage_id)),
            check_budget=lambda: None,
        )
    with Session(postgres_engine) as session:
        assert session.get(ImportStage, UUID(stage.stage_id)).status == "applied"
        assert session.get(ImportBatch, UUID(stage.batch_id)).status == "applied"


def test_formal_context_never_grants_foreign_owner_and_budget_failure_is_read_only(
    postgres_engine, published
):
    owner, stage, _ = published
    foreign = actor(postgres_engine)
    with Session(postgres_engine) as session, pytest.raises(ApiError, match="import_not_found"):
        published_stage_context(
            session,
            foreign.principal,
            session.get(ImportStage, UUID(stage.stage_id)),
            check_budget=lambda: None,
        )

    def expired():
        raise ApiError("test_budget_expired", 503)

    with Session(postgres_engine) as session, pytest.raises(ApiError, match="test_budget_expired"):
        published_stage_context(
            session,
            owner.principal,
            session.get(ImportStage, UUID(stage.stage_id)),
            check_budget=expired,
        )
