"""Real fenced parse completion, with zero ordinary business publication."""

from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from sync.helpers import actor, epoch

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.imports.models import ImportBatch
from flowtrace_server.imports.parsers import ImportFormatError, canonical, parse_json
from flowtrace_server.imports.staging import create_stage
from flowtrace_server.imports.staging_models import (
    ImportStage,
    ImportStageRow,
    ImportStageUploadChunk,
)
from flowtrace_server.imports.staging_parse import parse_stage_in_transaction
from flowtrace_server.imports.staging_rows import stage_rows
from flowtrace_server.imports.staging_schemas import STAGE_CHUNK_BYTES, StageCreate
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.jobs.store import LeaseLost, claim, complete
from flowtrace_server.sync.models import SyncEntity

from .test_staging_parsers import native_row, source_file
from .test_staging_upload import sealed, sha, upload

pytestmark = pytest.mark.postgres


def prepared(engine, owner, content, format_name="flowtrace_json", mapping=None):
    with Session(engine) as session:
        stage = create_stage(
            session,
            owner.principal,
            StageCreate(
                client_id=str(owner.principal.client_id),
                sync_epoch=epoch(engine),
                format=format_name,
                expected_bytes=len(content),
                source_sha256=sha(content),
                mapping=mapping or {},
            ),
        )
    for index, offset in enumerate(range(0, len(content), STAGE_CHUNK_BYTES)):
        upload(engine, owner, stage, index, content[offset : offset + STAGE_CHUNK_BYTES])
    job = sealed(engine, owner, stage, content)
    with Session(engine) as session:
        earliest = session.scalar(select(func.min(BackgroundJob.available_at)))
        session.get(BackgroundJob, UUID(job.job_id)).available_at = earliest - timedelta(seconds=1)
        session.commit()
    with Session(engine) as session:
        lease = claim(session, uuid4(), ["import_preview"])
        session.commit()
    assert str(lease.job_id) == job.job_id
    return stage, lease


def complete_parse(engine, lease, budget=lambda: None):
    with Session(engine) as session:
        result = complete(
            session,
            lease,
            lambda current, job: parse_stage_in_transaction(current, job.id, check_budget=budget),
        )
        session.commit()
        return result


def row_count(session, stage):
    return session.scalar(
        select(func.count())
        .select_from(ImportStageRow)
        .where(ImportStageRow.stage_id == UUID(stage.stage_id))
    )


def test_large_parse_is_durable_private_and_complete_is_the_only_commit(postgres_engine):
    owner = actor(postgres_engine)
    rows = [native_row() for _ in range(601)]
    stage, lease = prepared(postgres_engine, owner, source_file("flowtrace_json", rows))
    samples = 0

    def budget():
        nonlocal samples
        samples += 1
        if samples == 560:
            with Session(postgres_engine) as observer:
                assert row_count(observer, stage) == 0
                assert observer.get(ImportStage, UUID(stage.stage_id)).status == "uploaded"

    result = complete_parse(postgres_engine, lease, budget)
    assert result == {"code": "import_stage_parsed", "created_count": 601} and samples > 601
    with Session(postgres_engine) as session:
        record = session.get(ImportStage, UUID(stage.stage_id))
        assert (record.status, record.row_count, record.error_count, record.preview_hash) == (
            "parsed",
            601,
            0,
            None,
        )
        parsed = list(
            session.scalars(
                select(ImportStageRow)
                .where(ImportStageRow.stage_id == record.id)
                .order_by(ImportStageRow.position)
            )
        )
        assert [item.row_payload for item in parsed] == rows
        assert all(
            item.parsed_version == 1
            and item.preview_version is None
            and item.preview_status is None
            for item in parsed
        )
        assert session.get(BackgroundJob, lease.job_id).result == result
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


def test_row_errors_are_durable_but_never_ready(postgres_engine):
    owner = actor(postgres_engine)
    first, invalid = native_row(), native_row()
    invalid["payload"]["unexpected"] = "secret financial original"
    stage, lease = prepared(
        postgres_engine, owner, source_file("flowtrace_json", [first, invalid, first, native_row()])
    )
    assert complete_parse(postgres_engine, lease) == {
        "code": "import_stage_parsed_with_errors",
        "created_count": 4,
    }
    with Session(postgres_engine) as session:
        record = session.get(ImportStage, UUID(stage.stage_id))
        assert (record.status, record.row_count, record.error_count) == ("parsed", 4, 2)
        errors = session.get(ImportStageRow, (record.id, 2)).errors
        assert "secret financial" not in str(errors)
        assert session.get(ImportStageRow, (record.id, 3)).source_id is None


def test_file_failure_after_insert_batch_removes_all_rows_and_keeps_source(postgres_engine):
    owner = actor(postgres_engine)
    content = source_file("flowtrace_csv", [native_row() for _ in range(510)]) + b'"unterminated'
    stage, lease = prepared(postgres_engine, owner, content, "flowtrace_csv")
    assert complete_parse(postgres_engine, lease) == {"code": "invalid_csv", "created_count": 0}
    with Session(postgres_engine) as session:
        record = session.get(ImportStage, UUID(stage.stage_id))
        assert (record.status, record.row_count, record.error_count) == ("failed", 0, 1)
        assert row_count(session, stage) == 0
        assert (
            b"".join(
                session.scalars(
                    select(ImportStageUploadChunk.content)
                    .where(ImportStageUploadChunk.stage_id == record.id)
                    .order_by(ImportStageUploadChunk.chunk_index)
                )
            )
            == content
        )


