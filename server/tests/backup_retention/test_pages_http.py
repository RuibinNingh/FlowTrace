"""Production main ASGI, committed real cookie sessions and independent PG."""

import asyncio
import hashlib
import re
from datetime import timedelta
from html.parser import HTMLParser
from types import SimpleNamespace
from urllib.parse import urlencode
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import delete, select, text, update
from sqlalchemy.orm import Session

from flowtrace_server.admin import router as admin_routes
from flowtrace_server.auth.models import AdminRole, UserSession
from flowtrace_server.auth.service import create_user, now
from flowtrace_server.backups import retention
from flowtrace_server.backups.leases import BackupLeaseError, backup_exclusive_lease
from flowtrace_server.backups.retention_models import BackupControl, BackupPin
from flowtrace_server.config import Settings
from flowtrace_server.imports.parsers import canonical
from flowtrace_server.main import create_app

from .test_retention_io import package, snapshot

pytestmark = pytest.mark.postgres
PASSWORD = "Synthetic-retention-HTTP-password-2026"
ORIGIN = {"origin": "http://testserver"}


class SelectedForm(HTMLParser):
    def __init__(self, action):
        super().__init__()
        self.action, self.active, self.found, self.fields = action, False, False, []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "form":
            self.active = values.get("action") == self.action
            self.found = self.found or self.active
        if tag == "input" and self.active:
            name = values.get("name")
            if name and values.get("type") != "password" and name != "backup_ids":
                self.fields.append((name, values.get("value", "")))

    def handle_endtag(self, tag):
        if tag == "form":
            self.active = False


def form(page, action):
    parser = SelectedForm(action)
    parser.feed(page.text)
    assert parser.found
    return [*parser.fields, ("current_password", PASSWORD)]


def post(client, target, fields):
    return client.post(
        target,
        content=urlencode(fields),
        headers={**ORIGIN, "content-type": "application/x-www-form-urlencoded"},
        follow_redirects=False,
    )


@pytest.fixture
def live_pages(postgres_engine, tmp_path):
    username = "retention_http_" + uuid4().hex
    with Session(postgres_engine) as session, session.begin():
        user = create_user(session, username, PASSWORD)
        owner_id = user.id
        session.add_all(
            [
                AdminRole(user_id=user.id, role=role)
                for role in ("server_owner", "service_admin", "recovery_admin")
            ]
        )
    settings = Settings(
        _env_file=None,
        environment="test",
        diagnostics_enabled=False,
        database_url=postgres_engine.url.render_as_string(hide_password=False),
        data_directory=tmp_path,
    )
    app = create_app(settings)
    with TestClient(app) as client:
        login = client.get("/admin/login")
        csrf = re.search(r'name="csrf_token" value="([^"]+)"', login.text).group(1)
        response = client.post(
            "/admin/login",
            data={
                "csrf_token": csrf,
                "username": username,
                "password": PASSWORD,
            },
            headers=ORIGIN,
            follow_redirects=False,
        )
        assert response.status_code == 303
        result = SimpleNamespace(
            client=client,
            settings=settings,
            engine=postgres_engine,
            owner_id=owner_id,
            session_id=None,
        )
        with Session(postgres_engine) as session:
            result.session_id = session.scalar(
                select(UserSession.id).where(
                    UserSession.user_id == owner_id, UserSession.purpose == "admin"
                )
            )
        try:
            yield result
        finally:
            client.post(
                "/admin/logout",
                data={"csrf_token": client.cookies.get("flowtrace_admin_csrf", "")},
                headers=ORIGIN,
            )
            with Session(postgres_engine) as session, session.begin():
                session.execute(delete(AdminRole).where(AdminRole.user_id == owner_id))
                session.execute(
                    update(UserSession)
                    .where(UserSession.user_id == owner_id, UserSession.revoked_at.is_(None))
                    .values(revoked_at=now())
                )


def make_package(case, *, age_days=40, register=False):
    with Session(case.engine) as session:
        instance, epoch = retention._source(session)
    identifier, root, manifest = package(
        case.settings, instance=instance, epoch=epoch, created_at=now() - timedelta(days=age_days)
    )
    if register:
        from flowtrace_server.auth.dependencies import Principal

        # Use the real stored cookie session's client ID, never invented auth.
        with Session(case.engine) as session:
            principal = Principal(
                case.owner_id,
                case.session_id,
                session.get(UserSession, case.session_id).client_id,
                "admin",
                frozenset(),
            )
        with retention.prepare_registration(case.settings, identifier) as prepared:
            with Session(case.engine) as session:
                retention.register_verified_backup(
                    session, principal, case.settings, prepared=prepared, password=PASSWORD
                )
                session.commit()
    return identifier, root, manifest


