"""Cross-language choices are checked against the real source/writer planner."""

import base64
import hashlib
import json
from copy import deepcopy
from pathlib import Path
from uuid import UUID

import pytest

from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.imports.attachment_transfers import plan_transfers
from flowtrace_server.imports.schemas import ImportRequest
from flowtrace_server.imports.service import operations_for, target_ids
from flowtrace_server.imports.staging_parsers import open_stage_source
from flowtrace_server.imports.staging_schemas import StageMapping, StageRequirement

GOLDEN_PATH = Path(__file__).parent / "fixtures/stage_image_mapping_golden.json"
GOLDEN = json.loads(GOLDEN_PATH.read_text("utf-8"))


def production_plan(case, mapping):
    """Also callable for the Dart helper's independently produced mapping."""
    mapping = StageMapping.model_validate(mapping)
    source_bytes = base64.b64decode(case["source_base64"], validate=True)
    assert hashlib.sha256(source_bytes).hexdigest() == case["source_sha256"]
    with open_stage_source(
        source_bytes, case["format"], mapping, check_budget=lambda: None
    ) as source:
        values = list(source.rows)
        assert all(value.row is not None and not value.errors for value in values)
        namespace = source.source_namespace
        images = [ref for value in values for ref in value.requirements if ref.kind == "image"]
        assert len(images) == 1
        manifest = source.attachment_sources
    requirement = StageRequirement.model_validate(case["requirement"])
    reference = images[0]
    assert {key: getattr(requirement, key) for key in reference.__dict__} == reference.__dict__
    attachment = next(
        (item for item in manifest if item["source_id"] == reference.source_key), None
    )
    assert (
        requirement.attachment_source.model_dump() if requirement.attachment_source else None
    ) == attachment
    selected = case["selected"]
    content = base64.b64decode(selected["base64"], validate=True)
    assert len(content) == selected["size_bytes"] == 77
    assert hashlib.sha256(content).hexdigest() == selected["sha256"]
    if attachment is not None:
        assert {key: selected[key] for key in ("sha256", "size_bytes", "media_type")} == {
            key: attachment[key] for key in ("sha256", "size_bytes", "media_type")
        }
    principal = Principal(
        **{key: UUID(value) for key, value in case["principal"].items()},
        purpose="api_native",
        roles=frozenset(),
    )
    request = ImportRequest(
        batch_id=case["batch_id"],
        client_id=str(principal.client_id),
        sync_epoch=case["sync_epoch"],
        document=dict(
            format="flowtrace-data-v1",
            source_namespace=namespace,
            rows=[value.row for value in values],
        ),
        scope_mapping=mapping.scope_mapping,
        resource_mapping=mapping.resource_mapping,
        attachment_transfers=mapping.attachment_transfers,
    )
    targets = target_ids(principal, request)
    commands = operations_for(principal, request)
    planned = plan_transfers(request, commands, targets)
    bill = next(command for command in commands if command.entity_type == "bill")
    return dict(
        plan={str(key): str(value) for key, value in planned.items()},
        bill_scope=bill.scope_id,
        bill_attachment_ids=bill.payload.attachment_ids,
        target_ids=targets,
    )


@pytest.mark.parametrize("case", GOLDEN["cases"], ids=lambda case: case["name"])
def test_real_native_and_v10_adapters_rewrite_image_and_same_batch_book_before_transfer(case):
    actual = production_plan(case, case["expected_mapping"])
    assert actual == dict(
        plan=case["expected_plan"],
        bill_scope=case["expected_bill_scope"],
        bill_attachment_ids=case["expected_bill_attachment_ids"],
        target_ids=case["expected_target_ids"],
    )
    if case["format"] == "flowtrace_json":
        assert actual["bill_scope"] != case["target_book_id"]
        assert actual["target_ids"][case["target_book_id"]] == actual["bill_scope"]
        assert case["requirement"]["source_key"] != case["uploaded_id"]
    else:
        assert actual["bill_scope"] == case["target_book_id"]


def test_old_source_id_as_transfer_key_is_rejected_by_actual_native_planner():
    case = GOLDEN["cases"][0]
    incorrect = deepcopy(case["base_mapping"])
    incorrect["attachment_transfers"] = {case["requirement"]["source_key"]: case["uploaded_id"]}
    with pytest.raises(ApiError, match="import_attachment_transfer_destination_mismatch"):
        production_plan(case, incorrect)


@pytest.mark.parametrize("case", GOLDEN["cases"], ids=lambda case: case["name"])
def test_upload_destination_mismatch_is_rejected_after_real_bill_rewrite(case):
    incorrect = deepcopy(case["expected_mapping"])
    incorrect["attachment_transfers"][case["uploaded_id"]] = "ffffffff-ffff-ffff-ffff-ffffffffffff"
    with pytest.raises(ApiError, match="import_attachment_transfer_destination_mismatch"):
        production_plan(case, incorrect)
