"""Explicit releases affect only newly generated test stages on a fresh DB."""

from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from threading import Barrier
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, insert, select, text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.orm import Session
from sync.helpers import actor, epoch, revoke, share

from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import User, UserSession
from flowtrace_server.auth.service import issue_session
from flowtrace_server.imports.models import ImportBatch
from flowtrace_server.imports.source_release import release_stage_source
from flowtrace_server.imports.staging import StagePolicy, create_stage, stage_status
from flowtrace_server.imports.staging_models import (
    ImportPublication,
    ImportStage,
    ImportStageRow,
    ImportStageSourceRelease,
    ImportStageUploadChunk,
)
from flowtrace_server.imports.staging_reauthorize import reauthorize_published_stage
from flowtrace_server.imports.staging_rows import stage_rows
from flowtrace_server.imports.staging_schemas import (
    StageCreate,
    StageReauthorize,
    StageSourceReleaseRequest,
)
from flowtrace_server.persistence.registry import Base

from .test_staging_http import headers, post, run, status
from .test_staging_http import ready as http_ready
from .test_staging_http import stage_http as stage_http
from .test_staging_parsers import source_file
from .test_staging_preview import categories
from .test_staging_publish import apply, queued_undo, ready, undo

pytestmark = pytest.mark.postgres


def published(engine, owner=None, *, target=None):
    owner = owner or actor(engine)
    stage, _, _, lease = ready(
        engine, owner, source_file("flowtrace_json", categories(target or owner, 4))
    )
    apply(engine, lease)
    with Session(engine) as session:
        row = session.get(ImportStage, UUID(stage.stage_id))
        body = StageSourceReleaseRequest(
            stage_version=1,
            request_id=str(uuid4()),
            batch_id=stage.batch_id,
            client_id=str(owner.principal.client_id),
            sync_epoch=epoch(engine),
            source_sha256=row.source_sha256,
        )
    return owner, stage, body


def release(engine, owner, stage, body, budget=lambda: None):
    with Session(engine) as session:
        return release_stage_source(
            session, owner.principal, UUID(stage.stage_id), body, check_budget=budget
        )


def source_snapshot(engine, stage):
    with Session(engine) as session:
        row = session.get(ImportStage, UUID(stage.stage_id))
        chunks = list(
            session.scalars(
                select(ImportStageUploadChunk)
                .where(ImportStageUploadChunk.stage_id == row.id)
                .order_by(ImportStageUploadChunk.chunk_index)
            )
        )
        return (
            row.source_released_at,
            row.received_bytes,
            row.received_chunks,
            row.preview_hash,
            tuple((value.chunk_index, value.sha256, bytes(value.content)) for value in chunks),
            session.scalar(
                select(func.count())
                .select_from(ImportStageRow)
                .where(ImportStageRow.stage_id == row.id)
            ),
        )


def test_explicit_release_keeps_history_metadata_and_other_stage_source(postgres_engine):
    owner, stage, body = published(postgres_engine)
    _, other, _ = published(postgres_engine, owner)
    untouched = source_snapshot(postgres_engine, other)
    before = source_snapshot(postgres_engine, stage)
    with Session(postgres_engine) as session:
        financial = deepcopy(session.get(ImportBatch, UUID(stage.batch_id)).result)
        content_hash = session.get(ImportPublication, UUID(stage.stage_id)).content_hash
    receipt = release(postgres_engine, owner, stage, body)
    assert not receipt.replayed and receipt.deleted_source_bytes == before[1]
    assert receipt.deleted_source_chunks == before[2] and receipt.deleted_preview_rows == 4
    assert source_snapshot(postgres_engine, other) == untouched
    after = source_snapshot(postgres_engine, stage)
    assert after[0] is not None and after[1:4] == before[1:4] and after[4:] == ((), 0)
    with Session(postgres_engine) as session:
        current = stage_status(session, owner.principal, UUID(stage.stage_id))
        assert current.source_released and current.received_bytes == before[1]
        assert current.status == "applied" and current.stage_version == 1
        assert session.get(ImportBatch, UUID(stage.batch_id)).result == financial
        assert session.get(ImportPublication, UUID(stage.stage_id)).content_hash == content_hash
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_source_released") as caught,
    ):
        stage_rows(session, owner.principal, UUID(stage.stage_id), stage_version=1)
    assert caught.value.status == 410