def test_production_route_accepts_twenty_multipart_choices_and_zero_delete_report(live_pages):
    case = live_pages
    selected = [make_package(case, register=True) for _ in range(20)]
    _, witness, _ = make_package(case, age_days=0, register=True)
    before = {str(identifier): snapshot(root) for identifier, root, _ in selected}
    witness_before = snapshot(witness)
    page = case.client.get("/admin/backups/retention")
    assert page.status_code == 200 and "不会自动删除" in page.text
    fields = form(page, "/admin/backups/retention/preview")
    fields.extend(("backup_ids", str(identifier)) for identifier, *_ in selected)
    response = case.client.post(
        "/admin/backups/retention/preview",
        files=[(key, (None, value)) for key, value in fields],
        headers=ORIGIN,
        follow_redirects=False,
    )
    assert response.status_code == 200 and "零删除预览报告" in response.text
    assert all(str(identifier) in response.text for identifier, *_ in selected)
    assert PASSWORD not in response.text
    assert {str(identifier): snapshot(root) for identifier, root, _ in selected} == before
    assert snapshot(witness) == witness_before


def test_registration_uses_real_cookie_pw_and_has_no_db_locks_while_hashing(
    live_pages, monkeypatch
):
    case = live_pages
    identifier, root, _ = make_package(case)
    frozen = snapshot(root)
    path = f"/admin/backups/{identifier}/register"
    page = case.client.get(path)
    fields = form(page, path)
    actual = retention._verify_stamp
    phases = []

    def hash_without_business_locks(settings, backup_id, **kwargs):
        assert backup_id == identifier
        with case.engine.begin() as other:
            other.execute(text("SET LOCAL lock_timeout='200ms'"))
            other.execute(
                text("SELECT id FROM users WHERE id=:id FOR UPDATE NOWAIT"), {"id": case.owner_id}
            ).one()
            other.execute(text("SELECT id FROM admin_control WHERE id=1 FOR UPDATE NOWAIT")).one()
            other.execute(text("SELECT id FROM service_configuration WHERE id=1 FOR UPDATE NOWAIT"))
        with pytest.raises(BackupLeaseError):
            with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
                pytest.fail("route hash phase was not source SH protected")
        phases.append("pure_hash")
        return actual(settings, backup_id, **kwargs)

    monkeypatch.setattr(retention, "_verify_stamp", hash_without_business_locks)
    response = post(case.client, path, fields)
    assert response.status_code == 303
    assert response.headers["location"].endswith("/protection") and phases == ["pure_hash"]
    with Session(case.engine) as session:
        assert session.get(BackupControl, identifier) is not None
    with backup_exclusive_lease(case.settings, (identifier,), timeout_seconds=0):
        pass
    assert snapshot(root) == frozen


@pytest.mark.parametrize(
    "mutation",
    [
        "csrf",
        "origin",
        "password",
        "duplicate",
        "extra_url",
        "wrong_sha",
        "wrong_epoch",
    ],
)
def test_registration_rejects_stale_or_nonclosed_auth_without_claiming_package(
    live_pages, mutation
):
    case = live_pages
    identifier, root, _ = make_package(case)
    path = f"/admin/backups/{identifier}/register"
    fields = form(case.client.get(path), path)
    if mutation == "duplicate":
        fields.append(("current_password", PASSWORD))
    elif mutation == "extra_url":
        fields.append(("endpoint", "https://private-sentinel.invalid"))
    else:
        key, value = {
            "csrf": ("csrf_token", "invalid"),
            "origin": ("confirm_target", str(identifier)),
            "password": ("current_password", "Incorrect-current-password-fixture"),
            "wrong_sha": ("expected_manifest_sha256", "0" * 64),
            "wrong_epoch": ("expected_epoch", str(uuid4())),
        }[mutation]
        fields = [(name, value if name == key else item) for name, item in fields]
    before = snapshot(root)
    if mutation == "origin":
        response = case.client.post(
            path,
            content=urlencode(fields),
            headers={
                "origin": "http://untrusted.invalid",
                "content-type": "application/x-www-form-urlencoded",
            },
            follow_redirects=False,
        )
    else:
        response = post(case.client, path, fields)
    assert (
        response.status_code
        == {
            "csrf": 403,
            "origin": 403,
            "password": 403,
            "duplicate": 422,
            "extra_url": 422,
            "wrong_sha": 409,
            "wrong_epoch": 409,
        }[mutation]
    )
    assert PASSWORD not in response.text and "private-sentinel" not in response.text
    with Session(case.engine) as session:
        assert session.get(BackupControl, identifier) is None
    with backup_exclusive_lease(case.settings, (identifier,), timeout_seconds=0):
        pass
    assert snapshot(root) == before


