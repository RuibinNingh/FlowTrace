"""Explicit source abandonment after origin expiry cannot erase finance."""

from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from pydantic import ValidationError
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from sync.helpers import actor, epoch

from flowtrace_server.attachments.models import Attachment
from flowtrace_server.attachments.service import hold_attachments
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import UserSession
from flowtrace_server.imports.models import ImportBatch
from flowtrace_server.imports.staging import StagePolicy, create_stage
from flowtrace_server.imports.staging_discard import discard_stage
from flowtrace_server.imports.staging_holds import stage_hold_id
from flowtrace_server.imports.staging_models import (
    ImportPublication,
    ImportStage,
    ImportStageRequirement,
    ImportStageRow,
    ImportStageUploadChunk,
)
from flowtrace_server.imports.staging_schemas import StageCreate, StageDiscard
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.jobs.store import LeaseLost

from .test_import_attachments import ready_image
from .test_source_release import published
from .test_stage_reauthorization_metadata import table_fingerprints
from .test_staging_holds import holds, image_stage, queue_preview
from .test_staging_http import PREFIX, headers, post
from .test_staging_http import stage_http as stage_http
from .test_staging_parse import complete_parse, prepared
from .test_staging_parsers import source_file
from .test_staging_preview import categories
from .test_staging_requirements import source_owner as source_owner

pytestmark = pytest.mark.postgres


def body_for(engine, owner, stage, *, version=1):
    with Session(engine) as session:
        row = session.get(ImportStage, UUID(stage.stage_id))
        return StageDiscard(
            stage_version=version,
            batch_id=stage.batch_id,
            client_id=str(owner.principal.client_id),
            sync_epoch=epoch(engine),
            source_sha256=row.source_sha256,
        )


def discard(engine, owner, stage, body, budget=lambda: None):
    with Session(engine) as session:
        return discard_stage(
            session, owner.principal, UUID(stage.stage_id), body, check_budget=budget
        )


def source_counts(session, stage):
    return tuple(
        session.scalar(
            select(func.count()).select_from(model).where(model.stage_id == UUID(stage.stage_id))
        )
        for model in (ImportStageUploadChunk, ImportStageRow, ImportStageRequirement)
    )


def revoke_origin(engine, owner):
    with Session(engine) as session, session.begin():
        row = session.get(UserSession, owner.principal.session_id)
        row.revoked_at = session.scalar(select(func.clock_timestamp()))
    return actor(engine, owner.principal.user_id)


def test_discard_body_is_closed_and_never_accepts_old_origin_or_fetch_target():
    raw = dict(
        stage_version=1,
        batch_id=str(uuid4()),
        client_id=str(uuid4()),
        sync_epoch=str(uuid4()),
        source_sha256="a" * 64,
    )
    assert StageDiscard.model_validate(raw).model_dump() == raw
    for patch in (
        {"origin_session_id": str(uuid4())},
        {"url": "https://unused.invalid"},
        {"source_sha256": "invalid"},
        {"stage_version": True},
    ):
        with pytest.raises(ValidationError):
            StageDiscard.model_validate(raw | patch)


