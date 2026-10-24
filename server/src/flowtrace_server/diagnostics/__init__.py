"""Bounded structured diagnostics; callers cannot emit request bodies or exceptions."""

import json
import logging
import math
import threading
from contextvars import ContextVar
from datetime import UTC, datetime
from pathlib import Path
from uuid import UUID

from .import_codes import IMPORT_CODES, IMPORT_FIELDS, IMPORT_FORMATS
from .policy import DiagnosticPolicy, collect
from .store import DiagnosticStore as DiagnosticStore

request_id_context: ContextVar[str | None] = ContextVar("request_id", default=None)
LOGGER = logging.getLogger("flowtrace")
_configuration_lock = threading.Lock()
SAFE_ROUTES = {"unmatched"}
EVENTS = {
    "safe",
    "http_request",
    "request_failed",
    "sync_commit",
    "sync_replay",
    "sync_conflict",
    "attachment_staged",
    "attachment_completed",
    "attachment_gc",
    "diagnostic_export",
    "import_parse_checked",
}
CODES = {
    "internal_error",
    "hash_mismatch",
    "size_mismatch",
    "image_invalid",
    "image_format",
    "image_dimensions",
    "image_animated",
    "image_capacity",
    "upload_mismatch",
    "upload_expired",
    "attachment_storage_unavailable",
    "diagnostic_unavailable",
} | IMPORT_CODES


def register_routes(routes) -> None:
    """Only application-defined route templates, never request URLs."""

    # Locked FastAPI versions may include routers lazily. Their original paths
    # plus the declared include prefix remain code-defined templates.
    def walk(values, prefix="", ancestors=frozenset()):
        for route in values:
            path = getattr(route, "path", None)
            if isinstance(path, str):
                SAFE_ROUTES.add(prefix + path)
            nested = getattr(route, "original_router", None)
            if nested is not None and id(nested) not in ancestors:
                context = getattr(route, "include_context", None)
                extra = getattr(context, "prefix", "")
                if isinstance(extra, str):
                    walk(nested.routes, prefix + extra, ancestors | {id(nested)})

    walk(routes)


def safe_payload(fields: dict, timestamp: datetime | None = None) -> dict:
    payload = {
        "timestamp": (timestamp or datetime.now(UTC)).astimezone(UTC).isoformat(),
        "service": "flowtrace-api",
    }
    if not isinstance(fields.get("event"), str) or fields["event"] not in EVENTS:
        return {**payload, "event": "record_omitted"}
    payload["event"] = fields["event"]
    for key in ("request_id", "operation_id", "scope_id", "entity_id", "stage_id"):
        try:
            payload[key] = str(UUID(str(fields.get(key))))
        except (ValueError, TypeError, AttributeError):
            pass
    if isinstance(fields.get("method"), str) and fields["method"] in {
        "GET",
        "HEAD",
        "OPTIONS",
        "POST",
        "PUT",
        "PATCH",
        "DELETE",
    }:
        payload["method"] = fields["method"]
    route = fields.get("route")
    if isinstance(route, str) and len(route) <= 160 and route in SAFE_ROUTES:
        payload["route"] = route
    if isinstance(fields.get("code"), str) and fields["code"] in CODES:
        payload["code"] = fields["code"]
    for key, upper in (
        ("status_code", 599),
        ("size_bytes", 10 * 1024 * 1024),
        ("count", 1_000_000),
        ("error_count", 1_000_000),
        ("row", 200_001),
    ):
        value = fields.get(key)
        if type(value) is int and 0 <= value <= upper:
            payload[key] = value
    if fields.get("event") == "import_parse_checked":
        if isinstance(fields.get("format"), str) and fields["format"] in IMPORT_FORMATS:
            payload["format"] = fields["format"]
        if isinstance(fields.get("field"), str) and fields["field"] in IMPORT_FIELDS:
            payload["field"] = fields["field"]
    value = fields.get("duration_ms")
    if type(value) in {int, float} and math.isfinite(value) and 0 <= value <= 3_600_000:
        payload["duration_ms"] = round(value, 3)
    return payload


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = safe_payload(getattr(record, "safe_fields", {}))
        payload["level"] = (
            record.levelname
            if record.levelname in {"INFO", "WARNING", "ERROR", "DEBUG"}
            else "INFO"
        )
        return json.dumps(payload, separators=(",", ":"), ensure_ascii=True)


class StoreHandler(logging.Handler):
    def __init__(self):
        super().__init__()
        # This router owns no mutable target state. Per-policy/store locks
        # serialize their own files; a global handler lock would let one app's
        # slow policy probe block unrelated applications' collection.
        self.lock = None

    def emit(self, record: logging.LogRecord) -> None:
        collect(safe_payload(getattr(record, "safe_fields", {})), level=record.levelno)


def configure_logging(level: str, directory: Path | None = None, *, runtime_reader=None):
    """Configure process stderr and one context router; never bind a global app.

    An optional directory returns an unbound policy. Legacy test/CLI callers
    must explicitly provide a trusted reader and bind that returned policy.
    """
    with _configuration_lock:
        handler = next((h for h in LOGGER.handlers if getattr(h, "_flowtrace", False)), None)
        if handler is None:
            handler = logging.StreamHandler()
            handler.setFormatter(JsonFormatter())
            handler._flowtrace = True
            LOGGER.addHandler(handler)
        handler.setLevel(level)
        if not any(isinstance(h, StoreHandler) for h in LOGGER.handlers):
            LOGGER.addHandler(StoreHandler())
        # Each policy applies its own threshold; another application's level
        # cannot prevent this application's events from reaching its router.
        LOGGER.setLevel(logging.DEBUG)
        LOGGER.propagate = False
    return (
        DiagnosticPolicy(
            directory, os_enabled=True, runtime_reader=runtime_reader, minimum_level=level
        )
        if directory is not None
        else None
    )


def event(name: str, **fields: object) -> None:
    safe = {"event": name, "request_id": request_id_context.get(), **fields}
    try:
        LOGGER.info("", extra={"safe_fields": safe})
    except Exception:
        # Diagnostics are not a business receipt. Logging failure must not retry a committed write.
        pass
