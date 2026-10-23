"""Actual host protection roundtrip and closed private reference boundaries."""

import json
import os
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from uuid import uuid4

import pytest
from pydantic import SecretStr

from flowtrace_server.configuration.secrets import SecretStorageError, SecretVault


def prepare(vault, **kwargs):
    return vault.prepare(
        "ai_api_key",
        SecretStr("synthetic-vault-sentinel-20261023"),
        actor_id=uuid4(),
        base_version=0,
        request_id=uuid4(),
        **kwargs,
    )


def test_host_secret_roundtrip_reopen_never_exposes_value_in_reference(tmp_path):
    vault = SecretVault(tmp_path)
    prepared = prepare(vault)
    assert vault.validate_prepared(prepared) == prepared.reference
    assert "sentinel" not in repr(prepared)
    path = vault.root / f"{prepared.reference}.json"
    envelope = json.loads(path.read_bytes())
    assert set(envelope) == {"format", "protection", "content"}
    if os.name == "nt":
        assert envelope["protection"] == "dpapi-current-user"
        assert b"synthetic-vault-sentinel" not in path.read_bytes()
    assert SecretVault(tmp_path).read(prepared.reference, "ai_api_key").get_secret_value() == (
        "synthetic-vault-sentinel-20261023"
    )


@pytest.mark.parametrize("changed", ["field", "actor_id", "base_version", "request_id"])
def test_prepared_reference_is_bound_to_exact_intent(tmp_path, changed):
    vault = SecretVault(tmp_path)
    prepared = prepare(vault)
    value = {"field": "ocr_api_key", "actor_id": uuid4(), "base_version": 1, "request_id": uuid4()}[
        changed
    ]
    with pytest.raises(SecretStorageError, match="secret_preparation_mismatch"):
        vault.validate_prepared(replace(prepared, **{changed: value}))
    with pytest.raises(SecretStorageError, match="secret_reference_mismatch"):
        vault.read(prepared.reference, "ocr_api_key")


def test_tampered_copied_or_missing_reference_fails_closed(tmp_path):
    vault = SecretVault(tmp_path)
    prepared = prepare(vault)
    path = vault.root / f"{prepared.reference}.json"
    copied = uuid4()
    (vault.root / f"{copied}.json").write_bytes(path.read_bytes())
    with pytest.raises(SecretStorageError):
        vault.read(copied, "ai_api_key")
    path.write_bytes(b'{"format":"invalid","content":"not-a-secret"}')
    with pytest.raises(SecretStorageError):
        vault.read(prepared.reference, "ai_api_key")
    with pytest.raises(SecretStorageError):
        vault.read(uuid4(), "ai_api_key")
    with pytest.raises(SecretStorageError, match="secret_reference_invalid"):
        vault.read("../../outside", "ai_api_key")


def test_invalid_secret_is_rejected_before_any_file_is_created(tmp_path):
    vault = SecretVault(tmp_path)
    for value in ("", "abc\r\nInjected: value", "a" * 4097):
        with pytest.raises(SecretStorageError, match="secret_input_invalid"):
            vault.prepare(
                "ai_api_key", SecretStr(value), actor_id=uuid4(), base_version=0, request_id=uuid4()
            )
    assert list(vault.root.iterdir()) == []


@pytest.mark.parametrize("character", ["界", "\U0001f30a"])
def test_maximum_multibyte_value_is_readable_after_prepare(tmp_path, character):
    vault = SecretVault(tmp_path)
    value = character * 4096
    prepared = vault.prepare(
        "ai_api_key", SecretStr(value), actor_id=uuid4(), base_version=0, request_id=uuid4()
    )
    assert vault.validate_prepared(prepared) == prepared.reference
    assert SecretVault(tmp_path).read(prepared.reference, "ai_api_key").get_secret_value() == value


def test_same_intent_concurrent_preparation_reuses_exact_reference_and_rejects_new_secret(tmp_path):
    actor, request = uuid4(), uuid4()

    def prepare_same(value="synthetic-idempotent-key"):
        return SecretVault(tmp_path).prepare(
            "ai_api_key",
            SecretStr(value),
            actor_id=actor,
            base_version=7,
            request_id=request,
        )

    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(prepare_same) for _ in range(2)]
        first, second = (future.result(timeout=10) for future in futures)
    assert first == second
    assert len(list(SecretVault(tmp_path).root.glob("*.json"))) == 1
    with pytest.raises(SecretStorageError, match="secret_preparation_conflict"):
        prepare_same("synthetic-different-key")
    assert SecretVault(tmp_path).read(first.reference, "ai_api_key").get_secret_value() == (
        "synthetic-idempotent-key"
    )
