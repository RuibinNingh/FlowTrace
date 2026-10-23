import io
import json
import logging
from importlib.resources import files
from uuid import UUID

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from flowtrace_server.config import Settings
from flowtrace_server.diagnostics import JsonFormatter
from flowtrace_server.main import create_app
from flowtrace_server.persistence.testing import require_isolated_database


def settings(**kwargs):
    return Settings(_env_file=None, database_url=None, **kwargs)


@pytest.mark.parametrize(
    "origin,extra_header,accepted",
    [
        ("https://client.example", "x-chunk-sha256", True),
        ("https://client.example", "x-admin-role", False),
        ("https://unconfigured.example", "x-chunk-sha256", False),
    ],
)
def test_chunk_upload_preflight_uses_explicit_origin_and_hash_header(
    origin, extra_header, accepted
):
    with TestClient(create_app(settings(cors_origins=["https://client.example"]))) as client:
        response = client.options(
            "/api/v1/data-tools/import-stages/00000000-0000-4000-8000-000000000001/"
            "chunks/0?stage_version=1",
            headers={
                "origin": origin,
                "access-control-request-method": "PUT",
                "access-control-request-headers": "authorization,content-type," + extra_header,
            },
        )
    assert response.status_code == (200 if accepted else 400)
    if accepted:
        assert response.headers["access-control-allow-origin"] == origin
        assert "x-chunk-sha256" in response.headers["access-control-allow-headers"].lower()


def test_health_and_missing_database_are_distinct():
    with TestClient(create_app(settings())) as client:
        response = client.get("/health/live")
        assert response.json() == {"status": "ok"}
        UUID(response.headers["x-request-id"])
        assert response.headers["cache-control"] == "no-store"
        ready = client.get("/health/ready")
        assert ready.status_code == 503
        assert ready.json()["error"]["code"] == "service_unavailable"
        assert ready.json()["error"]["request_id"] == ready.headers["x-request-id"]
        assert client.get("/api/v1/server-info").status_code == 503


def test_unknown_route_returns_safe_not_found():
    app = create_app(settings())
    assert set(app.openapi()["paths"]).issuperset(
        {"/health/live", "/health/ready", "/api/v1/server-info"}
    )
    with TestClient(app) as client:
        response = client.post("/api/v1/unimplemented-probe", json={"password": "sensitive-body"})
        assert response.status_code == 404
        assert "sensitive-body" not in response.text


def test_unexpected_error_redacts_body_and_exception():
    app = create_app(settings())

    @app.get("/test-crash")
    def crash():
        raise RuntimeError("database_password_and_private_bill")

    with TestClient(app) as client:
        response = client.get("/test-crash")
        assert response.status_code == 500
        assert response.json()["error"]["code"] == "internal_error"
        assert "database_password" not in response.text


def test_validation_does_not_echo_secret():
    app = create_app(settings())

    @app.get("/test-query")
    def needs_integer(number: int):
        return {"value": number}

    with TestClient(app) as client:
        response = client.get("/test-query", params={"number": "password-in-invalid-query"})
        assert response.status_code == 422
        assert "password-in-invalid-query" not in response.text


def test_formatter_uses_whitelist_and_never_formats_exception():
    output = io.StringIO()
    handler = logging.StreamHandler(output)
    handler.setFormatter(JsonFormatter())
    record = logging.LogRecord("test", logging.ERROR, "", 0, "secret-message", (), None)
    record.safe_fields = {"event": "safe", "request_id": "safe-id", "password": "secret"}
    handler.handle(record)
    data = json.loads(output.getvalue())
    assert data["event"] == "safe"
    assert "secret" not in output.getvalue()


def test_database_configuration_is_secret_and_postgres_only():
    password = "sensitive-config-value"
    value = Settings(
        _env_file=None, database_url=f"postgresql+psycopg://user:{password}@localhost/db"
    )
    assert password not in repr(value)
    with pytest.raises(ValidationError) as error:
        Settings(_env_file=None, database_url="sqlite:///private.db")
    assert "private.db" not in str(error.value)


def test_unreachable_database_returns_safe_503():
    value = Settings(
        _env_file=None,
        database_url="postgresql+psycopg://user:never-echo-this@127.0.0.1:1/flowtrace_test_down",
        database_connect_timeout=1,
    )
    with TestClient(create_app(value)) as client:
        response = client.get("/health/ready")
        assert response.status_code == 503
        assert "never-echo-this" not in response.text
        assert response.json()["error"]["code"] == "service_unavailable"


@pytest.mark.parametrize(
    "url,environment",
    [
        ("postgresql+psycopg://localhost/flowtrace", "test"),
        ("postgresql+psycopg://remote/flowtrace_test_demo", "test"),
        ("postgresql+psycopg://localhost/flowtrace_test_demo", "production"),
        ("sqlite:///flowtrace_test_demo", "test"),
    ],
)
def test_guard_refuses_unsafe_database(url, environment):
    with pytest.raises(ValueError, match="isolated_test_database_required"):
        require_isolated_database(url, environment)


def test_guard_accepts_explicit_local_test_database():
    result = require_isolated_database("postgresql+psycopg://localhost/flowtrace_test_demo", "test")
    assert result.database == "flowtrace_test_demo"


def test_admin_resources_present():
    assert files("flowtrace_server.admin").joinpath("templates/base.html").is_file()


def test_openapi_declares_current_closed_responses_and_safe_validation_errors():
    schema = create_app(settings()).openapi()
    login = schema["paths"]["/api/v1/auth/login"]["post"]["responses"]
    assert login["200"]["content"]["application/json"]["schema"] == {
        "$ref": "#/components/schemas/LoginTokens"
    }
    assert login["422"]["content"]["application/json"]["schema"] == {
        "$ref": "#/components/schemas/ErrorResponse"
    }
    assert schema["components"]["schemas"]["LoginTokens"]["additionalProperties"] is False
