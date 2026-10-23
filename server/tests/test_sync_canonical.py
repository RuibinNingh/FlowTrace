import json
from pathlib import Path

import pytest

from flowtrace_server.sync.canonical import (
    InvalidSyncBody,
    canonical_bytes,
    content_hash,
    decode_body,
    operation_hash,
)


def test_published_digest_and_key_order():
    path = Path(__file__).resolve().parents[2] / "contracts/fixtures/api/canonical-operation.json"
    fixture = json.loads(path.read_text(encoding="utf-8"))
    original = fixture["hash_input"]
    assert canonical_bytes(original).decode() == fixture["canonical_utf8"]
    assert (
        operation_hash(original["protocol_version"], original["sync_epoch"], original["operation"])
        == fixture["sha256"]
    )
    assert content_hash(dict(reversed(list(original.items())))) == fixture["sha256"]


@pytest.mark.parametrize(
    "raw",
    [
        b'{"value":1,"value":2}',
        b'{"value":NaN}',
        b'{"value":0.1}',
        b'{"value":1e2}',
        b'{"value":-1}',
        b'{"value":-0}',
        b'{"value":2147483648}',
        b'{"value":"\\ud800"}',
        b'{"value":"\\u0000"}',
        b'{"\\u91d1\\u989d":"1"}',
        b"[]",
        b'{"value":',
        b'{"value":"\xff"}',
    ],
)
def test_ambiguous_or_inexact_request_rejected(raw):
    with pytest.raises(InvalidSyncBody):
        decode_body(raw)


def test_64_bit_money_never_converted_to_float():
    original = {"amount_minor": "9223372036854775807", "note": "早餐🍜"}
    assert decode_body(canonical_bytes(original)) == original


def test_missing_and_null_are_different_frozen_intents():
    assert content_hash({}) != content_hash({"depends_on": None})
    assert content_hash({"amount_minor": "1"}) != content_hash({"amount_minor": "2"})


def test_bounded_body_and_depth():
    with pytest.raises(InvalidSyncBody, match="payload_too_large"):
        decode_body(b'{"a":"12345"}', limit=8)
    value = {"a": None}
    for _ in range(33):
        value = {"a": value}
    with pytest.raises(InvalidSyncBody, match="json_too_deep"):
        canonical_bytes(value)


def test_control_integer_boundaries_and_very_long_integer():
    assert decode_body(b'{"count":0,"max":2147483647}') == {
        "count": 0,
        "max": 2147483647,
    }
    with pytest.raises(InvalidSyncBody, match="invalid_control_integer"):
        decode_body(b'{"count":' + b"1" * 5000 + b"}")


def test_escaped_duplicate_keys_and_unicode_are_exact():
    with pytest.raises(InvalidSyncBody, match="duplicate_json_key"):
        decode_body(b'{"note":"one","\\u006eote":"two"}')
    assert content_hash({"note": "\u00e9"}) != content_hash({"note": "e\u0301"})
    assert decode_body(b'{"note":"\\ud83c\\udf5c"}') == {"note": "🍜"}
