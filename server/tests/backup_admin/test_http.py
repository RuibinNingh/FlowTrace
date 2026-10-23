import hashlib
import io
import zipfile
from dataclasses import replace
from datetime import timedelta
from uuid import uuid4

import pytest
from admin.conftest import ORIGIN, PASSWORD, login
from admin.test_management import add_user
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import AdminRole, UserSession
from flowtrace_server.backups import administration as backups
from flowtrace_server.jobs import store

from .test_archives import temporary_files


def test_html_download_requires_target_csrf_and_current_password(backup_system):
    client, connection, principal, settings, identifier, *_ = backup_system
    csrf = login(client)
    url = f"/admin/backups/{identifier}/download"
    assert client.get(url).status_code == 200
    data = {"csrf_token": csrf, "confirm_target": str(identifier), "current_password": PASSWORD}
    for modified in ({"csrf_token": "wrong"}, {"confirm_target": str(uuid4())}):
        assert client.post(url, data={**data, **modified}, headers=ORIGIN).status_code == 403
    denied = client.post(
        url, data={**data, "current_password": "wrong-password-fixture"}, headers=ORIGIN
    )
    assert denied.status_code == 403 and "当前管理密码验证失败" in denied.text
    assert 'value="wrong-password-fixture"' not in denied.text
    assert temporary_files(settings) == []
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        record = session.scalar(
            select(AdminAudit).where(AdminAudit.action == "backup.raw_download")
        )
        assert record.summary == {"succeeded": False, "status": 403}
    downloaded = client.post(url, data=data, headers=ORIGIN)
    assert downloaded.status_code == 200
    assert downloaded.headers["content-type"] == "application/zip"
    assert "attachment" in downloaded.headers["content-disposition"]
    assert (
        downloaded.headers["x-flowtrace-archive-sha256"]
        == hashlib.sha256(downloaded.content).hexdigest()
    )
    assert {"private", "no-store"} <= set(
        downloaded.headers["cache-control"].replace(" ", "").split(",")
    )
    with zipfile.ZipFile(io.BytesIO(downloaded.content)) as archive:
        assert len(archive.namelist()) == 5
        assert all(name.startswith(f"{identifier}/") for name in archive.namelist())
    assert temporary_files(settings) == []


def test_service_and_owner_without_recovery_cannot_download(backup_system):
    client, connection, principal, _, identifier, *_ = backup_system
    add_user(connection, "backup_service", ["service_admin"])
    for username in ("backup_service", "admin_owner"):
        if username == "admin_owner":
            with Session(connection, join_transaction_mode="create_savepoint") as session:
                session.execute(
                    delete(AdminRole).where(
                        AdminRole.user_id == principal.user_id, AdminRole.role == "recovery_admin"
                    )
                )
                session.commit()
        csrf = login(client, username)
        listing = client.get("/admin/backups")
        assert listing.status_code == 200 and str(identifier) in listing.text
        assert "下载原始包" not in listing.text
        url = f"/admin/backups/{identifier}/download"
        assert client.get(url).status_code == 403
        assert (
            client.post(
                url,
                data={
                    "csrf_token": csrf,
                    "confirm_target": str(identifier),
                    "current_password": PASSWORD,
                },
                headers=ORIGIN,
            ).status_code
            == 403
        )


def test_recovery_only_can_download_but_not_private_book_or_service_actions(backup_system):
    client, connection, _, _, identifier, *_ = backup_system
    add_user(connection, "backup_recovery", ["recovery_admin"])
    csrf = login(client, "backup_recovery")
    assert client.get("/admin/users").status_code == 403
    assert client.get("/admin/backups").status_code == 200
    response = client.post(
        f"/admin/backups/{identifier}/download",
        data={"csrf_token": csrf, "confirm_target": str(identifier), "current_password": PASSWORD},
        headers=ORIGIN,
    )
    assert response.status_code == 200 and response.headers["content-type"] == "application/zip"


def test_uuid_only_boundary_rejects_extra_paths_urls_and_non_uuid_targets(backup_system):
    client, _, _, _, identifier, *_ = backup_system
    csrf = login(client)
    for target in ("not-a-uuid", "https:%2F%2Fexample.invalid", "..%2Fprivate"):
        assert client.get(f"/admin/backups/{target}/download").status_code in {404, 422}
    assert client.get("/admin/backups?before=not-a-uuid").status_code == 422
    data = {"csrf_token": csrf, "confirm_target": str(identifier), "current_password": PASSWORD}
    for field in ("path", "url", "database_url", "command"):
        assert (
            client.post(
                f"/admin/backups/{identifier}/download",
                data={**data, field: "private-input"},
                headers=ORIGIN,
            ).status_code
            == 422
        )


def test_damaged_package_returns_safe_html_failure_and_no_download(backup_system):
    client, connection, _, settings, identifier, directory, *_ = backup_system
    (directory / "database.dump").write_bytes(b"PGDMPdamaged")
    csrf = login(client)
    response = client.post(
        f"/admin/backups/{identifier}/download",
        data={"csrf_token": csrf, "confirm_target": str(identifier), "current_password": PASSWORD},
        headers=ORIGIN,
    )
    assert response.status_code == 409 and "未生成下载包" in response.text
    assert "content-disposition" not in response.headers and temporary_files(settings) == []
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        record = session.scalar(
            select(AdminAudit).where(AdminAudit.action == "backup.raw_download")
        )
        assert record.summary == {"succeeded": False, "status": 409}


def test_expired_principal_cannot_list_or_prepare_and_roles_are_fresh(backup_system):
    _, connection, principal, settings, identifier, *_ = backup_system
    stale_role = replace(principal, roles=frozenset({"recovery_admin"}))
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        session.get(UserSession, principal.session_id).expires_at = store.stamp(
            session
        ) - timedelta(seconds=1)
        session.flush()
        for action in (
            lambda: backups.list_backups(session, stale_role, settings),
            lambda: backups.precheck_download(
                session, stale_role, backup_id=identifier, password=PASSWORD
            ),
        ):
            with pytest.raises(ApiError) as error:
                action()
            assert error.value.status == 401
    assert temporary_files(settings) == []
