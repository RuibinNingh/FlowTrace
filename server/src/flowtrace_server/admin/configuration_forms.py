"""Closed HTML inputs; no model imports or authority-bearing secret UUIDs."""

import re
from dataclasses import dataclass, field
from uuid import UUID

from pydantic import SecretStr, ValidationError

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.configuration.schemas import PublicConfigurationPatch

PUBLIC_FIELDS = (
    ("registration_enabled", "允许邀请注册", "bool", None, None),
    ("invitation_default_days", "邀请默认有效天数", "int", 1, 30),
    ("attachment_max_bytes", "单个附件上限（字节）", "int", 1, 10485760),
    ("per_user_attachment_quota_bytes", "每位用户附件配额（字节）", "int", 1, 1099511627776),
    ("orphan_retention_days", "孤立附件保留天数", "int", 1, 365),
    ("diagnostics_enabled", "允许诊断记录", "bool", None, None),
    ("worker_poll_seconds", "执行器轮询间隔（秒）", "float", 0.25, 60),
    ("backup_retention_days", "备份保留天数", "int", 1, 3650),
    ("ocr_provider", "OCR 服务", "provider", None, None),
    ("ai_provider", "AI 服务", "provider", None, None),
)
SECRET_FIELDS = (("ocr_api_key", "OCR API 密钥"), ("ai_api_key", "AI API 密钥"))
PUBLIC_KEYS = frozenset(item[0] for item in PUBLIC_FIELDS)
METADATA_KEYS = frozenset(
    {"csrf_token", "base_version", "request_id", "confirm_version", "current_password"}
)
UPDATE_KEYS = (
    PUBLIC_KEYS
    | METADATA_KEYS
    | {f"{key}_{suffix}" for key, _ in SECRET_FIELDS for suffix in ("action", "value")}
)


@dataclass(frozen=True)
class ConfigurationForm:
    base_version: int
    request_id: UUID
    public_patch: PublicConfigurationPatch
    secret_changes: dict
    password: str = field(repr=False)


def _error():
    return ApiError("configuration_input_invalid", 422)


def _closed(form, keys):
    if set(form) != keys or any(len(form.getlist(key)) != 1 for key in form):
        raise _error()
    if any(not isinstance(value, str) for _, value in form.multi_items()):
        raise _error()


def version(value: str) -> int:
    if not re.fullmatch(r"0|[1-9][0-9]{0,18}", value) or int(value) > 2**63 - 1:
        raise _error()
    return int(value)


def request_uuid(value: str) -> UUID:
    try:
        parsed = UUID(value)
    except (ValueError, TypeError, AttributeError):
        raise _error() from None
    if str(parsed) != value:
        raise _error()
    return parsed


def parse_update(form, *, require_confirmation=True) -> ConfigurationForm:
    keys = UPDATE_KEYS
    if not require_confirmation and "confirm_version" not in form:
        keys = keys - {"confirm_version"}
    _closed(form, keys)
    base = version(form["base_version"])
    request_id = request_uuid(form["request_id"])
    if require_confirmation and form.get("confirm_version") != str(base):
        raise ApiError("configuration_target_confirmation_required", 422)
    public = {}
    for key, _, kind, _, _ in PUBLIC_FIELDS:
        value = form[key]
        if kind == "bool":
            if value not in {"true", "false"}:
                raise _error()
            public[key] = value == "true"
        elif kind == "int":
            if not re.fullmatch(r"0|[1-9][0-9]{0,12}", value):
                raise _error()
            public[key] = int(value)
        elif kind == "float":
            if not re.fullmatch(r"[0-9]{1,2}(\.[0-9]{1,3})?", value):
                raise _error()
            public[key] = float(value)
        else:
            public[key] = value
    changes = {}
    for key, _ in SECRET_FIELDS:
        action, value = form[f"{key}_action"], form[f"{key}_value"]
        if action not in {"keep", "replace", "delete"}:
            raise _error()
        if action == "replace":
            if not 1 <= len(value) <= 4096 or any(char in value for char in "\x00\r\n"):
                raise _error()
            changes[key] = {"action": action, "value": SecretStr(value)}
        elif value:
            # An unrelated typed value must not be silently accepted as keep or
            # delete. The user explicitly selects replace to publish it.
            raise _error()
        else:
            changes[key] = {"action": action, "value": None}
    try:
        patch = PublicConfigurationPatch.model_validate(public)
    except ValidationError:
        raise _error() from None
    return ConfigurationForm(base, request_id, patch, changes, form["current_password"])
