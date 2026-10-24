"""A business parse failure has a safe event despite its valid HTTP 200 response."""

import json

import pytest
from fastapi.testclient import TestClient
from sync.helpers import actor

from flowtrace_server.config import Settings
from flowtrace_server.main import create_app

pytestmark = pytest.mark.postgres


@pytest.mark.parametrize("include_diagnostics", [False, True])
def test_parse_failure_correlates_private_logs_and_preserves_legacy_response(
    postgres_engine, tmp_path, include_diagnostics
):
    owner = actor(postgres_engine)
    app = create_app(
        Settings(
            _env_file=None,
            environment="test",
            data_directory=tmp_path,
            database_url=postgres_engine.url.render_as_string(hide_password=False),
            diagnostics_enabled=True,
        )
    )
    app.state.engine = postgres_engine
    options = {"template_mapping": {"scope_id": str(owner.book_id), "timezone": "Asia/Shanghai"}}
    if include_diagnostics:
        options["include_diagnostics"] = True
    with TestClient(app) as client:
        response = client.post(
            "/api/v1/data-tools/imports/parse",
            headers={"Authorization": "Bearer " + owner.token},
            data={"format": "qianji_csv", "options": json.dumps(options)},
            files={
                "file": (
                    "PRIVATE_FILENAME.csv",
                    b"PRIVATE_COLUMN\nPRIVATE_BILL_NOTE_87654321.98\n",
                    "text/csv",
                )
            },
        )
        assert response.status_code == 200
        body = response.json()
        assert body["document"] is None
        assert body["errors"] == [{"row": 1, "field": None, "code": "unsupported_qianji_columns"}]
        if include_diagnostics:
            assert body["request_id"] == response.headers["x-request-id"]
        else:
            assert "request_id" not in body
        rows = [
            json.loads(line)
            for path in (tmp_path / "diagnostics").glob("flowtrace-*.jsonl")
            for line in path.read_bytes().splitlines()
        ]
        parse = [item for item in rows if item["event"] == "import_parse_checked"]
        assert len(parse) == 1
        assert parse[0]["request_id"] == response.headers["x-request-id"]
        assert parse[0]["code"] == "unsupported_qianji_columns" and parse[0]["row"] == 1
        http = [item for item in rows if item["event"] == "http_request"]
        assert http[-1]["route"] == "/api/v1/data-tools/imports/parse"
        assert http[-1]["status_code"] == 200
        rendered = json.dumps(rows)
        for private in [
            "PRIVATE_FILENAME",
            "PRIVATE_COLUMN",
            "PRIVATE_BILL_NOTE",
            "87654321.98",
            owner.token,
        ]:
            assert private not in rendered