def test_budget_failure_after_batch_rolls_back_and_same_job_can_retry(postgres_engine):
    owner = actor(postgres_engine)
    stage, lease = prepared(
        postgres_engine, owner, source_file("flowtrace_json", [native_row() for _ in range(601)])
    )
    calls = 0

    def budget():
        nonlocal calls
        calls += 1
        if calls == 560:
            raise TimeoutError("stage_execution_budget_exhausted")

    with pytest.raises(TimeoutError, match="stage_execution_budget_exhausted"):
        complete_parse(postgres_engine, lease, budget)
    with Session(postgres_engine) as session:
        assert session.get(ImportStage, UUID(stage.stage_id)).status == "uploaded"
        assert row_count(session, stage) == 0
        assert session.get(BackgroundJob, lease.job_id).status == "running"
    assert complete_parse(postgres_engine, lease)["created_count"] == 601


def test_source_integrity_failure_propagates_without_claiming_file_processed(postgres_engine):
    owner = actor(postgres_engine)
    stage, lease = prepared(postgres_engine, owner, source_file("flowtrace_json", [native_row()]))
    with Session(postgres_engine) as session:
        piece = session.get(ImportStageUploadChunk, (UUID(stage.stage_id), 0))
        piece.content = piece.content[:-1] + b"x"
        session.commit()
    with pytest.raises(ApiError, match="import_stage_source_changed"):
        complete_parse(postgres_engine, lease)
    with Session(postgres_engine) as session:
        assert session.get(ImportStage, UUID(stage.stage_id)).status == "uploaded"
        assert row_count(session, stage) == 0


def test_final_completion_lease_fence_rolls_back_parser_output(postgres_engine):
    owner = actor(postgres_engine)
    stage, lease = prepared(postgres_engine, owner, source_file("flowtrace_json", [native_row()]))
    with Session(postgres_engine) as session:

        def effect(current, job):
            result = parse_stage_in_transaction(current, job.id, check_budget=lambda: None)
            job.lease_until = current.scalar(select(func.clock_timestamp())) - timedelta(seconds=1)
            current.flush()
            return result

        with pytest.raises(LeaseLost, match="job_lease_lost"):
            complete(session, lease, effect)
        session.commit()  # Even a caller committing after a rejected effect publishes nothing.
    with Session(postgres_engine) as session:
        assert session.get(ImportStage, UUID(stage.stage_id)).status == "uploaded"
        assert row_count(session, stage) == 0
        assert session.get(BackgroundJob, lease.job_id).status == "running"


def test_parsed_rows_page_is_version_bound_and_owner_origin_private(postgres_engine):
    owner, foreign = actor(postgres_engine), actor(postgres_engine)
    stage, lease = prepared(
        postgres_engine, owner, source_file("flowtrace_json", [native_row() for _ in range(205)])
    )
    complete_parse(postgres_engine, lease)
    cursor, positions = None, []
    for expected, more in ((100, True), (100, True), (5, False)):
        with Session(postgres_engine) as session:
            page = stage_rows(
                session, owner.principal, UUID(stage.stage_id), stage_version=1, cursor=cursor
            )
        assert len(page.rows) == expected and page.has_more == more
        assert all(item.status == "parsed" and item.target_entity_id is None for item in page.rows)
        positions += [item.position for item in page.rows]
        cursor = page.next_cursor
    assert positions == list(range(1, 206)) and cursor is None
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_not_found"),
    ):
        stage_rows(session, foreign.principal, UUID(stage.stage_id), stage_version=1)
    renewed = actor(postgres_engine, existing_user=owner.principal.user_id)
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_reauthorization_required"),
    ):
        stage_rows(session, renewed.principal, UUID(stage.stage_id), stage_version=1)
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_version_changed"),
    ):
        stage_rows(session, owner.principal, UUID(stage.stage_id), stage_version=2)
    with (
        Session(postgres_engine) as session,
        pytest.raises(ApiError, match="import_stage_cursor_invalid"),
    ):
        stage_rows(
            session, owner.principal, UUID(stage.stage_id), stage_version=1, cursor="private-path"
        )


def test_over_5mib_source_and_large_json_pages_have_explicit_continuation(postgres_engine):
    owner = actor(postgres_engine)
    payload = {
        "bill_type": "refund",
        "money": {"currency": "CNY", "currency_scale": 2, "amount_minor": "100"},
        "business_date": "2026-10-20",
        "business_timezone": "Asia/Shanghai",
        "note": "中" * 2000,
        "tag_ids": [str(uuid4()) for _ in range(100)],
        "allocations": [
            {
                "source_bill_id": str(uuid4()),
                "source_amount_minor": "1",
                "receipt_amount_minor": "1",
            }
            for _ in range(100)
        ],
    }
    rows = [
        {
            "source_id": str(uuid4()),
            "entity_type": "bill",
            "scope_id": str(owner.book_id),
            "payload": payload,
        }
        for _ in range(275)
    ]
    content = source_file("flowtrace_json", rows)
    assert len(content) > 5 * 1024 * 1024
    with pytest.raises(ImportFormatError, match="file_too_large"):
        parse_json(content)
    stage, lease = prepared(postgres_engine, owner, content)
    assert stage.expected_chunks > 10
    assert complete_parse(postgres_engine, lease) == {
        "code": "import_stage_parsed",
        "created_count": 275,
    }
    positions, cursor, short_page = [], None, False
    for _ in range(20):
        with Session(postgres_engine) as session:
            page = stage_rows(
                session, owner.principal, UUID(stage.stage_id), stage_version=1, cursor=cursor
            )
        assert len(canonical(page.model_dump(mode="json"))) <= 1024 * 1024
        short_page |= page.has_more and len(page.rows) < 100
        positions.extend(item.position for item in page.rows)
        cursor = page.next_cursor
        if not page.has_more:
            break
    assert cursor is None and short_page and positions == list(range(1, 276))