def test_same_frozen_release_replays_but_different_body_or_nonce_never_rewrites_audit(
    postgres_engine,
):
    owner, stage, body = published(postgres_engine)
    first = release(postgres_engine, owner, stage, body)
    repeated = release(postgres_engine, owner, stage, body)
    assert repeated.model_dump(exclude={"replayed"}) == first.model_dump(exclude={"replayed"})
    assert repeated.replayed
    for patch in ({"request_id": str(uuid4())}, {"source_sha256": "0" * 64}, {"stage_version": 2}):
        with pytest.raises(ApiError):
            release(postgres_engine, owner, stage, body.model_copy(update=patch))
    with Session(postgres_engine) as session:
        assert (
            session.scalar(
                select(func.count())
                .select_from(ImportStageSourceRelease)
                .where(ImportStageSourceRelease.stage_id == UUID(stage.stage_id))
            )
            == 1
        )


def test_same_request_id_cannot_release_another_stage(postgres_engine):
    owner, stage, body = published(postgres_engine)
    _, other, second = published(postgres_engine, owner)
    release(postgres_engine, owner, stage, body)
    before = source_snapshot(postgres_engine, other)
    with pytest.raises(ApiError, match="import_stage_source_release_conflict"):
        release(
            postgres_engine, owner, other, second.model_copy(update={"request_id": body.request_id})
        )
    assert source_snapshot(postgres_engine, other) == before


def test_stage_cas_owner_current_permission_and_origin_are_rechecked(postgres_engine):
    owner, member = actor(postgres_engine), actor(postgres_engine)
    share(postgres_engine, owner, member)
    _, stage, body = published(postgres_engine, member, target=owner)
    before = source_snapshot(postgres_engine, stage)
    with pytest.raises(ApiError, match="import_stage_version_changed"):
        release(postgres_engine, member, stage, body.model_copy(update={"stage_version": 2}))
    with pytest.raises(ApiError):
        release(
            postgres_engine,
            owner,
            stage,
            body.model_copy(update={"client_id": str(owner.principal.client_id)}),
        )
    renewed = actor(postgres_engine, member.principal.user_id)
    with pytest.raises(ApiError, match="import_stage_reauthorization_required"):
        release(
            postgres_engine,
            renewed,
            stage,
            body.model_copy(update={"client_id": str(renewed.principal.client_id)}),
        )
    revoke(postgres_engine, owner, member)
    with pytest.raises(ApiError, match="scope_forbidden"):
        release(postgres_engine, member, stage, body)
    assert source_snapshot(postgres_engine, stage) == before


def test_budget_cancellation_after_both_deletes_rolls_back_source_audit_marker_and_quota(
    postgres_engine,
):
    owner, stage, body = published(postgres_engine)
    before = source_snapshot(postgres_engine, stage)
    with Session(postgres_engine) as session:
        observed = []

        def cancel_after_delete():
            pieces = session.scalar(
                select(func.count())
                .select_from(ImportStageUploadChunk)
                .where(ImportStageUploadChunk.stage_id == UUID(stage.stage_id))
            )
            rows = session.scalar(
                select(func.count())
                .select_from(ImportStageRow)
                .where(ImportStageRow.stage_id == UUID(stage.stage_id))
            )
            if not pieces and not rows:
                with Session(postgres_engine) as observer:
                    assert (
                        observer.scalar(
                            select(func.count())
                            .select_from(ImportStageUploadChunk)
                            .where(ImportStageUploadChunk.stage_id == UUID(stage.stage_id))
                        )
                        == before[2]
                    )
                observed.append(True)
                raise ApiError("source_release_cancelled", 503)

        with pytest.raises(ApiError, match="source_release_cancelled"):
            release_stage_source(
                session,
                owner.principal,
                UUID(stage.stage_id),
                body,
                check_budget=cancel_after_delete,
            )
        assert observed
    assert source_snapshot(postgres_engine, stage) == before
    with Session(postgres_engine) as session:
        assert session.get(ImportStageSourceRelease, UUID(stage.stage_id)) is None


