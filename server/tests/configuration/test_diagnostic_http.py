import asyncio
import json
import threading
from time import monotonic
from uuid import uuid4

import httpx
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from flowtrace_server.config import Settings
from flowtrace_server.diagnostics.policy import DiagnosticPolicy
from flowtrace_server.main import create_app

from .conftest import committed_config_actor as committed_config_actor
from .test_diagnostic_collection import settings_for
from .test_service import command, save


def records(directory):
    return [
        json.loads(line)
        for path in directory.glob("flowtrace-*.jsonl")
        for line in path.read_bytes().splitlines()
    ]


def test_real_http_apps_read_committed_switch_and_keep_their_own_directory(
    postgres_engine, tmp_path, committed_config_actor
):
    principal, requests, base = committed_config_actor
    settings_a = settings_for(postgres_engine, tmp_path)
    settings_b = settings_for(postgres_engine, tmp_path)
    settings_off = settings_for(postgres_engine, tmp_path).model_copy(
        update={"diagnostics_enabled": False}
    )
    app_a, app_b, app_off = [create_app(s) for s in (settings_a, settings_b, settings_off)]
    directory_a = settings_a.data_directory / "diagnostics"
    directory_b = settings_b.data_directory / "diagnostics"
    with TestClient(app_b) as second, TestClient(app_off) as disabled:
        with TestClient(app_a) as first:
            assert first.get("/health/live").status_code == 200
            assert len(records(directory_a)) == 1
            assert not directory_b.exists()
            assert second.get("/health/live").status_code == 200
            assert len(records(directory_b)) == 1
            request = command(base, diagnostics_enabled=False)
            requests.append(request.request_id)
            with Session(postgres_engine) as session, session.begin():
                save(session, principal, request)
            assert first.get("/health/live").status_code == 200
            assert second.get("/health/live").status_code == 200
            assert len(records(directory_a)) == len(records(directory_b)) == 1
            request = command(base + 1, diagnostics_enabled=True)
            requests.append(request.request_id)
            with Session(postgres_engine) as session, session.begin():
                save(session, principal, request)
            assert first.get("/health/live").status_code == 200
            assert len(records(directory_a)) == 2
        # Closing one application disposes only that application's probe.
        assert second.get("/health/live").status_code == 200
        assert len(records(directory_b)) == 2
        assert disabled.get("/health/live").status_code == 200
        assert not (settings_off.data_directory / "diagnostics").exists()
    assert all(record["event"] == "http_request" for record in records(directory_a))


def test_async_http_diagnostic_probe_runs_outside_the_event_loop(tmp_path):
    entered = threading.Event()
    release = threading.Event()

    def reader():
        entered.set()
        release.wait(2)
        return True

    app = create_app(Settings(_env_file=None, data_directory=tmp_path / str(uuid4())))
    app.state.diagnostic_policy.close()
    app.state.diagnostic_policy = DiagnosticPolicy(
        tmp_path / str(uuid4()), os_enabled=True, runtime_reader=reader
    )

    async def exercise():
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://testserver"
        ) as client:
            request = asyncio.create_task(client.get("/health/live"))
            try:
                started = monotonic()
                while not entered.is_set() and monotonic() - started < 1:
                    await asyncio.sleep(0.01)
                assert entered.is_set()
                await asyncio.sleep(0.02)
                assert monotonic() - started < 1
                assert not request.done()
            finally:
                release.set()
                response = await request
            assert response.status_code == 200

    try:
        asyncio.run(exercise())
    finally:
        release.set()
        app.state.diagnostic_policy.close()