def test_new_session_discards_real_source_requirements_and_cancels_old_claim(
    postgres_engine, source_owner, stage_http
):
    content = source_file("flowtrace_json", categories(source_owner, 4))
    stage, lease = prepared(postgres_engine, source_owner, content)
    complete_parse(postgres_engine, lease)
    pending = queue_preview(postgres_engine, source_owner, stage)
    with Session(postgres_engine) as session:
        row = session.get(ImportStage, UUID(stage.stage_id))
        original = (
            row.created_at,
            row.source_sha256,
            row.mapping,
            row.origin_session_id,
            row.client_id,
        )
        assert source_counts(session, stage) == (1, 4, 1)
    renewed = revoke_origin(postgres_engine, source_owner)
    body = body_for(postgres_engine, renewed, stage)
    # Ordinary origin-bound reads/cancel stay strict.
    assert (
        stage_http.get(PREFIX + "/" + stage.stage_id, headers=headers(renewed)).status_code == 409
    )
    assert (
        post(
            stage_http, renewed, {"stage_id": stage.stage_id}, "cancel", {"stage_version": 1}
        ).status_code
        == 409
    )
    response = post(stage_http, renewed, {"stage_id": stage.stage_id}, "discard", body.model_dump())
    assert response.status_code == 200 and "no-store" in response.headers["cache-control"]
    value = response.json()
    assert value["status"] == "cancelled" and value["stage_version"] == 2
    assert value["received_bytes"] == value["received_chunks"] == value["row_count"] == 0
    assert value["requirements_version"] is None and value["preview_hash"] is None
    with Session(postgres_engine) as session:
        row = session.get(ImportStage, UUID(stage.stage_id))
        assert (
            row.created_at,
            row.source_sha256,
            row.mapping,
            row.origin_session_id,
            row.client_id,
        ) == original
        assert source_counts(session, stage) == (0, 0, 0)
        assert session.get(BackgroundJob, UUID(pending.job_id)).status == "cancelled"
        assert session.get(ImportBatch, row.batch_id) is None
        assert not session.scalar(
            select(ImportPublication.id).where(ImportPublication.stage_id == row.id)
        )
    with pytest.raises(LeaseLost):
        complete_parse(postgres_engine, lease)
    # N and current N+1 confirm actual desired state without a new binding/ACK.
    before = table_fingerprints(postgres_engine)
    assert discard(postgres_engine, renewed, stage, body).stage_version == 2
    assert (
        discard(
            postgres_engine, renewed, stage, body.model_copy(update={"stage_version": 2})
        ).stage_version
        == 2
    )
    after = table_fingerprints(postgres_engine)
    # The current client may be renewed, but no stage/source/financial history changes.
    for name in before.keys() - {"sync_clients"}:
        assert before[name] == after[name]
    probe = stage_http.get(
        PREFIX + f"/{stage.stage_id}/reauthorization", headers=headers(renewed)
    ).json()
    assert probe["status"] == "cancelled" and probe["source_sha256"] == body.source_sha256
    assert (
        stage_http.get(PREFIX + "/" + stage.stage_id, headers=headers(renewed)).status_code == 409
    )


def test_actual_expired_source_can_be_explicitly_discarded_by_current_session(
    postgres_engine, source_owner, stage_http
):
    stage, _ = prepared(
        postgres_engine, source_owner, source_file("flowtrace_json", categories(source_owner, 2))
    )
    with Session(postgres_engine) as session, session.begin():
        row = session.get(ImportStage, UUID(stage.stage_id))
        row.created_at -= timedelta(days=10)
        row.expires_at = session.scalar(select(func.clock_timestamp())) - timedelta(seconds=1)
    renewed = revoke_origin(postgres_engine, source_owner)
    reauth = post(
        stage_http,
        renewed,
        {"stage_id": stage.stage_id},
        "reauthorize",
        {
            "stage_version": 1,
            "client_id": str(renewed.principal.client_id),
            "sync_epoch": epoch(postgres_engine),
        },
    )
    assert reauth.status_code == 410
    body = body_for(postgres_engine, renewed, stage)
    value = discard(postgres_engine, renewed, stage, body)
    assert value.status == "cancelled" and value.stage_version == 2
    with Session(postgres_engine) as session:
        assert source_counts(session, stage) == (0, 0, 0)


@pytest.mark.parametrize(
    "change,code",
    [
        ("batch_id", "import_stage_discard_conflict"),
        ("source_sha256", "import_stage_discard_conflict"),
        ("stage_version", "import_stage_version_changed"),
        ("client_id", "client_mismatch"),
        ("sync_epoch", "epoch_changed"),
    ],
)
def test_discard_requires_exact_frozen_identity_and_current_client(
    postgres_engine, source_owner, change, code
):
    stage, _ = prepared(
        postgres_engine, source_owner, source_file("flowtrace_json", categories(source_owner, 1))
    )
    body = body_for(postgres_engine, source_owner, stage)
    changed = (
        5 if change == "stage_version" else "f" * 64 if change == "source_sha256" else str(uuid4())
    )
    before = table_fingerprints(postgres_engine)
    with pytest.raises(ApiError, match=code):
        discard(postgres_engine, source_owner, stage, body.model_copy(update={change: changed}))
    assert table_fingerprints(postgres_engine) == before