def test_real_reservation_and_retained_count_return_only_after_source_release(postgres_engine):
    owner, stage, body = published(postgres_engine)
    candidate = StageCreate(
        client_id=str(owner.principal.client_id),
        sync_epoch=body.sync_epoch,
        format="flowtrace_json",
        expected_bytes=1,
        source_sha256="a" * 64,
    )
    limits = StagePolicy(
        max_retained_stages=1, max_reserved_bytes=source_snapshot(postgres_engine, stage)[1]
    )
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_quota_exceeded"),
    ):
        create_stage(session, owner.principal, candidate, policy=limits)
    release(postgres_engine, owner, stage, body)
    with Session(postgres_engine) as session:
        created = create_stage(session, owner.principal, candidate, policy=limits)
        assert created.stage_id != stage.stage_id


def test_released_source_supports_new_session_reauth_then_formal_undo(postgres_engine):
    owner, stage, body = published(postgres_engine)
    release(postgres_engine, owner, stage, body)
    renewed = actor(postgres_engine, owner.principal.user_id)
    with Session(postgres_engine) as session:
        current = reauthorize_published_stage(
            session,
            renewed.principal,
            UUID(stage.stage_id),
            StageReauthorize(
                stage_version=1,
                client_id=str(renewed.principal.client_id),
                sync_epoch=body.sync_epoch,
            ),
            check_budget=lambda: None,
        )
        assert current.source_released and current.stage_version == 2
    with pytest.raises(ApiError):
        release(postgres_engine, renewed, stage, body)
    with pytest.raises(ApiError, match="import_stage_source_release_conflict"):
        release(
            postgres_engine,
            renewed,
            stage,
            body.model_copy(
                update={"stage_version": 2, "client_id": str(renewed.principal.client_id)}
            ),
        )
    _, lease = queued_undo(postgres_engine, renewed, stage, version=2)
    assert undo(postgres_engine, lease)["created_count"] == 4


def test_undone_owner_can_release_source_without_resurrecting_deleted_book_rights(postgres_engine):
    owner, stage, body = published(postgres_engine)
    _, lease = queued_undo(postgres_engine, owner, stage)
    undo(postgres_engine, lease)
    receipt = release(postgres_engine, owner, stage, body)
    assert receipt.deleted_preview_rows == 4
    with Session(postgres_engine) as session:
        assert session.get(ImportStage, UUID(stage.stage_id)).status == "undone"


def test_two_real_connections_same_release_have_one_audit_and_one_replay(postgres_engine):
    owner, stage, body = published(postgres_engine)
    start = Barrier(2)

    def invoke():
        start.wait(timeout=5)
        return release(postgres_engine, owner, stage, body).replayed

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: invoke(), range(2)))
    assert sorted(results) == [False, True]


def test_final_cancellation_after_marker_and_audit_flush_restores_every_source_byte(
    postgres_engine,
):
    owner, stage, body = published(postgres_engine)
    before = source_snapshot(postgres_engine, stage)
    with Session(postgres_engine) as session:
        observed = []

        def cancel_after_marker():
            row = session.get(ImportStage, UUID(stage.stage_id))
            if row is not None and row.source_released_at is not None:
                assert session.get(ImportStageSourceRelease, row.id) is not None
                observed.append(True)
                raise ApiError("cancelled_after_marker", 503)

        with pytest.raises(ApiError, match="cancelled_after_marker"):
            release_stage_source(
                session,
                owner.principal,
                UUID(stage.stage_id),
                body,
                check_budget=cancel_after_marker,
            )
        assert observed
    assert source_snapshot(postgres_engine, stage) == before
    with Session(postgres_engine) as session:
        assert session.get(ImportStageSourceRelease, UUID(stage.stage_id)) is None


