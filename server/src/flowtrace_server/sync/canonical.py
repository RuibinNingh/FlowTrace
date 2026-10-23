"""Restricted, exact JSON hashing for immutable operation receipts (protocol v1)."""

import hashlib
import json
from typing import Any


class InvalidSyncBody(ValueError):
    """Safe protocol error, containing no input or secrets."""


def _pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise InvalidSyncBody("duplicate_json_key")
        result[key] = value
    return result


def _invalid_number(_: str) -> None:
    raise InvalidSyncBody("non_integer_json_number")


def _control_integer(value: str) -> int:
    # Reject -0 before json.loads erases its sign and bound work before int().
    if value.startswith("-") or len(value) > 10:
        raise InvalidSyncBody("invalid_control_integer")
    integer = int(value)
    if integer > 2**31 - 1:
        raise InvalidSyncBody("invalid_control_integer")
    return integer


def validate_value(value: Any, depth: int = 0) -> None:
    if depth > 32:
        raise InvalidSyncBody("json_too_deep")
    if value is None or isinstance(value, bool):
        return
    if isinstance(value, str):
        # PostgreSQL JSONB/text cannot store U+0000. Reject it before hashing or
        # starting a transaction rather than turning valid-looking input into 503.
        if "\x00" in value:
            raise InvalidSyncBody("unsupported_unicode")
        try:
            value.encode("utf-8", errors="strict")
        except UnicodeError:
            raise InvalidSyncBody("invalid_unicode") from None
        return
    if type(value) is int and 0 <= value <= 2**31 - 1:
        return
    if isinstance(value, list):
        for item in value:
            validate_value(item, depth + 1)
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str) or not key or not key.isascii():
                raise InvalidSyncBody("invalid_json_key")
            validate_value(item, depth + 1)
        return
    raise InvalidSyncBody("invalid_json_value")


def decode_body(raw: bytes, limit: int = 1024 * 1024) -> dict[str, Any]:
    if len(raw) > limit:
        raise InvalidSyncBody("payload_too_large")
    try:
        value = json.loads(
            raw.decode("utf-8", errors="strict"),
            object_pairs_hook=_pairs,
            parse_int=_control_integer,
            parse_float=_invalid_number,
            parse_constant=_invalid_number,
        )
    except InvalidSyncBody:
        raise
    except (ValueError, UnicodeError, RecursionError):
        raise InvalidSyncBody("invalid_json") from None
    if not isinstance(value, dict):
        raise InvalidSyncBody("json_object_required")
    validate_value(value)
    return value


def canonical_bytes(value: Any) -> bytes:
    validate_value(value)
    return json.dumps(
        value, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def content_hash(value: Any) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def operation_hash(protocol_version: int, epoch: str, operation: dict[str, Any]) -> str:
    return content_hash(
        {"protocol_version": protocol_version, "sync_epoch": epoch, "operation": operation}
    )
