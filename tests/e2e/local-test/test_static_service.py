"""Ordinary API/admin routes and fixed sealed resources share one ASGI app."""

import json
import logging
import os
import subprocess
import sys
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from flowtrace_server.config import Settings
from flowtrace_server.tools.local_test_service import (
    RuntimeFormatter,
    create_local_test_app,
    load_configuration,
    runtime_lease,
)


def test_private_runtime_log_does_not_format_message_arguments_or_exception():
    secret = "synthetic-private-token-never-log"
    record = logging.LogRecord(
        "uvicorn.error", logging.ERROR, __file__, 1, "%s", (secret,), None
    )
    record.exc_text = secret
    record.stack_info = secret
    line = RuntimeFormatter().format(record)
    assert secret not in line
    assert set(json.loads(line)) == {"timestamp", "level", "event"}
    assert json.loads(line)["event"] == "local_test_service_runtime"


def test_runtime_mode_lease_refuses_second_process_and_releases(tmp_path):
    code = """
import sys
import portalocker
from flowtrace_server.tools.local_test_service import runtime_lease
try:
    with runtime_lease(sys.argv[1], 'serve'):
        print('acquired')
except portalocker.exceptions.LockException:
    print('blocked')
"""

    def attempt():
        result = subprocess.run(
            [sys.executable, "-I", "-c", code, str(tmp_path)],
            capture_output=True,
            check=True,
            text=True,
            timeout=10,
        )
        return result.stdout.strip()

    with runtime_lease(tmp_path, "serve"):
        assert attempt() == "blocked"
        with runtime_lease(tmp_path, "worker"):
            pass
    assert attempt() == "acquired"


def client_for(sealed_web, tmp_path):
    root, manifest = sealed_web
    return TestClient(
        create_local_test_app(
            Settings(
                _env_file=None,
                environment="test",
                database_url=None,
                data_directory=tmp_path / "data",
            ),
            root,
            expected_release_id=manifest["release_id"],
        )
    )


def test_static_mime_scope_and_headers_with_ordinary_health(sealed_web, tmp_path):
    with client_for(sealed_web, tmp_path) as client:
        for path in (
            "/",
            "/index.html",
            "/sqlite3.wasm",
            "/drift_worker.js",
            "/flutter_service_worker.js",
            "/flowtrace-release.json",
            "/health/live",
            "/admin/login",
        ):
            response = client.get(path)
            assert response.status_code == 200
            assert response.headers["cross-origin-opener-policy"] == "same-origin"
            assert response.headers["cross-origin-embedder-policy"] == "require-corp"
            assert response.headers["x-content-type-options"] == "nosniff"
            assert response.headers["cache-control"] == "no-store"
        assert client.get("/sqlite3.wasm").headers["content-type"] == "application/wasm"
        assert (
            client.get("/drift_worker.js")
            .headers["content-type"]
            .startswith("application/javascript")
        )
        assert (
            client.get("/flutter_service_worker.js").headers["service-worker-allowed"]
            == "/"
        )
        assert (
            client.get("/main.dart.js?flowtrace_release=synthetic").content
            == client.get("/main.dart.js").content
        )
        head = client.head("/main.dart.js")
        assert head.status_code == 200 and head.content == b""
        assert int(head.headers["content-length"]) == len(
            client.get("/main.dart.js").content
        )
        assert client.post("/main.dart.js").status_code == 405
        assert client.get("/api/v1/server-info").status_code == 503
        # Ordinary auth dependencies fail closed before body validation when
        # this deliberately disconnected app has no database.
        assert client.post("/api/v1/auth/login", json={}).status_code == 503


@pytest.mark.parametrize(
    "path",
    [
        "/api/v1/missing",
        "/admin/missing",
        "/health/missing",
        "/settings",
        "/assets/missing.wasm",
        "/.env",
        "/private/service.json",
    ],
)
def test_unknown_or_private_path_never_falls_back_to_index(sealed_web, tmp_path, path):
    root, _ = sealed_web
    (root / ".env").write_text("synthetic-private-file-never-public", encoding="utf-8")
    with client_for(sealed_web, tmp_path) as client:
        response = client.get(path)
        assert response.status_code == 404
        assert b"synthetic FlowTrace shell" not in response.content
        assert b"synthetic-private-file" not in response.content
        assert response.headers["cache-control"] == "no-store"


