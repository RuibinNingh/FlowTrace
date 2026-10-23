"""Real worker parse and domain preview, with no financial publication."""

from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from data_tools.test_staging_parsers import native_row, source_file
from data_tools.test_staging_upload import sealed, start, upload
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from sync.helpers import actor

from flowtrace_server.auth.models import UserSession
from flowtrace_server.auth.service import now
from flowtrace_server.config import Settings
from flowtrace_server.imports.models import ImportBatch
from flowtrace_server.imports.staging_models import ImportStage, ImportStageRow
from flowtrace_server.imports.staging_preview import request_stage_preview
from flowtrace_server.imports.staging_schemas import STAGE_CHUNK_BYTES, StageVersionInput
from flowtrace_server.jobs import store
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.worker import runtime

pytestmark = pytest.mark.postgres


@pytest.fixture
def staged_worker(postgres_engine, tmp_path):
    created = []

    def create(content=None):
        result = prepare(postgres_engine, tmp_path, content)
        created.append(result)
        return result

    yield create
    # Only cancel this test's unfinished intents; keep private stage/source
    # records as evidence and never touch another fixture or financial data.
    with Session(postgres_engine) as session, session.begin():
        for owner, _, _, instance in created:
            jobs = list(
                session.scalars(
                    select(BackgroundJob).where(
                        BackgroundJob.owner_user_id == owner.principal.user_id,
                        BackgroundJob.kind == "import_preview",
                        BackgroundJob.status.in_(["pending", "running", "retry_wait"]),
                    )
                )
            )
            for job in jobs:
                store.cancel(session, job.id)
            instance.close()


def prepare(engine, tmp_path, content=None):
    owner = actor(engine)
    rows = [native_row() for _ in range(61)]
    for row in rows:
        row["scope_id"] = str(owner.book_id)
    content = content or source_file("flowtrace_json", rows)
    stage = start(engine, owner, content)
    for index, offset in enumerate(range(0, len(content), STAGE_CHUNK_BYTES)):
        upload(engine, owner, stage, index, content[offset : offset + STAGE_CHUNK_BYTES])
    queued = sealed(engine, owner, stage, content)
    job_id = UUID(queued.job_id)
    with Session(engine) as session, session.begin():
        earliest = session.scalar(select(func.min(BackgroundJob.available_at)))
        session.get(BackgroundJob, job_id).available_at = earliest - timedelta(seconds=1)
    settings = Settings(_env_file=None, environment="test", data_directory=tmp_path)
    instance = runtime.Worker(engine, settings, worker_id=uuid4())
    assert "import_preview" in instance.supported_kinds
    return owner, UUID(stage.stage_id), job_id, instance


def read(engine, stage_id, job_id):
    with Session(engine) as session:
        stage = session.get(ImportStage, stage_id)
        job = session.get(BackgroundJob, job_id)
        count = session.scalar(
            select(func.count())
            .select_from(ImportStageRow)
            .where(ImportStageRow.stage_id == stage_id)
        )
        return stage.status, count, job.status, job.result, job.error_code


def test_real_parse_keeps_financial_data_unpublished_without_admin_role(
    postgres_engine, staged_worker
):
    owner, stage_id, job_id, instance = staged_worker()
    assert instance.run_once()
    assert read(postgres_engine, stage_id, job_id) == (
        "parsed",
        61,
        "succeeded",
        {"code": "import_stage_parsed", "created_count": 61},
        None,
    )
    with Session(postgres_engine) as session:
        assert not session.scalar(
            select(func.count())
            .select_from(ImportBatch)
            .where(ImportBatch.user_id == owner.principal.user_id)
        )


def test_real_worker_preview_becomes_ready_without_creating_financial_batch(
    postgres_engine, staged_worker
):
    owner, stage_id, _, instance = staged_worker()
    assert instance.run_once()
    with Session(postgres_engine) as session:
        first = request_stage_preview(
            session, owner.principal, stage_id, StageVersionInput(stage_version=1)
        )
        replay = request_stage_preview(
            session, owner.principal, stage_id, StageVersionInput(stage_version=1)
        )
    assert first.job_id == replay.job_id
    job_id = UUID(first.job_id)
    with Session(postgres_engine) as session, session.begin():
        earliest = session.scalar(select(func.min(BackgroundJob.available_at)))
        session.get(BackgroundJob, job_id).available_at = earliest - timedelta(seconds=1)
    assert instance.run_once()
    assert read(postgres_engine, stage_id, job_id) == (
        "ready",
        61,
        "succeeded",
        {"code": "import_stage_ready", "created_count": 61},
        None,
    )
    with Session(postgres_engine) as session:
        assert not session.scalar(
            select(func.count())
            .select_from(ImportBatch)
            .where(ImportBatch.user_id == owner.principal.user_id)
        )


def test_origin_deadline_five_second_reserve_prevents_parser_entry(
    postgres_engine, staged_worker, monkeypatch
):
    owner, stage_id, job_id, instance = staged_worker()
    with Session(postgres_engine) as session, session.begin():
        session.get(UserSession, owner.principal.session_id).access_expires_at = now() + timedelta(
            seconds=3
        )
    calls = []
    actual = runtime.parse_stage_in_transaction

    def bounded(*args, **kwargs):
        kwargs["check_budget"]()
        calls.append(True)
        return actual(*args, **kwargs)

    monkeypatch.setattr(runtime, "parse_stage_in_transaction", bounded)
    assert instance.run_once()
    assert not calls
    assert read(postgres_engine, stage_id, job_id) == (
        "uploaded",
        0,
        "retry_wait",
        None,
        "import_execution_timeout",
    )


def test_expired_real_origin_is_permanent_and_retains_source(postgres_engine, staged_worker):
    owner, stage_id, job_id, instance = staged_worker()
    with Session(postgres_engine) as session, session.begin():
        session.get(UserSession, owner.principal.session_id).revoked_at = now()
    assert instance.run_once()
    assert read(postgres_engine, stage_id, job_id) == (
        "uploaded",
        0,
        "failed",
        None,
        "session_invalid",
    )


def test_lost_completion_rolls_back_parsed_rows_and_new_generation_can_retry(
    postgres_engine, staged_worker, monkeypatch
):
    _, stage_id, job_id, instance = staged_worker()
    actual = runtime.parse_stage_in_transaction

    def late(session, actual_job_id, **kwargs):
        result = actual(session, actual_job_id, **kwargs)
        session.get(BackgroundJob, actual_job_id).lease_until = store.stamp(session) - timedelta(
            seconds=1
        )
        session.flush()
        return result

    monkeypatch.setattr(runtime, "parse_stage_in_transaction", late)
    assert instance.run_once()
    assert read(postgres_engine, stage_id, job_id) == ("uploaded", 0, "running", None, None)
    with Session(postgres_engine) as session, session.begin():
        session.get(BackgroundJob, job_id).lease_until = store.stamp(session) - timedelta(seconds=1)
    monkeypatch.setattr(runtime, "parse_stage_in_transaction", actual)
    assert instance.run_once()
    assert read(postgres_engine, stage_id, job_id)[:3] == ("parsed", 61, "succeeded")


def test_bad_file_completes_processing_but_stage_is_failed_not_ready(
    postgres_engine, staged_worker
):
    _, stage_id, job_id, instance = staged_worker(b'{"unknown":true}')
    assert instance.run_once()
    status, count, job_status, result, error = read(postgres_engine, stage_id, job_id)
    assert (status, count, job_status, error) == ("failed", 0, "succeeded", None)
    assert result["created_count"] == 0 and set(result) == {"code", "created_count"}
