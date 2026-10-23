from concurrent.futures import ThreadPoolExecutor
from threading import Event
from uuid import uuid4

import pytest
from admin.conftest import ORIGIN, PASSWORD
from fastapi.testclient import TestClient
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.admin.service import lock_admin_control
from flowtrace_server.auth.models import AdminRole, User, UserSession
from flowtrace_server.auth.service import PASSWORDS, issue_session
from flowtrace_server.backups import administration as backups
from flowtrace_server.backups.service import verify_backup
from flowtrace_server.config import Settings
from flowtrace_server.jobs import store
from flowtrace_server.main import create_app

from .conftest import package
from .test_archives import temporary_files


@pytest.mark.parametrize("revocation", ["role", "session"])
def test_real_second_connection_revokes_during_lock_free_archive_and_final_response_is_denied(
    queue_case, tmp_path, monkeypatch, revocation
):
    case = queue_case
    settings = Settings(_env_file=None, environment="test", data_directory=tmp_path)
    backup_id, *_ = package(tmp_path / "backups")
    with Session(case.engine) as session, session.begin():
        user = session.get(User, case.owner_id)
        user.password_hash = PASSWORDS.hash(PASSWORD)
        for role in ("server_owner", "service_admin", "recovery_admin"):
            session.add(AdminRole(user_id=case.owner_id, role=role))
        record, tokens = issue_session(
            session, user, uuid4(), "Backup concurrency fixture", "admin"
        )
        session_id = record.id
    app = create_app(settings)
    app.state.engine = case.engine
    started, release = Event(), Event()
    actual = backups.prepare_archive

    def paused_archive(*args, **kwargs):
        started.set()
        assert release.wait(timeout=8)
        return actual(*args, **kwargs)

    monkeypatch.setattr(backups, "prepare_archive", paused_archive)
    with TestClient(app) as client, ThreadPoolExecutor(max_workers=2) as executor:
        client.cookies.set("flowtrace_admin_session", tokens["access_token"], path="/admin")
        client.cookies.set("flowtrace_admin_csrf", tokens["csrf_token"], path="/admin")
        response_future = executor.submit(
            client.post,
            f"/admin/backups/{backup_id}/download",
            data={
                "csrf_token": tokens["csrf_token"],
                "confirm_target": str(backup_id),
                "current_password": PASSWORD,
            },
            headers=ORIGIN,
            follow_redirects=False,
        )
        try:
            assert started.wait(timeout=5)
            # A second HTTP request completes while the slow archive is paused.
            assert executor.submit(client.get, "/health/live").result(timeout=2).status_code == 200
            with Session(case.engine) as session, session.begin():
                session.connection().exec_driver_sql("SET LOCAL lock_timeout='500ms'")
                lock_admin_control(session)
                session.scalar(select(User).where(User.id == case.owner_id).with_for_update())
                if revocation == "role":
                    session.execute(
                        delete(AdminRole).where(
                            AdminRole.user_id == case.owner_id, AdminRole.role == "recovery_admin"
                        )
                    )
                else:
                    session.get(UserSession, session_id).revoked_at = store.stamp(session)
        finally:
            release.set()
        response = response_future.result(timeout=5)
        assert response.status_code == (403 if revocation == "role" else 303)
        assert "content-disposition" not in response.headers
    assert temporary_files(settings) == []
    with Session(case.engine) as session:
        audits = list(
            session.scalars(select(AdminAudit).where(AdminAudit.actor_id == case.owner_id))
        )
        assert len(audits) == 1
        assert audits[0].summary == {
            "succeeded": False,
            "status": 403 if revocation == "role" else 401,
        }


def test_verify_backup_budget_callback_runs_during_hashing_not_only_afterward(tmp_path):
    identifier, *_ = package(tmp_path)
    callbacks = []

    class BudgetExpired(RuntimeError):
        pass

    def budget():
        callbacks.append(True)
        if len(callbacks) == 4:
            raise BudgetExpired

    with pytest.raises(BudgetExpired):
        verify_backup(tmp_path, identifier, check_budget=budget)
    assert len(callbacks) == 4
    assert verify_backup(tmp_path, identifier)["backup_id"] == str(identifier)