def test_actual_new_session_same_client_cannot_replay_original_body_without_reauthorization(
    postgres_engine,
):
    owner, stage, body = published(postgres_engine)
    first = release(postgres_engine, owner, stage, body)
    with Session(postgres_engine) as session, session.begin():
        record, _ = issue_session(
            session,
            session.get(User, owner.principal.user_id),
            owner.principal.client_id,
            "合成源释放重放",
            "api_native",
        )
        principal = Principal(
            record.user_id, record.id, record.client_id, record.purpose, frozenset()
        )
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_reauthorization_required"),
    ):
        release_stage_source(
            session, principal, UUID(stage.stage_id), body, check_budget=lambda: None
        )
    with Session(postgres_engine) as session:
        assert session.get(ImportStageSourceRelease, UUID(stage.stage_id)).request_id == UUID(
            first.request_id
        )


@pytest.mark.parametrize("change", ["session_revoked", "wrong_epoch"])
def test_real_session_and_epoch_are_required_before_source_release(postgres_engine, change):
    owner, stage, body = published(postgres_engine)
    before = source_snapshot(postgres_engine, stage)
    if change == "session_revoked":
        with Session(postgres_engine) as session, session.begin():
            session.get(UserSession, owner.principal.session_id).revoked_at = session.scalar(
                select(func.clock_timestamp())
            )
    else:
        body = body.model_copy(update={"sync_epoch": str(uuid4())})
    with pytest.raises(ApiError) as caught:
        release(postgres_engine, owner, stage, body)
    assert caught.value.code in {"session_invalid", "epoch_changed"}
    assert source_snapshot(postgres_engine, stage) == before


def test_source_release_audit_capacity_check_is_enforced_by_postgresql(postgres_engine):
    owner, stage, body = published(postgres_engine)
    _, other, _ = published(postgres_engine, owner)
    release(postgres_engine, owner, stage, body)
    table = ImportStageSourceRelease.__table__
    with Session(postgres_engine) as session:
        values = dict(
            session.execute(select(table).where(table.c.stage_id == UUID(stage.stage_id)))
            .mappings()
            .one()
        )
        values.update(
            stage_id=UUID(other.stage_id),
            batch_id=UUID(other.batch_id),
            request_id=uuid4(),
            deleted_source_bytes=values["received_bytes_snapshot"] + 1,
        )
        with pytest.raises(DBAPIError) as caught, session.begin_nested():
            session.execute(insert(table).values(**values))
        assert caught.value.orig.sqlstate == "23514"
        assert session.scalar(text("SELECT 1")) == 1


@pytest.mark.parametrize("action", ["update", "delete"])
def test_source_release_orm_guard_is_append_only(postgres_engine, action):
    owner, stage, body = published(postgres_engine)
    release(postgres_engine, owner, stage, body)
    with Session(postgres_engine) as session:
        with (
            pytest.raises(ValueError, match="import_stage_source_release_immutable"),
            session.begin_nested(),
        ):
            audit = session.get(ImportStageSourceRelease, UUID(stage.stage_id))
            if action == "update":
                audit.request_hash = "0" * 64
            else:
                session.delete(audit)
            session.flush()
        assert session.scalar(text("SELECT 1")) == 1


