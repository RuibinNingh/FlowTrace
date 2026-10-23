import re
from datetime import timedelta

from admin.conftest import ORIGIN, PASSWORD, login
from admin.conftest import admin_system as admin_system
from admin.test_management import add_user
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from flowtrace_server.auth.models import Invite
from flowtrace_server.auth.service import now
from flowtrace_server.configuration.models import ConfigurationRevision

from .test_forms import form_values


def update_form(client, csrf):
    page = client.get("/admin/configuration")
    assert page.status_code == 200
    values = form_values()
    values.update(
        csrf_token=csrf,
        current_password=PASSWORD,
        base_version=re.search(r'name="base_version" value="([^"]+)"', page.text).group(1),
        request_id=re.search(r'name="request_id" value="([^"]+)"', page.text).group(1),
    )
    values["confirm_version"] = values["base_version"]
    return values


def test_html_preview_has_no_publish_or_secret_echo_and_save_replays(admin_system):
    client, connection, _ = admin_system
    csrf = login(client)
    data = update_form(client, csrf)
    current = client.get("/admin/configuration")
    assert current.text.count("已接入运行行为") == 7
    assert current.text.count("可保存；运行行为尚未接入") == 3
    data.pop("confirm_version")
    data.update(current_password="", invitation_default_days="9")
    preview = client.post("/admin/configuration/preview", data=data, headers=ORIGIN)
    assert preview.status_code == 200 and "公开设置预览" in preview.text
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert session.scalar(select(func.count()).select_from(ConfigurationRevision)) == 0
    data.update(
        current_password=PASSWORD,
        confirm_version="0",
        ai_api_key_action="replace",
        ai_api_key_value="Synthetic-HTML-private-secret",
    )
    denied = client.post(
        "/admin/configuration",
        data={**data, "current_password": "Incorrect-current-password-fixture"},
        headers=ORIGIN,
    )
    assert denied.status_code == 403
    assert "Incorrect-current-password-fixture" not in denied.text
    assert "Synthetic-HTML-private-secret" not in denied.text
    for _ in range(2):
        response = client.post("/admin/configuration", data=data, headers=ORIGIN)
        assert response.status_code == 200
        assert 'name="base_version" value="1"' in response.text
        assert "AI API 密钥 · 已配置" in response.text
        assert "Synthetic-HTML-private-secret" not in response.text
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert session.scalar(select(func.count()).select_from(ConfigurationRevision)) == 1


def test_update_form_requires_csrf_target_and_closed_fields(admin_system):
    client, connection, _ = admin_system
    data = update_form(client, login(client))
    for patch, status in (
        ({"csrf_token": "wrong"}, 403),
        ({"confirm_version": "1"}, 422),
        ({"endpoint": "http://127.0.0.1/private"}, 422),
        ({"ai_api_key": "00000000-0000-0000-0000-000000000000"}, 422),
        ({"attachment_max_bytes": "200", "per_user_attachment_quota_bytes": "100"}, 422),
    ):
        response = client.post("/admin/configuration", data={**data, **patch}, headers=ORIGIN)
        assert response.status_code == status
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert session.scalar(select(func.count()).select_from(ConfigurationRevision)) == 0


def test_recovery_only_cannot_read_or_post_configuration(admin_system):
    client, connection, _ = admin_system
    add_user(connection, "configuration_recovery", ["recovery_admin"])
    csrf = login(client, "configuration_recovery")
    assert client.get("/admin/overview").status_code == 200
    assert 'href="/admin/configuration"' not in client.get("/admin/overview").text
    for path in (
        "/admin/configuration",
        "/admin/configuration/history",
        "/admin/configuration/providers",
    ):
        assert client.get(path).status_code == 403
    data = {**form_values(), "csrf_token": csrf, "current_password": PASSWORD}
    assert client.post("/admin/configuration", data=data, headers=ORIGIN).status_code == 403


def test_rollback_html_preview_and_post_require_target_and_password(admin_system):
    client, connection, _ = admin_system
    csrf = login(client)
    data = update_form(client, csrf)
    data["invitation_default_days"] = "9"
    assert client.post("/admin/configuration", data=data, headers=ORIGIN).status_code == 200
    preview = client.get("/admin/configuration/rollback/0")
    assert preview.status_code == 200 and "预览回滚" in preview.text
    request_id = re.search(r'name="request_id" value="([^"]+)"', preview.text).group(1)
    rollback = {
        "csrf_token": csrf,
        "base_version": "1",
        "request_id": request_id,
        "confirm_target": "0",
        "current_password": PASSWORD,
    }
    for patch, status in (
        ({"confirm_target": "1"}, 422),
        ({"current_password": "wrong-password-fixture"}, 403),
    ):
        assert (
            client.post(
                "/admin/configuration/rollback/0", data={**rollback, **patch}, headers=ORIGIN
            ).status_code
            == status
        )
    response = client.post("/admin/configuration/rollback/0", data=rollback, headers=ORIGIN)
    assert response.status_code == 200 and 'name="base_version" value="2"' in response.text
    history = client.get("/admin/configuration/history")
    assert history.status_code == 200 and "回滚到 0" in history.text
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert session.get(ConfigurationRevision, 1).public_values["invitation_default_days"] == 9


def test_fixed_provider_check_has_reauth_target_and_version_boundaries(admin_system):
    client, _, _ = admin_system
    csrf = login(client)
    data = {
        "csrf_token": csrf,
        "expected_version": "0",
        "confirm_provider": "ocr_primary",
        "current_password": PASSWORD,
    }
    endpoint = "/admin/configuration/providers/ocr_primary/check"
    for patch, status in (
        ({"expected_version": "1"}, 409),
        ({"confirm_provider": "ai_primary"}, 422),
        ({"current_password": "wrong-password-fixture"}, 403),
        ({"url": "https://example.invalid"}, 422),
    ):
        assert client.post(endpoint, data={**data, **patch}, headers=ORIGIN).status_code == status
    result = client.post(endpoint, data=data, headers=ORIGIN)
    assert result.status_code == 200 and "provider_not_registered" in result.text
    assert "https://example.invalid" not in result.text


def test_invitation_form_and_omitted_duration_use_current_configuration(admin_system):
    client, connection, _ = admin_system
    csrf = login(client)
    data = update_form(client, csrf)
    data["invitation_default_days"] = "9"
    assert client.post("/admin/configuration", data=data, headers=ORIGIN).status_code == 200
    assert 'name="days" type="number" value="9"' in client.get("/admin/invites").text
    start = now()
    response = client.post("/admin/invites", data={"csrf_token": csrf}, headers=ORIGIN)
    assert response.status_code == 200
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        invitation = session.scalar(select(Invite).order_by(Invite.created_at.desc()))
        assert start + timedelta(days=9) <= invitation.expires_at <= now() + timedelta(days=9)