def test_resource_mutation_fails_closed_without_mixing_an_index(sealed_web, tmp_path):
    root, _ = sealed_web
    with client_for(sealed_web, tmp_path) as client:
        assert client.get("/main.dart.js").status_code == 200
        (root / "main.dart.js").write_bytes(b"changed after activation")
        changed = client.get("/main.dart.js")
        assert changed.status_code == 503
        assert changed.json()["error"]["code"] == "web_resource_unavailable"
        assert client.get("/").status_code == 200


@pytest.mark.parametrize("changed", ["resource", "worker", "release-id"])
def test_bad_release_refuses_app_construction(sealed_web, tmp_path, changed):
    root, manifest = sealed_web
    expected = manifest["release_id"]
    if changed == "resource":
        (root / "main.dart.js").write_bytes(b"bad before startup")
    elif changed == "worker":
        (root / "flutter_service_worker.js").write_bytes(b"const RELEASE = {};\n")
    else:
        expected = "0" * 64
    with pytest.raises(ValueError):
        create_local_test_app(
            Settings(
                _env_file=None, database_url=None, data_directory=tmp_path / "data"
            ),
            root,
            expected_release_id=expected,
        )


@pytest.mark.parametrize(
    "unsafe",
    [
        "hostaddr",
        "service",
        "options",
        "external-host",
        "production-environment",
        "production-database",
        "production-role",
        "old-database-port",
        "mismatched-port",
        "invalid-http-port",
        "same-port",
    ],
)
def test_private_configuration_overrides_inherited_database_and_rejects_unsafe_without_connecting(
    tmp_path, monkeypatch, unsafe
):
    root = tmp_path / "new-instance"
    (root / "private").mkdir(parents=True)
    version = root / "versions" / "synthetic"
    version.mkdir(parents=True)
    service_id = str(uuid4())
    short_id = service_id.replace("-", "")[:16]
    role = "flowtrace_service_" + short_id
    database = "flowtrace_local_" + short_id
    (root / "service-owner.json").write_text(
        json.dumps({"service_id": service_id}), encoding="utf-8"
    )
    config = {
        "format": "flowtrace-local-test-service-v1",
        "root": str(root),
        "service_id": service_id,
        "host": "127.0.0.1",
        "http_port": 18889,
        "database_port": 55441,
        "version_directory": str(version),
        "postgresql": {
            "database": database,
            "role": role,
        },
        "settings": {
            "environment": "test",
            "data_directory": str(root / "data"),
            "database_url": f"postgresql+psycopg://{role}:synthetic@127.0.0.1:55441/{database}",
            "pg_dump_executable": str(version / "postgresql/bin/pg_dump.exe"),
        },
    }
    path = root / "private/service.json"
    path.write_text(json.dumps(config), encoding="utf-8")
    monkeypatch.setenv(
        "FLOWTRACE_DATABASE_URL", "postgresql+psycopg://old:old@127.0.0.1:55432/old"
    )
    monkeypatch.setenv(
        "FLOWTRACE_PROVIDER_ENDPOINTS", '{"ai_primary":"https://old.invalid"}'
    )
    _, settings = load_configuration(path)
    assert ":55441/" in settings.database_url.get_secret_value()
    assert not settings.provider_endpoints
    assert ":55432/old" in os.environ["FLOWTRACE_DATABASE_URL"]
    url = config["settings"]["database_url"]
    if unsafe == "hostaddr":
        url += "?hostaddr=198.51.100.12"
    elif unsafe == "service":
        url += "?service=production"
    elif unsafe == "options":
        url += "?options=-c%20search_path%3Dproduction"
    elif unsafe == "external-host":
        url = url.replace("127.0.0.1", "198.51.100.12")
    elif unsafe == "production-environment":
        config["settings"]["environment"] = "production"
    elif unsafe == "production-database":
        url = url.replace(database, "production")
        config["postgresql"]["database"] = "production"
    elif unsafe == "production-role":
        url = url.replace(role, "production")
        config["postgresql"]["role"] = "production"
    elif unsafe == "old-database-port":
        url = url.replace(":55441/", ":55432/")
        config["database_port"] = 55432
    elif unsafe == "mismatched-port":
        url = url.replace(":55441/", ":55442/")
    elif unsafe == "invalid-http-port":
        config["http_port"] = -1
    else:
        config["http_port"] = config["database_port"]
    config["settings"]["database_url"] = url
    path.write_text(json.dumps(config), encoding="utf-8")
    with pytest.raises(ValueError, match="(?:database|settings)_boundary"):
        load_configuration(path)
