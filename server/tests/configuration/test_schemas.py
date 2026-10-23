import json
from uuid import uuid4

import pytest
from pydantic import ValidationError

from flowtrace_server.configuration.schemas import (
    INITIAL_PUBLIC_VALUES,
    INITIAL_SECRET_REFS,
    ConfigurationSaveCommand,
    PreparedSecretReferencePatch,
    PublicConfiguration,
    PublicConfigurationPatch,
    SecretReferences,
)


def test_initial_values_are_explicit_and_secret_free():
    assert PublicConfiguration().model_dump() == INITIAL_PUBLIC_VALUES
    assert SecretReferences().model_dump(mode="json") == INITIAL_SECRET_REFS
    assert INITIAL_SECRET_REFS == {"ocr_api_key": None, "ai_api_key": None}


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("registration_enabled", "true"),
        ("diagnostics_enabled", 1),
        ("invitation_default_days", True),
        ("invitation_default_days", 0),
        ("invitation_default_days", 31),
        ("attachment_max_bytes", 0),
        ("attachment_max_bytes", 10485761),
        ("per_user_attachment_quota_bytes", 1024**4 + 1),
        ("orphan_retention_days", 366),
        ("backup_retention_days", 3651),
        ("worker_poll_seconds", True),
        ("worker_poll_seconds", "1"),
        ("worker_poll_seconds", 0.249),
        ("worker_poll_seconds", 60.01),
        ("worker_poll_seconds", float("nan")),
        ("worker_poll_seconds", float("inf")),
        ("ocr_provider", "ai_primary"),
        ("ai_provider", "https://example.invalid"),
    ],
)
def test_ranges_types_and_provider_ids_are_closed(field, value):
    with pytest.raises(ValidationError):
        PublicConfiguration.model_validate({field: value})


def test_public_patch_revalidates_merged_quota_and_rejects_explicit_null():
    original = PublicConfiguration()
    assert PublicConfigurationPatch().apply(original) == original
    patch = PublicConfigurationPatch(attachment_max_bytes=10, per_user_attachment_quota_bytes=20)
    assert patch.apply(original).per_user_attachment_quota_bytes == 20
    with pytest.raises(ValidationError, match="configuration_quota_below_file_limit"):
        PublicConfigurationPatch(per_user_attachment_quota_bytes=20).apply(original)
    with pytest.raises(ValidationError, match="configuration_null_value_invalid"):
        PublicConfigurationPatch(registration_enabled=None)


def test_secret_patch_distinguishes_keep_replace_delete():
    old, replacement = uuid4(), uuid4()
    refs = SecretReferences(ocr_api_key=old)
    assert PreparedSecretReferencePatch().apply(refs) == refs
    changed = PreparedSecretReferencePatch(ai_api_key=replacement).apply(refs)
    assert changed.ocr_api_key == old and changed.ai_api_key == replacement
    assert PreparedSecretReferencePatch(ocr_api_key=None).apply(changed).ocr_api_key is None
    assert changed.ocr_api_key == old
    assert changed.model_dump(mode="json")["ai_api_key"] == str(replacement)


def test_uuid_reference_json_roundtrip_and_closed_secret_keys():
    identifier = uuid4()
    refs = SecretReferences.model_validate_json(json.dumps({"ocr_api_key": str(identifier)}))
    assert refs.ocr_api_key == identifier
    for data in ({"ocr_api_key": "raw-secret-value"}, {"endpoint": "file://secret"}):
        with pytest.raises(ValidationError):
            SecretReferences.model_validate_json(json.dumps(data))


def test_commands_reject_extra_fields_and_redact_validation_inputs():
    request_id = uuid4()
    command = ConfigurationSaveCommand(
        base_version=0, request_id=request_id, public_patch=PublicConfigurationPatch()
    )
    assert command.prepared_secret_refs.model_dump(exclude_unset=True) == {}
    for value in (-1, True, 2**63):
        with pytest.raises(ValidationError):
            ConfigurationSaveCommand(
                base_version=value, request_id=request_id, public_patch=PublicConfigurationPatch()
            )
    with pytest.raises(ValidationError) as caught:
        PublicConfiguration.model_validate({"endpoint": "secret-not-to-echo"})
    assert "secret-not-to-echo" not in str(caught.value)
    with pytest.raises(ValidationError):
        PublicConfigurationPatch.model_validate({"ocr_api_key": str(uuid4())})