def test_foreign_owner_cannot_discard_and_cancelled_corruption_is_not_false_success(
    postgres_engine, source_owner
):
    stage, _ = prepared(
        postgres_engine, source_owner, source_file("flowtrace_json", categories(source_owner, 1))
    )
    other = actor(postgres_engine)
    with pytest.raises(ApiError, match="import_stage_not_found"):
        discard(postgres_engine, other, stage, body_for(postgres_engine, other, stage))
    with Session(postgres_engine) as session, session.begin():
        # Simulate corrupted prior cancellation; do not silently declare quota freed.
        session.get(ImportStage, UUID(stage.stage_id)).status = "cancelled"
    with pytest.raises(ApiError, match="import_stage_discard_incomplete"):
        discard(
            postgres_engine, source_owner, stage, body_for(postgres_engine, source_owner, stage)
        )
    with Session(postgres_engine) as session:
        assert source_counts(session, stage)[0] == 1


@pytest.mark.parametrize("phase", ["applying", "applied", "undoing", "undone"])
def test_ambiguous_or_financial_phase_never_discards_even_without_publication(
    postgres_engine, source_owner, phase
):
    stage, lease = prepared(
        postgres_engine, source_owner, source_file("flowtrace_json", categories(source_owner, 1))
    )
    with Session(postgres_engine) as session, session.begin():
        row = session.get(ImportStage, UUID(stage.stage_id))
        row.status = phase
        row.preview_hash = "a" * 64
        row.preview_version = 1
        old_job = session.get(BackgroundJob, lease.job_id)
        old_job.status, old_job.error_code = "failed", "fixture_failure"
        old_job.lease_owner = old_job.lease_token = old_job.lease_until = None
    before = table_fingerprints(postgres_engine)
    with pytest.raises(ApiError, match="import_stage_state_conflict"):
        discard(
            postgres_engine, source_owner, stage, body_for(postgres_engine, source_owner, stage)
        )
    assert table_fingerprints(postgres_engine) == before


def test_formal_batch_and_publication_are_guarded_independent_of_visible_phase(postgres_engine):
    owner, stage, _ = published(postgres_engine)
    with Session(postgres_engine) as session, session.begin():
        session.get(ImportStage, UUID(stage.stage_id)).status = "parsed"
    before = table_fingerprints(postgres_engine)
    with pytest.raises(ApiError, match="import_stage_state_conflict"):
        discard(postgres_engine, owner, stage, body_for(postgres_engine, owner, stage))
    assert table_fingerprints(postgres_engine) == before


def test_budget_after_actual_deletes_rolls_back_source_hold_job_and_stage(
    postgres_engine, source_owner, tmp_path
):
    uploaded, _, original, files = ready_image(postgres_engine, source_owner, tmp_path / "files")
    stage, _ = image_stage(postgres_engine, source_owner, uploaded, original)
    job = queue_preview(postgres_engine, source_owner, stage)
    body = body_for(postgres_engine, source_owner, stage)
    before = table_fingerprints(postgres_engine)
    observed_deletion = False
    with Session(postgres_engine) as session:

        def budget():
            nonlocal observed_deletion
            if source_counts(session, stage)[0] == 0:
                observed_deletion = True
                assert source_counts(session, stage) == (0, 0, 0)
                assert not holds(session, uploaded)
                assert session.get(BackgroundJob, UUID(job.job_id)).status == "cancelled"
                raise ApiError("import_stage_discard_timeout", 503)

        with pytest.raises(ApiError, match="import_stage_discard_timeout"):
            discard_stage(
                session, source_owner.principal, UUID(stage.stage_id), body, check_budget=budget
            )
    assert observed_deletion and table_fingerprints(postgres_engine) == before
    with Session(postgres_engine) as session:
        image = session.get(Attachment, uploaded)
        assert (
            image.scope_id == source_owner.principal.user_id
            and files.content(image.storage_key) == original
        )


