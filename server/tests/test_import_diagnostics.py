"""Privacy and correlation at the import diagnostics boundary."""

from uuid import uuid4

import pytest
from pydantic import ValidationError

from flowtrace_server.config import Settings
from flowtrace_server.diagnostics import SAFE_ROUTES, safe_payload
from flowtrace_server.imports.http_schemas import ParseOptions
from flowtrace_server.main import create_app


def test_import_metadata_is_fixed_and_rejects_private_or_malformed_fields():
    request, stage = str(uuid4()), str(uuid4())
    record = safe_payload(
        {
            "event": "import_parse_checked",
            "request_id": request,
            "stage_id": stage,
            "format": "qianji_xlsx",
            "code": "unsupported_qianji_columns",
            "row": 1,
            "field": "关联账单",
            "count": 105,
            "error_count": 1,
            "filename": "DO_NOT_LOG.xlsx",
            "body": "PRIVATE_BILL_NOTE",
            "amount": "87654321.98",
            "password": "PRIVATE_PASSWORD",
        }
    )
    assert record["code"] == "unsupported_qianji_columns"
    assert record["request_id"] == request and record["stage_id"] == stage
    assert record["row"] == 1 and record["count"] == 105 and record["error_count"] == 1
    assert set(record) == {
        "timestamp",
        "service",
        "event",
        "request_id",
        "stage_id",
        "format",
        "code",
        "row",
        "field",
        "count",
        "error_count",
    }
    invalid = safe_payload(
        {
            "event": "import_parse_checked",
            "format": "PRIVATE_ACCOUNT_NAME",
            "field": "PRIVATE_NOTE",
            "code": "PRIVATE_ERROR",
            "row": True,
            "error_count": -1,
            "stage_id": "PRIVATE_SESSION_TOKEN",
        }
    )
    assert set(invalid) == {"timestamp", "service", "event"}


def test_lazy_included_routes_are_registered_as_templates_only():
    app = create_app(Settings(_env_file=None, environment="test", diagnostics_enabled=False))
    paths = set(app.openapi()["paths"])
    assert paths <= SAFE_ROUTES
    assert "/api/v1/data-tools/imports/parse" in SAFE_ROUTES
    assert "/api/v1/data-tools/import-stages/{stage_id}/rows" in SAFE_ROUTES
    assert "route" not in safe_payload(
        {
            "event": "http_request",
            "route": "/api/v1/data-tools/imports/parse?password=PRIVATE",
        }
    )


def test_diagnostic_request_opt_in_is_strict_and_disabled_for_legacy_clients():
    assert ParseOptions().include_diagnostics is False
    assert ParseOptions(include_diagnostics=True).include_diagnostics is True
    with pytest.raises(ValidationError):
        ParseOptions(include_diagnostics="true")
