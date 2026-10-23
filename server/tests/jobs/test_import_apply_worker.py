"""Real four-stage worker publication; image evidence uses its own fresh DB."""

import hashlib
import os
from dataclasses import dataclass
from datetime import timedelta
from uuid import UUID

import pytest
from data_tools.test_import_attachments import new_book_request
from data_tools.test_staging_parsers import source_file
from data_tools.test_staging_preview import categories
from data_tools.test_staging_upload import sealed, start, upload
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from sync.helpers import actor, epoch, revoke, share

from flowtrace_server.attachments.models import Attachment, AttachmentHold
from flowtrace_server.config import Settings
from flowtrace_server.imports.models import ImportBatch
from flowtrace_server.imports.parsers import canonical
from flowtrace_server.imports.staging import create_stage
from flowtrace_server.imports.staging_models import ImportPublication, ImportStage
from flowtrace_server.imports.staging_preview import request_stage_preview
from flowtrace_server.imports.staging_publish import request_stage_apply, request_stage_undo
from flowtrace_server.imports.staging_schemas import (
    STAGE_CHUNK_BYTES,
    StageApply,
    StageCreate,
    StageUndo,
    StageVersionInput,
)
from flowtrace_server.jobs import store
from flowtrace_server.jobs.models import BackgroundJob, JobAttempt, WorkerState
from flowtrace_server.sync.models import SyncEntity
from flowtrace_server.worker import runtime

pytestmark = pytest.mark.postgres


@dataclass
class StageWorker:
    owner: object
    stage_id: UUID
    worker: runtime.Worker


@pytest.fixture
def stage_workers(postgres_engine, tmp_path):
    cases = []

    def create(owner=None, *, target=None, content=None, mapping=None):
        owner = owner or actor(postgres_engine)
        content = content or source_file("flowtrace_json", categories(target or owner, 61))
        if mapping is None:
            stage = start(postgres_engine, owner, content)
        else:
            with Session(postgres_engine) as session:
                stage = create_stage(
                    session,
                    owner.principal,
                    StageCreate(
                        client_id=str(owner.principal.client_id),
                        sync_epoch=epoch(postgres_engine),
                        format="flowtrace_json",
                        expected_bytes=len(content),
                        source_sha256=hashlib.sha256(content).hexdigest(),
                        mapping=mapping,
                    ),
                )
        for index, offset in enumerate(range(0, len(content), STAGE_CHUNK_BYTES)):
            upload(
                postgres_engine, owner, stage, index, content[offset : offset + STAGE_CHUNK_BYTES]
            )
        sealed(postgres_engine, owner, stage, content)
        stage_id = UUID(stage.stage_id)
        instance = runtime.Worker(
            postgres_engine,
            Settings(
                _env_file=None,
                environment="test",
                database_url=os.environ["FLOWTRACE_TEST_DATABASE_URL"],
                data_directory=tmp_path,
            ),
        )
        assert "import_apply" in instance.supported_kinds
        case = StageWorker(owner, stage_id, instance)
        cases.append(case)
        return case

    yield create
    try:
        with Session(postgres_engine) as session, session.begin():
            for case in cases:
                for job in session.scalars(
                    select(BackgroundJob).where(
                        BackgroundJob.owner_user_id == case.owner.principal.user_id,
                        BackgroundJob.kind.in_(["import_preview", "import_apply"]),
                        BackgroundJob.status.in_(["pending", "running", "retry_wait"]),
                    )
                ):
                    store.cancel(session, job.id)
    finally:
        for case in cases:
            case.worker.close()


def first(engine, job_id):
    with Session(engine) as session, session.begin():
        earliest = session.scalar(select(func.min(BackgroundJob.available_at)))
        session.get(BackgroundJob, job_id).available_at = earliest - timedelta(seconds=1)


def step(engine, case, field):
    with Session(engine) as session:
        job_id = getattr(session.get(ImportStage, case.stage_id), field)
    first(engine, job_id)
    assert case.worker.run_once()
    return job_id


