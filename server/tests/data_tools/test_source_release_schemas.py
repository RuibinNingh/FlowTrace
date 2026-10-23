"""Source release schema/guard candidate checks; no PG migration/effect claim."""

from pathlib import Path
from uuid import uuid4

import pytest
from pydantic import ValidationError
from sqlalchemy.dialects import postgresql
from sqlalchemy.schema import AddConstraint, CreateTable

from flowtrace_server.imports.staging_models import ImportStage, ImportStageSourceRelease
from flowtrace_server.imports.staging_schemas import (
    StageSourceReleaseReceipt,
    StageSourceReleaseRequest,
    StageStatusResponse,
)
from flowtrace_server.persistence.registry import Base


def request():
    return dict(
        stage_version=1,
        request_id=str(uuid4()),
        batch_id=str(uuid4()),
        client_id=str(uuid4()),
        sync_epoch=str(uuid4()),
        source_sha256="a" * 64,
    )


def test_release_request_is_fixed_closed_and_never_selects_paths_or_sessions():
    body = request()
    assert StageSourceReleaseRequest.model_validate(body).stage_version == 1
    for patch in (
        {"path": "never-read"},
        {"url": "https://invalid/never-fetch"},
        {"origin_session_id": str(uuid4())},
        {"stage_version": True},
        {"source_sha256": "bad"},
        {"request_id": None},
    ):
        with pytest.raises(ValidationError):
            StageSourceReleaseRequest.model_validate(body | patch)


def test_release_receipt_keeps_actual_deleted_bytes_separate_from_reservation():
    body = dict(
        stage_id=str(uuid4()),
        batch_id=str(uuid4()),
        request_id=str(uuid4()),
        stage_version=1,
        source_released_at="2026-10-23T00:00:00Z",
        reserved_bytes_released=100,
        deleted_source_bytes=100,
        deleted_source_chunks=1,
        deleted_preview_rows=4,
        replayed=False,
    )
    assert StageSourceReleaseReceipt.model_validate(body).source_released
    assert (
        StageSourceReleaseReceipt.model_validate(
            body | {"deleted_source_bytes": 0, "deleted_source_chunks": 0}
        ).reserved_bytes_released
        == 100
    )
    for patch in (
        {"deleted_source_bytes": 101},
        {"deleted_source_chunks": 0},
        {"deleted_source_chunks": 2},
        {"source_released": False},
        {"deleted_preview_rows": -1},
        {"replayed": 1},
    ):
        with pytest.raises(ValidationError):
            StageSourceReleaseReceipt.model_validate(body | patch)


def test_closed_status_exposes_release_without_erasing_received_history():
    body = dict(
        stage_id=str(uuid4()),
        batch_id=str(uuid4()),
        stage_version=1,
        format="flowtrace_json",
        status="applied",
        expected_bytes=100,
        received_bytes=100,
        received_chunks=1,
        row_count=4,
        error_count=0,
        preview_hash="a" * 64,
        parse_job_id=None,
        preview_job_id=None,
        apply_job_id=None,
        undo_job_id=None,
        created_at="2026-10-22T00:00:00Z",
        updated_at="2026-10-23T00:00:00Z",
        expires_at="2026-10-29T00:00:00Z",
    )
    assert not StageStatusResponse.model_validate(body).source_released
    released = body | {"source_released": True, "source_released_at": "2026-10-23T00:00:00Z"}
    assert StageStatusResponse.model_validate(released).received_bytes == 100
    for patch in (
        {"source_released_at": None},
        {"source_released": False},
        {"received_bytes": 0, "received_chunks": 0},
        {"status": "uploading"},
    ):
        with pytest.raises(ValidationError):
            StageStatusResponse.model_validate(released | patch)


def test_frozen_ddl_has_nullable_marker_paired_with_append_only_owner_audit():
    assert "users" in Base.metadata.tables
    audit = str(
        CreateTable(ImportStageSourceRelease.__table__).compile(dialect=postgresql.dialect())
    )
    assert "PRIMARY KEY (stage_id)" in audit
    assert "UNIQUE (owner_user_id, request_id)" in audit
    assert "FOREIGN KEY(stage_id, batch_id) REFERENCES import_stages (id, batch_id)" in audit
    assert "received_bytes_snapshot=reserved_bytes_released" in audit
    assert ImportStage.__table__.c.source_released_at.nullable
    pair = next(
        key
        for key in ImportStage.__table__.foreign_key_constraints
        if key.name == "fk_stage_source_release_receipt"
    )
    assert pair.use_alter
    ddl = str(AddConstraint(pair).compile(dialect=postgresql.dialect()))
    assert "FOREIGN KEY(id, source_released_at)" in ddl
    assert "REFERENCES import_stage_source_releases (stage_id, released_at)" in ddl
    check = next(
        key for key in ImportStage.__table__.constraints if key.name == "ck_stage_source_release"
    )
    assert "'applied','undoing','undone'" in str(check.sqltext)
    assert "received_bytes=expected_bytes" in str(check.sqltext)


def test_guard_candidate_is_fixed_invoker_and_preserves_old_source_marker():
    source = (Path(__file__).parent / "fixtures/0014_source_release_lifecycle.sql").read_text(
        "utf-8"
    )
    assert source.count("SECURITY INVOKER") == source.count("SET search_path = pg_catalog") == 2
    assert source.count("CREATE TRIGGER") == 3
    assert "BEFORE UPDATE OR DELETE ON public.import_stage_source_releases" in source
    assert "BEFORE TRUNCATE ON public.import_stage_source_releases" in source
    assert "OLD.source_released_at IS NOT NULL" in source
    assert "NEW.source_released_at IS DISTINCT FROM OLD.source_released_at" in source
    assert source.count("ERRCODE = '55000'") == 2
    assert "SECURITY DEFINER" not in source and "CASCADE" not in source
