"""Future closed staging contracts; no migration/service/job execution claim."""

from uuid import uuid4

import pytest
from pydantic import ValidationError

from flowtrace_server.imports.staging_schemas import (
    STAGE_CHUNK_BYTES,
    STAGE_MAX_SOURCE_BYTES,
    StageApplyJob,
    StageChunkReceipt,
    StageCreate,
    StageParseJob,
    StagePreviewJob,
    StageRowPreview,
    StageRowsPage,
    StageUndoJob,
)


def test_upload_creation_never_accepts_paths_urls_or_caller_selected_sessions():
    body = {
        "client_id": str(uuid4()),
        "sync_epoch": str(uuid4()),
        "format": "qianji_csv",
        "source_sha256": "a" * 64,
        "expected_bytes": STAGE_MAX_SOURCE_BYTES,
    }
    assert StageCreate.model_validate(body).expected_bytes == STAGE_MAX_SOURCE_BYTES
    for extra in (
        {"path": "C:/never-read"},
        {"url": "https://invalid/never-fetch"},
        {"origin_session_id": str(uuid4())},
        {"origin_purpose": "admin"},
        {"expected_bytes": True},
        {"expected_bytes": STAGE_MAX_SOURCE_BYTES + 1},
    ):
        with pytest.raises(ValidationError):
            StageCreate.model_validate({**body, **extra})


def test_upload_receipt_requires_complete_prefix_and_exact_final_chunk_length():
    body = {
        "stage_id": str(uuid4()),
        "stage_version": 1,
        "chunk_index": 0,
        "chunk_sha256": "a" * 64,
        "size_bytes": STAGE_CHUNK_BYTES,
        "next_chunk_index": 1,
        "received_bytes": STAGE_CHUNK_BYTES,
        "expected_bytes": STAGE_CHUNK_BYTES + 1,
        "replayed": False,
    }
    assert StageChunkReceipt.model_validate(body).next_chunk_index == 1
    assert StageChunkReceipt.model_validate(
        {
            **body,
            "chunk_index": 1,
            "size_bytes": 1,
            "next_chunk_index": 2,
            "received_bytes": STAGE_CHUNK_BYTES + 1,
        }
    )
    for changes in (
        {"size_bytes": 1},
        {"chunk_index": 2},
        {"received_bytes": STAGE_CHUNK_BYTES - 1},
        {"next_chunk_index": 3},
    ):
        with pytest.raises(ValidationError):
            StageChunkReceipt.model_validate({**body, **changes})


@pytest.mark.parametrize(
    "model,action,extra",
    [
        (StageParseJob, "parse", {"source_sha256": "a" * 64}),
        (StagePreviewJob, "preview", {"source_sha256": "a" * 64, "mapping_hash": "b" * 64}),
        (StageApplyJob, "apply", {"batch_id": str(uuid4()), "preview_hash": "b" * 64}),
        (StageUndoJob, "undo", {"batch_id": str(uuid4())}),
    ],
)
def test_job_intent_contains_only_fixed_stage_references_no_rows_or_file_bytes(
    model, action, extra
):
    body = {"action": action, "stage_id": str(uuid4()), "stage_version": 2, **extra}
    assert model.model_validate(body).stage_version == 2
    for forbidden in (
        {"rows": []},
        {"file_bytes": "private"},
        {"token": "never-store"},
        {"owner_user_id": str(uuid4())},
    ):
        with pytest.raises(ValidationError):
            model.model_validate({**body, **forbidden})


def test_paginated_stage_errors_are_located_and_never_silently_truncated():
    row = {
        "position": 1,
        "source_line": 2,
        "source_id": None,
        "row": None,
        "target_entity_id": None,
        "status": "invalid",
        "warning": None,
        "errors": [{"row": 2, "field": "money", "code": "invalid_exact_amount"}],
    }
    assert StageRowPreview.model_validate(row).source_line == 2
    with pytest.raises(ValidationError):
        StageRowPreview.model_validate({**row, "errors": []})
    body = {
        "stage_id": str(uuid4()),
        "stage_version": 1,
        "rows": [row],
        "has_more": True,
        "next_cursor": "fixed-version-position",
    }
    assert StageRowsPage.model_validate(body).has_more
    for changes in ({"next_cursor": None}, {"rows": []}, {"rows": [row, row]}):
        with pytest.raises(ValidationError):
            StageRowsPage.model_validate({**body, **changes})
