"""The integration boundary must preserve omitted versus explicit intent."""

import json
from copy import deepcopy
from pathlib import Path

import pytest
from pydantic import ValidationError

from flowtrace_server.sync.canonical import InvalidSyncBody, content_hash, operation_hash
from flowtrace_server.sync.input import parse_push_body


@pytest.fixture
def request_and_hash():
    path = Path(__file__).resolve().parents[2] / "contracts/fixtures/api/canonical-operation.json"
    fixture = json.loads(path.read_text(encoding="utf-8"))
    frozen = fixture["hash_input"]
    return {
        "protocol_version": frozen["protocol_version"],
        "sync_epoch": frozen["sync_epoch"],
        "client_id": "00000000-0000-4000-8000-000000000001",
        "operations": [frozen["operation"]],
    }, fixture["sha256"]


def encode(body):
    return json.dumps(body, ensure_ascii=False).encode("utf-8")


def test_validated_boundary_retains_published_hash_before_interpreting_defaults(request_and_hash):
    body, digest = request_and_hash
    original = deepcopy(body)
    result = parse_push_body(encode(body))
    assert result.operation_hashes == (digest,)
    assert result.request.operations[0].payload.flags.exclude_from_statistics is False
    assert body == original
    operation = result.request.operations[0].model_dump()
    assert operation_hash(body["protocol_version"], body["sync_epoch"], operation) != digest


def test_equivalent_defaults_are_distinct_original_body_intents(request_and_hash):
    body, _ = request_and_hash
    omitted = parse_push_body(encode(body))
    body["operations"][0]["payload"]["account_id"] = None
    explicit_null = parse_push_body(encode(body))
    body["operations"][0]["payload"]["flags"] = {
        "exclude_from_statistics": False,
        "exclude_from_budget": False,
    }
    explicit_flags = parse_push_body(encode(body))
    assert omitted.request == explicit_null.request == explicit_flags.request
    assert len({item.operation_hashes[0] for item in [omitted, explicit_null, explicit_flags]}) == 3


def test_input_order_and_exact_bigint_values_survive_hashing(request_and_hash):
    body, _ = request_and_hash
    second = deepcopy(body["operations"][0])
    second["operation_id"] = "00000000-0000-4000-8000-000000000099"
    second["entity_id"] = "00000000-0000-4000-8000-000000000098"
    second["payload"]["money"]["amount_minor"] = "9007199254740993"
    body["operations"].append(second)
    result = parse_push_body(encode(body))
    assert result.request.operations[1].payload.money.amount_minor == "9007199254740993"
    assert result.operation_hashes == tuple(
        content_hash({"protocol_version": 1, "sync_epoch": body["sync_epoch"], "operation": item})
        for item in body["operations"]
    )


def test_rejected_body_never_returns_receipt_hashes(request_and_hash):
    body, _ = request_and_hash
    body["operations"][0]["payload"]["money"]["amount_minor"] = "01"
    with pytest.raises(ValidationError):
        parse_push_body(encode(body))
    with pytest.raises(InvalidSyncBody):
        parse_push_body(b'{"protocol_version":1,"protocol_version":1}')
    with pytest.raises(InvalidSyncBody, match="payload_too_large"):
        parse_push_body(encode(body), limit=10)