def preview(engine, case, *, parsed=False):
    if not parsed:
        step(engine, case, "parse_job_id")
    with Session(engine) as session:
        queued = request_stage_preview(
            session, case.owner.principal, case.stage_id, StageVersionInput(stage_version=1)
        )
    step(engine, case, "preview_job_id")
    return queued


def queue_apply(engine, case):
    with Session(engine) as session:
        stage = session.get(ImportStage, case.stage_id)
        body = StageApply(
            stage_version=1, batch_id=str(stage.batch_id), preview_hash=stage.preview_hash
        )
        return body, request_stage_apply(session, case.owner.principal, stage.id, body)


def test_real_worker_four_stages_replay_and_published_ttl_undo(postgres_engine, stage_workers):
    case = stage_workers()
    preview(postgres_engine, case)
    body, queued = queue_apply(postgres_engine, case)
    with Session(postgres_engine) as session:
        assert (
            request_stage_apply(session, case.owner.principal, case.stage_id, body).job_id
            == queued.job_id
        )
    apply_job = step(postgres_engine, case, "apply_job_id")
    with Session(postgres_engine) as session:
        stage = session.get(ImportStage, case.stage_id)
        job = session.get(BackgroundJob, apply_job)
        assert stage.status == "applied" and job.status == "succeeded"
        assert job.result == {"code": "import_stage_applied", "created_count": 61}
        assert session.get(ImportPublication, stage.id).event_count == 61
        assert session.get(JobAttempt, (job.id, 1)).status == "succeeded"
        assert session.get(WorkerState, case.worker.id).supported_kinds == [
            "backup_quarantine",
            "backup_verify",
            "import_apply",
            "import_preview",
        ]
        assert (
            request_stage_apply(session, case.owner.principal, stage.id, body).job_id
            == queued.job_id
        )
        stage.created_at -= timedelta(days=10)
        stage.expires_at = store.stamp(session) - timedelta(seconds=1)
        session.commit()
        undo = StageUndo(stage_version=1, batch_id=str(stage.batch_id))
        queued_undo = request_stage_undo(session, case.owner.principal, stage.id, undo)
        assert (
            request_stage_undo(session, case.owner.principal, stage.id, undo).job_id
            == queued_undo.job_id
        )
    undo_job = step(postgres_engine, case, "undo_job_id")
    with Session(postgres_engine) as session:
        assert session.get(ImportStage, case.stage_id).status == "undone"
        assert session.get(BackgroundJob, undo_job).result == {
            "code": "import_stage_undone",
            "created_count": 61,
        }
        assert session.get(BackgroundJob, apply_job).attempt == 1
        assert (
            session.scalar(
                select(func.count())
                .select_from(SyncEntity)
                .where(SyncEntity.scope_id == case.owner.book_id, SyncEntity.deleted.is_(False))
            )
            == 1
        )
    assert not case.worker.run_once()


def test_real_worker_current_revocation_rejects_queued_financial_effect(
    postgres_engine, stage_workers
):
    owner, member = actor(postgres_engine), actor(postgres_engine)
    share(postgres_engine, owner, member)
    case = stage_workers(member, target=owner)
    preview(postgres_engine, case)
    _, queued = queue_apply(postgres_engine, case)
    revoke(postgres_engine, owner, member)
    job_id = step(postgres_engine, case, "apply_job_id")
    assert str(job_id) == queued.job_id
    with Session(postgres_engine) as session:
        job = session.get(BackgroundJob, job_id)
        assert job.status == "failed" and job.result is None
        assert job.error_code in {"scope_forbidden", "import_stage_preview_changed"}
        stage = session.get(ImportStage, case.stage_id)
        assert stage.status == "ready" and session.get(ImportBatch, stage.batch_id) is None
        assert session.get(ImportPublication, case.stage_id) is None


