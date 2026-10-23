from uuid import uuid4

import pytest
from starlette.datastructures import FormData

from flowtrace_server.admin.configuration_forms import parse_update
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.configuration.schemas import INITIAL_PUBLIC_VALUES, PublicConfiguration


def form_values():
    values = {
        key: str(value).lower() if isinstance(value, bool) else str(value)
        for key, value in INITIAL_PUBLIC_VALUES.items()
    }
    values.update(
        csrf_token="csrf-fixture",
        base_version="0",
        request_id=str(uuid4()),
        confirm_version="0",
        current_password="Private-current-password-fixture",
        ocr_api_key_action="keep",
        ocr_api_key_value="",
        ai_api_key_action="keep",
        ai_api_key_value="",
    )
    return values


def test_form_keeps_raw_secret_values_redacted_and_never_accepts_reference_uuid():
    values = form_values()
    values.update(ocr_api_key_action="replace", ocr_api_key_value="private-raw-key")
    parsed = parse_update(FormData(values))
    assert parsed.secret_changes["ocr_api_key"]["value"].get_secret_value() == "private-raw-key"
    assert "private-raw-key" not in repr(parsed)
    assert values["current_password"] not in repr(parsed)
    assert parsed.public_patch.apply(PublicConfiguration()).worker_poll_seconds == 1.0
    values["ocr_api_key"] = str(uuid4())
    with pytest.raises(ApiError):
        parse_update(FormData(values))


@pytest.mark.parametrize(
    ("key", "value"),
    [
        ("registration_enabled", "1"),
        ("worker_poll_seconds", "NaN"),
        ("worker_poll_seconds", "1e1"),
        ("worker_poll_seconds", "60.001"),
        ("invitation_default_days", "+7"),
        ("base_version", "9223372036854775808"),
        ("confirm_version", "1"),
        ("request_id", "not-a-uuid"),
        ("ocr_provider", "https://example.invalid/"),
        ("ocr_api_key_action", "unknown"),
        ("ocr_api_key_value", "unselected-replacement"),
    ],
)
def test_html_decoder_rejects_closed_boundary_without_echo(key, value):
    values = form_values()
    values[key] = value
    with pytest.raises(ApiError) as caught:
        parse_update(FormData(values))
    assert caught.value.status == 422
    assert value not in caught.value.code


def test_duplicate_and_missing_fields_are_rejected():
    values = form_values()
    with pytest.raises(ApiError):
        parse_update(FormData([*values.items(), ("request_id", str(uuid4()))]))
    values.pop("confirm_version")
    with pytest.raises(ApiError):
        parse_update(FormData(values))


def test_public_preview_needs_no_password_or_save_confirmation():
    values = form_values()
    values.pop("confirm_version")
    values["current_password"] = ""
    parsed = parse_update(FormData(values), require_confirmation=False)
    assert parsed.password == "" and parsed.base_version == 0