@pytest.mark.parametrize(
    "action", ["update", "delete", "truncate", "marker_clear", "marker_change"]
)
def test_actual_audit_and_marker_guards_reject_raw_sql(postgres_engine, action):
    owner, stage, body = published(postgres_engine)
    release(postgres_engine, owner, stage, body)
    with Session(postgres_engine) as session:
        if action == "truncate":
            # Explicit metadata FK closure passes TRUNCATE's pre-trigger safety
            # check without CASCADE. Audit is first and its guard fires 55000.
            names = {"import_stage_source_releases"}
            while True:
                added = {
                    table.name
                    for table in Base.metadata.tables.values()
                    if any(key.column.table.name in names for key in table.foreign_keys)
                }
                if added <= names:
                    break
                names |= added
            statement = text(
                "TRUNCATE "
                + ", ".join(
                    ["import_stage_source_releases"]
                    + sorted(names - {"import_stage_source_releases"})
                )
            )
        else:
            statement = text(
                {
                    "update": (
                        "UPDATE import_stage_source_releases "
                        "SET request_hash=request_hash WHERE stage_id=:id"
                    ),
                    "delete": "DELETE FROM import_stage_source_releases WHERE stage_id=:id",
                    "marker_clear": "UPDATE import_stages SET source_released_at=NULL WHERE id=:id",
                    "marker_change": (
                        "UPDATE import_stages SET source_released_at="
                        "source_released_at+interval '1 second' WHERE id=:id"
                    ),
                }[action]
            )
        with pytest.raises(DBAPIError) as caught, session.begin_nested():
            session.execute(statement, {"id": UUID(stage.stage_id)})
        assert caught.value.orig.sqlstate == "55000"
        assert session.scalar(text("SELECT 1")) == 1


def test_unaudited_marker_fk_and_published_state_check_are_real(postgres_engine):
    owner, stage, body = published(postgres_engine)
    _, other, _ = published(postgres_engine, owner)
    receipt = release(postgres_engine, owner, stage, body)
    with Session(postgres_engine) as session:
        for sql, params, code in (
            (
                "UPDATE import_stages SET source_released_at=:stamp, "
                "requirements_version=NULL, requirements_hash=NULL, requirements_count=0 "
                "WHERE id=:id",
                {"stamp": receipt.source_released_at, "id": UUID(other.stage_id)},
                "23503",
            ),
            (
                "UPDATE import_stages SET status='uploading' WHERE id=:id",
                {"id": UUID(stage.stage_id)},
                "23514",
            ),
        ):
            with pytest.raises(DBAPIError) as caught, session.begin_nested():
                session.execute(text(sql), params)
            assert caught.value.orig.sqlstate == code
            assert session.scalar(text("SELECT 1")) == 1


def test_test_only_http_release_receipt_status_rows410_and_real_worker_undo(
    stage_http, postgres_engine
):
    owner = actor(postgres_engine)
    stage, current = http_ready(stage_http, postgres_engine, owner)
    queued = post(
        stage_http,
        owner,
        stage,
        "apply",
        {
            "stage_version": 1,
            "batch_id": stage["batch_id"],
            "preview_hash": current["preview_hash"],
        },
    )
    run(stage_http, postgres_engine, queued.json()["job_id"])
    with Session(postgres_engine) as session:
        row = session.get(ImportStage, UUID(stage["stage_id"]))
        body = StageSourceReleaseRequest(
            stage_version=1,
            request_id=str(uuid4()),
            batch_id=stage["batch_id"],
            client_id=str(owner.principal.client_id),
            sync_epoch=epoch(postgres_engine),
            source_sha256=row.source_sha256,
        )
    response = post(stage_http, owner, stage, "source-release", body.model_dump())
    assert response.status_code == 200, response.text
    assert not response.json()["replayed"] and response.json()["deleted_preview_rows"] == 61
    assert post(stage_http, owner, stage, "source-release", body.model_dump()).json()["replayed"]
    assert status(stage_http, owner, stage)["source_released"]
    rows = stage_http.get(
        f"/api/v1/data-tools/import-stages/{stage['stage_id']}/rows",
        headers=headers(owner),
        params={"stage_version": 1},
    )
    assert (
        rows.status_code == 410 and rows.json()["error"]["code"] == "import_stage_source_released"
    )
    queued = post(
        stage_http, owner, stage, "undo", {"stage_version": 1, "batch_id": stage["batch_id"]}
    )
    run(stage_http, postgres_engine, queued.json()["job_id"])
    assert status(stage_http, owner, stage)["status"] == "undone"
