"""Read-only bound job facts distinguish queue failure from stage phase."""

import re
from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import event, func, select
from sqlalchemy.orm import Session
from sync.helpers import actor, epoch

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.imports.staging_jobs import stage_jobs
from flowtrace_server.imports.staging_models import ImportStage
from flowtrace_server.imports.staging_publish import request_stage_apply
from flowtrace_server.imports.staging_reauthorize import reauthorize_published_stage
from flowtrace_server.imports.staging_schemas import StageApply, StageReauthorize
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.jobs.store import _payload, fail

from .test_source_release import published, release
from .test_stage_reauthorization_metadata import table_fingerprints
from .test_staging_http import PREFIX, headers
from .test_staging_http import ready as http_ready
from .test_staging_http import stage_http as stage_http
from .test_staging_parse import complete_parse, prepared
from .test_staging_parsers import source_file
from .test_staging_preview import categories
from .test_staging_publish import claim_apply
from .test_staging_requirements import source_owner as source_owner

pytestmark = pytest.mark.postgres


def jobs(engine, owner, stage, version=1):
    with Session(engine) as session:
        return stage_jobs(session, owner.principal, UUID(stage.stage_id), stage_version=version)


def test_real_apply_failure_keeps_ready_phase_but_metadata_reports_failure_without_requeue(
    postgres_engine, source_owner, stage_http
):
    stage, status = http_ready(stage_http, postgres_engine, source_owner)
    with Session(postgres_engine) as session:
        queued = request_stage_apply(
            session,
            source_owner.principal,
            UUID(stage["stage_id"]),
            StageApply(
                stage_version=1, batch_id=stage["batch_id"], preview_hash=status["preview_hash"]
            ),
        )
    lease = claim_apply(postgres_engine, queued.job_id)
    with Session(postgres_engine) as session, session.begin():
        fail(session, lease, "import_stage_preview_changed", transient=False)
    before = table_fingerprints(postgres_engine)
    statements = []

    def no_dml(_, __, statement, ___, ____, _____):
        statements.append(statement)
        assert not re.match(
            r"\s*(INSERT|UPDATE|DELETE|TRUNCATE|ALTER|CREATE|DROP)\b", statement, re.I
        )

    event.listen(postgres_engine, "before_cursor_execute", no_dml)
    try:
        response = stage_http.get(
            PREFIX + f"/{stage['stage_id']}/jobs",
            params={"stage_version": 1},
            headers=headers(source_owner),
        )
    finally:
        event.remove(postgres_engine, "before_cursor_execute", no_dml)
    assert response.status_code == 200 and statements
    assert "no-store" in response.headers["cache-control"]
    assert table_fingerprints(postgres_engine) == before
    body = response.json()
    assert set(body) == {"stage_id", "stage_version", "jobs"}
    assert [item["action"] for item in body["jobs"]] == ["parse", "preview", "apply"]
    item = body["jobs"][-1]
    assert set(item) == {
        "action",
        "job_id",
        "stage_version",
        "status",
        "attempt",
        "error_code",
        "available_at",
        "lease_until",
    }
    assert item["status"] == "failed" and item["attempt"] == 1 and item["lease_until"] is None
    assert item["error_code"] == "import_stage_preview_changed" and item["job_id"] == queued.job_id
    with Session(postgres_engine) as session:
        assert session.get(ImportStage, UUID(stage["stage_id"])).status == "ready"
        replay = request_stage_apply(
            session,
            source_owner.principal,
            UUID(stage["stage_id"]),
            StageApply(
                stage_version=1, batch_id=stage["batch_id"], preview_hash=status["preview_hash"]
            ),
        )
        assert replay.job_id == queued.job_id
    with Session(postgres_engine) as session:
        assert session.get(BackgroundJob, lease.job_id).status == "failed"


def test_current_origin_only_ttl_and_released_source_do_not_hide_job_facts(
    postgres_engine, source_owner
):
    _, stage, release_body = published(postgres_engine, source_owner)
    release(postgres_engine, source_owner, stage, release_body)
    with Session(postgres_engine) as session, session.begin():
        row = session.get(ImportStage, UUID(stage.stage_id))
        row.created_at -= timedelta(days=10)
        row.expires_at = session.scalar(select(func.clock_timestamp())) - timedelta(seconds=1)
    previous = jobs(postgres_engine, source_owner, stage)
    assert len(previous.jobs) == 3 and all(item.status == "succeeded" for item in previous.jobs)
    renewed = actor(postgres_engine, source_owner.principal.user_id)
    with pytest.raises(ApiError, match="import_stage_reauthorization_required"):
        jobs(postgres_engine, renewed, stage)
    with Session(postgres_engine) as session:
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
    current = jobs(postgres_engine, renewed, stage, version=2)
    assert current.stage_version == 2 and all(item.stage_version == 1 for item in current.jobs)
    assert current.jobs == previous.jobs
    with pytest.raises(ApiError, match="import_stage_version_changed"):
        jobs(postgres_engine, renewed, stage)
    with pytest.raises(ApiError, match="import_stage_not_found"):
        jobs(postgres_engine, actor(postgres_engine), stage, version=2)


@pytest.mark.parametrize(
    "change", ["owner", "kind", "stage", "version", "source", "hash", "extra", "code"]
)
def test_job_binding_and_closed_safe_metadata_never_leak_or_guess_corrupted_facts(
    postgres_engine, source_owner, change
):
    stage, lease = prepared(
        postgres_engine, source_owner, source_file("flowtrace_json", categories(source_owner, 1))
    )
    complete_parse(postgres_engine, lease)
    foreign = actor(postgres_engine)
    with Session(postgres_engine) as session, session.begin():
        row = session.get(BackgroundJob, lease.job_id)
        payload = dict(row.payload)
        if change == "owner":
            row.owner_user_id = foreign.principal.user_id
        elif change == "kind":
            row.kind = "import_apply"
        elif change == "hash":
            row.payload_hash = "f" * 64
        elif change == "code":
            row.error_code = "raw financial/private/path"
        else:
            payload.update(
                {
                    "stage": {"stage_id": str(uuid4())},
                    "version": {"stage_version": 9},
                    "source": {"source_sha256": "f" * 64},
                    "extra": {"raw": "private financial contents"},
                }[change]
            )
            row.payload, row.payload_hash = _payload(payload)
    before = table_fingerprints(postgres_engine)
    with pytest.raises(ApiError, match="import_stage_jobs_changed"):
        jobs(postgres_engine, source_owner, stage)
    assert table_fingerprints(postgres_engine) == before


def test_no_jobs_is_legitimate_and_unknown_lookup_query_is_rejected(
    postgres_engine, source_owner, stage_http
):
    from .test_staging_upload import start

    stage = start(postgres_engine, source_owner, b"not yet parsed")
    value = jobs(postgres_engine, source_owner, stage)
    assert value.jobs == []
    path = PREFIX + f"/{stage.stage_id}/jobs?stage_version=1"
    for extra in ("&stage_version=1", "&job_id=" + str(uuid4()), "&all=true"):
        response = stage_http.get(path + extra, headers=headers(source_owner))
        assert response.status_code == 422
    response = stage_http.get(path)
    assert response.status_code == 401
