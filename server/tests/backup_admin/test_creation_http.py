import re
from uuid import uuid4

from admin.conftest import ORIGIN, PASSWORD, login
from admin.conftest import admin_system as admin_system
from admin.test_management import add_user
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.jobs.models import BackgroundJob


def configure_tool(client, tmp_path):
    # This fixture tests trusted registration and enqueue only. The production
    # worker/pg_dump integration has separate real-process tests and browser QA.
    tool = tmp_path / "tool-registration-fixture"
    tool.write_bytes(b"not-executed-by-http-tests")
    client.app.state.settings = client.app.state.settings.model_copy(
        update={"pg_dump_executable": tool}
    )


def form(page, csrf):
    return {
        "csrf_token": csrf,
        "current_password": PASSWORD,
        **{
            key: re.search(rf'name="{key}" value="([^"]+)"', page.text).group(1)
            for key in ("request_id", "expected_epoch", "confirm_target")
        },
    }


def test_creation_html_requires_tool_and_never_accepts_paths(admin_system, tmp_path):
    client, connection, owner = admin_system
    csrf = login(client)
    assert client.get("/admin/backups/create").status_code == 503
    assert 'href="/admin/backups/create"' not in client.get("/admin/backups").text
    configure_tool(client, tmp_path)
    page = client.get("/admin/backups/create")
    assert page.status_code == 200 and "短暂进入维护窗口" in page.text
    data = form(page, csrf)
    for patch, status in (
        ({"csrf_token": "incorrect"}, 403),
        ({"confirm_target": str(uuid4())}, 403),
        ({"expected_epoch": str(uuid4())}, 409),
        ({"current_password": "incorrect-current-password"}, 403),
        ({"output_path": "C:/private"}, 422),
        ({"command": "pg_dump --anything"}, 422),
    ):
        denied = client.post("/admin/backups/create", data={**data, **patch}, headers=ORIGIN)
        assert denied.status_code == status
        assert "incorrect-current-password" not in denied.text
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert session.scalar(select(func.count()).select_from(BackgroundJob).where(
            BackgroundJob.owner_user_id == owner
        )) == 0


def test_creation_html_same_request_has_one_pending_job_and_audit(admin_system, tmp_path):
    client, connection, owner = admin_system
    configure_tool(client, tmp_path)
    csrf = login(client)
    data = form(client.get("/admin/backups/create"), csrf)
    responses = [
        client.post("/admin/backups/create", data=data, headers=ORIGIN, follow_redirects=False)
        for _ in range(2)
    ]
    assert all(response.status_code == 303 for response in responses)
    assert responses[0].headers["location"] == responses[1].headers["location"]
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        job = session.scalar(select(BackgroundJob).where(BackgroundJob.owner_user_id == owner))
        assert job.kind == "backup_create" and job.status == "pending"
        assert set(job.payload) == {"backup_id"}
        assert session.scalar(select(func.count()).select_from(BackgroundJob).where(
            BackgroundJob.owner_user_id == owner
        )) == 1
        assert (
            session.scalar(
                select(func.count())
                .select_from(AdminAudit)
                .where(
                    AdminAudit.action == "job.backup_create_enqueue",
                    AdminAudit.actor_id == owner,
                )
            )
            == 1
        )


def test_creation_html_is_recovery_only_even_for_owner_role(admin_system, tmp_path):
    client, connection, _ = admin_system
    configure_tool(client, tmp_path)
    owner_csrf = login(client)
    data = form(client.get("/admin/backups/create"), owner_csrf)
    for username, roles in (
        ("creation_service", ["service_admin"]),
        ("creation_owner_only", ["server_owner"]),
    ):
        add_user(connection, username, roles)
        csrf = login(client, username)
        assert client.get("/admin/backups/create").status_code == 403
        assert 'href="/admin/backups/create"' not in client.get("/admin/backups").text
        assert (
            client.post(
                "/admin/backups/create", data={**data, "csrf_token": csrf}, headers=ORIGIN
            ).status_code
            == 403
        )
    add_user(connection, "creation_recovery_only", ["recovery_admin"])
    csrf = login(client, "creation_recovery_only")
    assert client.get("/admin/backups/create").status_code == 200
    assert (
        client.post(
            "/admin/backups/create", data={**data, "csrf_token": csrf}, headers=ORIGIN
        ).status_code
        == 200
    )
    assert client.get("/admin/configuration").status_code == 403