def test_discard_preserves_other_stage_hold_backup_hold_and_original(
    postgres_engine, source_owner, tmp_path
):
    uploaded, _, original, files = ready_image(postgres_engine, source_owner, tmp_path / "files")
    first, _ = image_stage(postgres_engine, source_owner, uploaded, original)
    queue_preview(postgres_engine, source_owner, first)
    second, _ = image_stage(postgres_engine, source_owner, uploaded, original)
    backup = uuid4()
    with Session(postgres_engine) as session:
        hold_attachments(session, backup, [uploaded], "backup")
        own = stage_hold_id(session.get(ImportStage, UUID(first.stage_id)))
        session.commit()
    discard(postgres_engine, source_owner, second, body_for(postgres_engine, source_owner, second))
    with Session(postgres_engine) as session:
        assert holds(session, uploaded) == {own: "job", backup: "backup"}
    renewed = revoke_origin(postgres_engine, source_owner)
    discard(postgres_engine, renewed, first, body_for(postgres_engine, renewed, first))
    with Session(postgres_engine) as session:
        assert holds(session, uploaded) == {backup: "backup"}
        image = session.get(Attachment, uploaded)
        assert (
            image.scope_id == source_owner.principal.user_id
            and files.content(image.storage_key) == original
        )


def test_quota_is_available_only_after_actual_source_discard(postgres_engine, source_owner):
    content = source_file("flowtrace_json", categories(source_owner, 2))
    stage, _ = prepared(postgres_engine, source_owner, content)
    new = StageCreate(
        client_id=str(source_owner.principal.client_id),
        sync_epoch=epoch(postgres_engine),
        format="flowtrace_json",
        expected_bytes=len(content),
        source_sha256="b" * 64,
    )
    policy = StagePolicy(max_retained_stages=1, max_reserved_bytes=len(content))
    with Session(postgres_engine) as session, pytest.raises(ApiError, match="import_stage_quota"):
        create_stage(session, source_owner.principal, new, policy=policy)
    discard(postgres_engine, source_owner, stage, body_for(postgres_engine, source_owner, stage))
    with Session(postgres_engine) as session:
        next_stage = create_stage(session, source_owner.principal, new, policy=policy)
        assert next_stage.stage_id != stage.stage_id and source_counts(session, stage) == (0, 0, 0)


def test_discard_router_is_bounded_strict_and_uses_current_session_budget(
    postgres_engine, source_owner, stage_http, monkeypatch
):
    from flowtrace_server.imports import staging_router

    stage, _ = prepared(
        postgres_engine, source_owner, source_file("flowtrace_json", categories(source_owner, 1))
    )
    renewed = revoke_origin(postgres_engine, source_owner)
    body = body_for(postgres_engine, renewed, stage)
    path = PREFIX + f"/{stage.stage_id}/discard"
    assert stage_http.post(path, json=body.model_dump()).status_code == 401
    assert (
        stage_http.post(
            path + "?force=true", headers=headers(renewed), json=body.model_dump()
        ).status_code
        == 422
    )
    assert (
        stage_http.post(
            path,
            headers=headers(renewed),
            json=body.model_dump() | {"origin_session_id": str(uuid4())},
        ).status_code
        == 422
    )
    raw = body.model_dump_json()[:-1] + ',"stage_version":1}'
    duplicate = stage_http.post(
        path, headers=headers(renewed) | {"content-type": "application/json"}, content=raw
    )
    assert duplicate.status_code == 400
    monkeypatch.setattr(staging_router, "REAUTHORIZE_SECONDS", 0)
    denied = stage_http.post(path, headers=headers(renewed), json=body.model_dump())
    assert denied.status_code == 503
    assert denied.json()["error"]["code"] == "import_stage_discard_timeout"
    with Session(postgres_engine) as session:
        assert source_counts(session, stage)[0] == 1
