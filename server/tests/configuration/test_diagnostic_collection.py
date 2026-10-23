import re
from time import monotonic
from uuid import uuid4

from admin.conftest import ORIGIN, login
from fastapi.testclient import TestClient
from sqlalchemy import select, text
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.auth.models import User
from flowtrace_server.config import Settings
from flowtrace_server.diagnostics.policy import bind_diagnostics, build_diagnostic_policy, collect
from flowtrace_server.main import create_app
from flowtrace_server.persistence.maintenance import MAINTENANCE_KEY

from .conftest import PASSWORD
from .conftest import committed_config_actor as committed_config_actor
from .test_forms import form_values
from .test_service import command, save


def settings_for(postgres_engine, tmp_path):
    return Settings(
        _env_file=None,
        environment="test",
        database_url=postgres_engine.url.render_as_string(hide_password=False),
        data_directory=tmp_path / str(uuid4()),
    )


def test_committed_disable_stops_next_private_event_but_preserves_formal_configuration_audit(
    postgres_engine, tmp_path, committed_config_actor
):
    principal, requests, base = committed_config_actor
    policy = build_diagnostic_policy(settings_for(postgres_engine, tmp_path))
    try:
        with bind_diagnostics(policy):
            assert collect({"event": "safe"})
            before = {p.name: p.read_bytes() for p in policy.directory.glob("*.jsonl")}
            request = command(base, diagnostics_enabled=False)
            requests.append(request.request_id)
            with Session(postgres_engine) as session, session.begin():
                outcome = save(session, principal, request)
            assert outcome.version == base + 1
            assert not collect({"event": "safe"})
            assert before == {p.name: p.read_bytes() for p in policy.directory.glob("*.jsonl")}
            with Session(postgres_engine) as session:
                audit = session.scalar(
                    select(AdminAudit).where(
                        AdminAudit.target_id == request.request_id,
                        AdminAudit.action == "configuration.update",
                    )
                )
                assert audit is not None and audit.summary == {
                    "version": base + 1,
                    "base_version": base,
                }
            enabled = command(base + 1, diagnostics_enabled=True)
            requests.append(enabled.request_id)
            with Session(postgres_engine) as session, session.begin():
                save(session, principal, enabled)
            assert collect({"event": "safe"})
    finally:
        policy.close()


def test_runtime_mvcc_probe_does_not_wait_for_own_head_row_or_maintenance_fence(
    postgres_engine, tmp_path
):
    policy = build_diagnostic_policy(settings_for(postgres_engine, tmp_path))
    try:
        assert policy.enabled()
        with postgres_engine.begin() as connection:
            connection.execute(text("SET LOCAL lock_timeout='250ms'"))
            connection.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": MAINTENANCE_KEY})
            connection.execute(
                text(
                    "UPDATE service_configuration SET public_values="
                    "jsonb_set(public_values,'{diagnostics_enabled}','false'::jsonb) WHERE id=1"
                )
            )
            stamp = monotonic()
            assert policy.enabled()  # Last committed true; uncommitted false is invisible.
            assert monotonic() - stamp < 1
            connection.rollback()
    finally:
        policy.close()


def test_schema_lock_probe_fails_closed_with_short_budget_without_aborting_business(
    postgres_engine, tmp_path
):
    policy = build_diagnostic_policy(settings_for(postgres_engine, tmp_path))
    try:
        with postgres_engine.begin() as connection:
            connection.execute(text("LOCK TABLE service_configuration IN ACCESS EXCLUSIVE MODE"))
            stamp = monotonic()
            assert not policy.enabled()
            assert monotonic() - stamp < 1
            assert connection.execute(text("SELECT 1")).scalar_one() == 1
            connection.rollback()
        assert policy.enabled()
    finally:
        policy.close()


def test_real_http_config_commit_switches_collection_and_export_with_os_hard_off(
    postgres_engine, tmp_path, committed_config_actor
):
    principal, requests, base = committed_config_actor
    settings = settings_for(postgres_engine, tmp_path)
    with Session(postgres_engine) as session:
        username = session.get(User, principal.user_id).username

    def bytes_in(directory):
        return {p.name: p.read_bytes() for p in directory.glob("*.jsonl")}

    app = create_app(settings)
    with TestClient(app) as client:
        token = login(client, username, password=PASSWORD)
        assert client.get("/health/live").status_code == 200
        assert client.get("/admin/diagnostics/export").status_code == 200
        directory = settings.data_directory / "diagnostics"
        assert bytes_in(directory)

        def publish(enabled, version):
            page = client.get("/admin/configuration")
            assert page.status_code == 200
            request_id = re.search(r'name="request_id" value="([^"]+)"', page.text).group(1)
            from uuid import UUID

            requests.append(UUID(request_id))
            values = {
                **form_values(),
                "csrf_token": token,
                "current_password": PASSWORD,
                "base_version": str(version),
                "confirm_version": str(version),
                "request_id": request_id,
                "diagnostics_enabled": str(enabled).lower(),
            }
            before = bytes_in(directory)
            response = client.post(
                "/admin/configuration", data=values, headers=ORIGIN, follow_redirects=False
            )
            assert response.status_code == 303
            with Session(postgres_engine) as session:
                audit = session.scalar(
                    select(AdminAudit).where(
                        AdminAudit.action == "configuration.update",
                        AdminAudit.target_id == UUID(request_id),
                    )
                )
                assert audit is not None and audit.summary["version"] == version + 1
            return before

        before = publish(False, base)
        assert bytes_in(directory) == before  # Even the successful POST's final diagnostic is off.
        assert client.get("/health/live").status_code == 200
        assert client.get("/admin/diagnostics/export").status_code == 503
        assert bytes_in(directory) == before
        publish(True, base + 1)
        assert client.get("/health/live").status_code == 200
        assert client.get("/admin/diagnostics/export").status_code == 200
        assert bytes_in(directory) != before

        off = settings.model_copy(
            update={"diagnostics_enabled": False, "data_directory": tmp_path / str(uuid4())}
        )
        with TestClient(create_app(off)) as os_client:
            login(os_client, username, password=PASSWORD)
            assert os_client.get("/health/live").status_code == 200
            assert os_client.get("/admin/diagnostics/export").status_code == 503
            assert not (off.data_directory / "diagnostics").exists()
        # Closing another app must not close this app's reader or destination.
        assert client.get("/admin/diagnostics/export").status_code == 200


def test_real_live_http_stays_successful_when_policy_probe_cannot_read_schema(
    postgres_engine, tmp_path
):
    app = create_app(settings_for(postgres_engine, tmp_path))
    with TestClient(app) as client, postgres_engine.begin() as connection:
        connection.execute(text("LOCK TABLE service_configuration IN ACCESS EXCLUSIVE MODE"))
        result = client.get("/health/live")
        assert result.status_code == 200 and result.json() == {"status": "ok"}
        assert connection.execute(text("SELECT 1")).scalar_one() == 1
        connection.rollback()