def test_real_worker_lost_apply_completion_rolls_back_metadata_then_new_generation_retries(
    postgres_engine, stage_workers, monkeypatch
):
    case = stage_workers()
    preview(postgres_engine, case)
    queue_apply(postgres_engine, case)
    actual = runtime.apply_stage_in_transaction

    def late(session, job_id, **kwargs):
        result = actual(session, job_id, **kwargs)
        assert session.get(ImportPublication, case.stage_id) is not None
        session.get(BackgroundJob, job_id).lease_until = store.stamp(session) - timedelta(seconds=1)
        session.flush()
        return result

    monkeypatch.setattr(runtime, "apply_stage_in_transaction", late)
    job_id = step(postgres_engine, case, "apply_job_id")
    with Session(postgres_engine) as session:
        stage = session.get(ImportStage, case.stage_id)
        assert stage.status == "ready" and session.get(ImportBatch, stage.batch_id) is None
        assert session.get(ImportPublication, stage.id) is None
        assert session.get(BackgroundJob, job_id).status == "running"
        session.get(BackgroundJob, job_id).lease_until = store.stamp(session) - timedelta(seconds=1)
        session.commit()
    monkeypatch.setattr(runtime, "apply_stage_in_transaction", actual)
    step(postgres_engine, case, "apply_job_id")
    with Session(postgres_engine) as session:
        assert session.get(ImportStage, case.stage_id).status == "applied"
        assert session.get(BackgroundJob, job_id).attempt == 2
        assert session.get(JobAttempt, (job_id, 1)).status == "lease_expired"
        assert session.get(JobAttempt, (job_id, 2)).status == "succeeded"
        assert (
            session.scalar(
                select(func.count())
                .select_from(ImportPublication)
                .where(ImportPublication.stage_id == case.stage_id)
            )
            == 1
        )


def test_real_worker_image_hold_case_in_separate_fixture_database(
    postgres_engine, stage_workers, tmp_path
):
    if os.environ.get("FLOWTRACE_STAGE_WORKER_IMAGE_DATABASE_URL") != os.environ.get(
        "FLOWTRACE_TEST_DATABASE_URL"
    ):
        pytest.skip("explicit separate image worker database not configured")
    from data_tools.test_import_attachments import ready_image

    owner = actor(postgres_engine)
    uploaded, _, original, storage = ready_image(postgres_engine, owner, tmp_path / "attachments")
    body, _, _ = new_book_request(postgres_engine, owner, uploaded)
    source = next(iter(body.resource_mapping))
    content = canonical(
        {
            "format": "flowtrace-export-v1",
            "document": body.document.model_dump(mode="json"),
            "attachments": [
                {
                    "attachment_id": source,
                    "sha256": hashlib.sha256(original).hexdigest(),
                    "size_bytes": len(original),
                    "media_type": "image/png",
                }
            ],
        }
    )
    case = stage_workers(
        owner,
        content=content,
        mapping={
            "resource_mapping": body.resource_mapping,
            "attachment_transfers": body.attachment_transfers,
        },
    )
    preview(postgres_engine, case)
    with Session(postgres_engine) as session:
        assert (
            session.scalar(
                select(func.count())
                .select_from(AttachmentHold)
                .where(AttachmentHold.attachment_id == uploaded)
            )
            == 1
        )
        assert session.get(Attachment, uploaded).scope_id == owner.principal.user_id
    queue_apply(postgres_engine, case)
    step(postgres_engine, case, "apply_job_id")
    with Session(postgres_engine) as session:
        image = session.get(Attachment, uploaded)
        assert image.scope_id != owner.principal.user_id
        assert storage.content(image.storage_key) == original
        assert not session.scalar(
            select(func.count())
            .select_from(AttachmentHold)
            .where(AttachmentHold.attachment_id == uploaded)
        )
        request_stage_undo(
            session,
            owner.principal,
            case.stage_id,
            StageUndo(
                stage_version=1, batch_id=str(session.get(ImportStage, case.stage_id).batch_id)
            ),
        )
    step(postgres_engine, case, "undo_job_id")
    with Session(postgres_engine) as session:
        image = session.get(Attachment, uploaded)
        assert (
            image.scope_id == owner.principal.user_id
            and storage.content(image.storage_key) == original
        )
