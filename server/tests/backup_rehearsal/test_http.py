import re
from uuid import uuid4

import pytest
from admin.conftest import ORIGIN, PASSWORD, login
from admin.conftest import admin_system as admin_system
from admin.test_management import add_user
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from flowtrace_server.backups import rehearsal
from flowtrace_server.jobs.models import BackgroundJob

from .test_boundaries import isolated_definition as isolated_definition


@pytest.fixture
def restore_http(admin_system, isolated_definition, monkeypatch):
    client, connection, owner = admin_system
    settings, target_id, _ = isolated_definition
    client.app.state.settings = settings
    monkeypatch.setattr(rehearsal, "_verified_manifest", lambda *args, **kwargs: ({}, "a" * 64))
    monkeypatch.setattr(rehearsal, "_probe_empty", lambda *args: ("b" * 64, "c" * 64))
    csrf = login(client)
    data = {
        "csrf_token": csrf,
        "current_password": PASSWORD,
        "target_id": str(target_id),
        "backup_id": str(uuid4()),
    }
    return client, connection, data, owner


def test_preview_confirm_exact_replay_and_consumed_link_without_target_io(
    restore_http, monkeypatch
):
    client, connection, data, owner = restore_http
    assert "合成隔离目标" in client.get("/admin/restores").text
    response = client.post(
        "/admin/restores/preview", data=data, headers=ORIGIN, follow_redirects=False
    )
    assert response.status_code == 303
    preview_url = response.headers["location"]
    confirmation = client.get(preview_url)
    assert "确认隔离恢复" in confirmation.text and "OS私有密钥" in confirmation.text
    assert "postgresql" not in confirmation.text and "fingerprint" not in confirmation.text
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        own_jobs = select(func.count()).select_from(BackgroundJob).where(
            BackgroundJob.owner_user_id == owner
        )
        assert session.scalar(own_jobs) == 0
    confirm = {
        "csrf_token": data["csrf_token"],
        "current_password": PASSWORD,
        "confirm_target": re.search(
            r'name="confirm_target" value="([^"]+)"', confirmation.text
        ).group(1),
    }
    first = client.post(preview_url, data=confirm, headers=ORIGIN, follow_redirects=False)
    assert first.status_code == 303
    monkeypatch.setattr(
        rehearsal, "_probe_empty", lambda *args: pytest.fail("replay probed target")
    )
    repeated = client.post(preview_url, data=confirm, headers=ORIGIN, follow_redirects=False)
    assert repeated.status_code == 303 and repeated.headers["location"] == first.headers["location"]
    assert "查看原恢复任务" in client.get("/admin/restores").text
    assert "待执行" in client.get(first.headers["location"]).text
    assert client.post("/admin/restores/preview", data=data, headers=ORIGIN).status_code == 409
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert session.scalar(own_jobs) == 1


def test_restore_forms_reject_csrf_paths_duplicate_target_and_wrong_password(restore_http):
    client, _, data, _ = restore_http
    for patch, code in (
        ({"csrf_token": "bad"}, 403),
        ({"current_password": "incorrect-current-password"}, 403),
        ({"target_id": str(uuid4())}, 503),
        ({"database_url": "private-fixture"}, 422),
    ):
        result = client.post("/admin/restores/preview", data={**data, **patch}, headers=ORIGIN)
        assert result.status_code == code
        assert "incorrect-current-password" not in result.text
    result = client.post(
        "/admin/restores/preview", data=data, headers=ORIGIN, follow_redirects=False
    )
    url = result.headers["location"]
    assert (
        client.post(
            url,
            data={
                "csrf_token": data["csrf_token"],
                "current_password": PASSWORD,
                "confirm_target": str(uuid4()),
            },
            headers=ORIGIN,
        ).status_code
        == 403
    )
    confirmation = client.get(url).text
    identity = re.search(r'name="confirm_target" value="([^"]+)"', confirmation).group(1)
    wrong = client.post(
        url,
        data={
            "csrf_token": data["csrf_token"],
            "current_password": "incorrect-current-password",
            "confirm_target": identity,
        },
        headers=ORIGIN,
    )
    assert wrong.status_code == 403 and "当前管理密码验证失败" in wrong.text
    assert 'value="incorrect-current-password"' not in wrong.text


def test_restore_role_matrix_and_missing_registry_have_no_fake_execution(restore_http):
    client, connection, data, _ = restore_http
    for username, roles in (
        ("restore_service", ["service_admin"]),
        ("restore_owner", ["server_owner"]),
    ):
        add_user(connection, username, roles)
        token = login(client, username)
        assert client.get("/admin/restores").status_code == 403
        assert (
            client.post(
                "/admin/restores/preview", data={**data, "csrf_token": token}, headers=ORIGIN
            ).status_code
            == 403
        )
    add_user(connection, "restore_recovery", ["recovery_admin"])
    login(client, "restore_recovery")
    assert client.get("/admin/restores").status_code == 200
    client.app.state.settings = client.app.state.settings.model_copy(update={"restore_targets": {}})
    page = client.get("/admin/restores")
    assert page.status_code == 200 and "部署未登记隔离恢复目标" in page.text
    assert 'action="/admin/restores/preview"' not in page.text