def test_current_role_cookie_does_not_grant_recovery_after_role_change(live_pages):
    case = live_pages
    identifier, _, _ = make_package(case)
    path = f"/admin/backups/{identifier}/register"
    fields = form(case.client.get(path), path)
    with Session(case.engine) as session, session.begin():
        session.execute(
            delete(AdminRole).where(
                AdminRole.user_id == case.owner_id, AdminRole.role == "recovery_admin"
            )
        )
    assert case.client.get("/admin/backups/retention").status_code == 403
    assert post(case.client, path, fields).status_code == 403
    with Session(case.engine) as session:
        assert session.get(BackupControl, identifier) is None


@pytest.mark.parametrize("late_change", ["manifest", "role_during_hash"])
def test_registration_get_binding_and_final_authority_are_fresh(
    live_pages, monkeypatch, late_change
):
    case = live_pages
    identifier, root, manifest = make_package(case)
    path = f"/admin/backups/{identifier}/register"
    fields = form(case.client.get(path), path)
    if late_change == "manifest":
        changed = b'{"environment":"test","changed_since_get":true}'
        (root / "settings.json").write_bytes(changed)
        manifest["files"][0].update(
            size_bytes=len(changed), sha256=hashlib.sha256(changed).hexdigest()
        )
        (root / "manifest.json").write_bytes(canonical(manifest))
    else:
        actual = retention._verify_stamp

        def revoke_after_hash(*args, **kwargs):
            stamp = actual(*args, **kwargs)
            with Session(case.engine) as session, session.begin():
                session.execute(
                    delete(AdminRole).where(
                        AdminRole.user_id == case.owner_id, AdminRole.role == "recovery_admin"
                    )
                )
            return stamp

        monkeypatch.setattr(retention, "_verify_stamp", revoke_after_hash)
    frozen = snapshot(root)
    response = post(case.client, path, fields)
    assert response.status_code == (409 if late_change == "manifest" else 403)
    assert PASSWORD not in response.text
    with Session(case.engine) as session:
        assert session.get(BackupControl, identifier) is None
    with backup_exclusive_lease(case.settings, (identifier,), timeout_seconds=0):
        pass
    assert snapshot(root) == frozen


def test_pin_post_replay_release_and_stale_cas_do_not_delete_package(live_pages):
    case = live_pages
    identifier, root, _ = make_package(case, register=True)
    frozen = snapshot(root)
    view_path, create_path = (
        f"/admin/backups/{identifier}/protection",
        f"/admin/backups/{identifier}/pins",
    )
    fields = form(case.client.get(view_path), create_path)
    assert post(case.client, create_path, fields).status_code == 303
    assert post(case.client, create_path, fields).status_code == 303
    with Session(case.engine) as session:
        pins = list(session.scalars(select(BackupPin).where(BackupPin.backup_id == identifier)))
        assert len(pins) == 1
        pin_id = pins[0].id
    release_path = f"/admin/backups/{identifier}/pins/{pin_id}/release"
    release_fields = form(case.client.get(view_path), release_path)
    wrong_parent = f"/admin/backups/{uuid4()}/pins/{pin_id}/release"
    assert post(case.client, wrong_parent, release_fields).status_code in {404, 409}
    assert post(case.client, release_path, release_fields).status_code == 303
    with Session(case.engine) as session:
        assert session.get(BackupPin, pin_id).version == 2
    assert snapshot(root) == frozen


def test_auth_sql_is_off_eventloop_for_new_post_routes(live_pages, monkeypatch):
    case = live_pages
    identifier, _, _ = make_package(case)
    path = f"/admin/backups/{identifier}/register"
    fields = form(case.client.get(path), path)
    actual, calls = admin_routes.administrator, []

    def checked(*args, **kwargs):
        with pytest.raises(RuntimeError, match="no running event loop"):
            asyncio.get_running_loop()
        calls.append(True)
        return actual(*args, **kwargs)

    monkeypatch.setattr(admin_routes, "administrator", checked)
    assert post(case.client, path, fields).status_code == 303
    assert calls == [True]
