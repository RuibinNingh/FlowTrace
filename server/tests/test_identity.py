import re
from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.admin.service import bootstrap_admin, recover_admin
from flowtrace_server.auth.dependencies import get_session
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import AdminRole, Invite, User, UserSession
from flowtrace_server.auth.service import PASSWORDS, authenticate_access, digest, now
from flowtrace_server.books.models import Book, BookMembership, SyncScope
from flowtrace_server.books.permissions import authorize_scope
from flowtrace_server.config import Settings
from flowtrace_server.main import create_app

pytestmark = pytest.mark.postgres
PASSWORD = "Fixture-only-password-2026"
ORIGIN = {"origin": "http://testserver"}


@pytest.fixture
def identity(postgres_engine):
    with postgres_engine.connect() as connection:
        outer = connection.begin()

        def db_session():
            with Session(
                connection, expire_on_commit=False, join_transaction_mode="create_savepoint"
            ) as session:
                yield session

        with Session(connection, join_transaction_mode="create_savepoint") as session:
            administrator = bootstrap_admin(session, "test_owner", PASSWORD)
            admin_id = administrator.id
            session.commit()
        app = create_app(Settings(_env_file=None, database_url=None, environment="test"))
        app.state.engine = postgres_engine
        app.dependency_overrides[get_session] = db_session
        with TestClient(app) as client:
            yield client, connection, admin_id
        outer.rollback()


def login_admin(client):
    page = client.get("/admin/login")
    token = re.search(r'name="csrf_token" value="([^"]+)"', page.text).group(1)
    response = client.post(
        "/admin/login",
        data={"username": "test_owner", "password": PASSWORD, "csrf_token": token},
        headers=ORIGIN,
        follow_redirects=False,
    )
    assert response.status_code == 303
    return client.cookies.get("flowtrace_admin_csrf")


def invite(client, csrf):
    response = client.post("/admin/invites", data={"days": "7", "csrf_token": csrf}, headers=ORIGIN)
    assert response.status_code == 200
    return re.search(r'data-testid="invite-token">([^<]+)', response.text).group(1)


def register_user(client, token, username="alice"):
    response = client.post(
        "/api/v1/auth/register",
        json={
            "username": username,
            "password": PASSWORD,
            "client_id": str(uuid4()),
            "device_name": "合成测试设备",
            "client_kind": "native",
            "invite_token": token,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def bearer(tokens):
    return {"authorization": "Bearer " + tokens["access_token"]}


def test_invite_single_use_password_and_tokens_are_hashes(identity):
    client, connection, _ = identity
    csrf = login_admin(client)
    token = invite(client, csrf)
    tokens = register_user(client, token)
    assert client.get("/api/v1/users/me", headers=bearer(tokens)).json()["username"] == "alice"
    second = client.post(
        "/api/v1/auth/register",
        json={
            "username": "second",
            "password": PASSWORD,
            "client_id": str(uuid4()),
            "invite_token": token,
        },
    )
    assert second.status_code == 422
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        user = session.scalar(select(User).where(User.username == "alice"))
        assert user.password_hash.startswith("$argon2id$")
        assert PASSWORD not in user.password_hash
        assert session.get(SyncScope, user.id).kind == "user"
        assert (
            len(
                list(
                    session.scalars(select(BookMembership).where(BookMembership.user_id == user.id))
                )
            )
            == 1
        )
        record = session.get(UserSession, UUID(tokens["session_id"]))
        assert record.access_hash == digest(tokens["access_token"])
        assert session.scalar(
            select(Invite.token_hash).where(Invite.consumed_by == user.id)
        ) == digest(token)


def test_refresh_rotation_reuse_revokes_family(identity):
    client, _, _ = identity
    csrf = login_admin(client)
    tokens = register_user(client, invite(client, csrf))
    rotated = client.post("/api/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert rotated.status_code == 200
    assert client.get("/api/v1/users/me", headers=bearer(tokens)).status_code == 401
    assert client.get("/api/v1/users/me", headers=bearer(rotated.json())).status_code == 200
    reused = client.post("/api/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert reused.status_code == 401
    assert client.get("/api/v1/users/me", headers=bearer(rotated.json())).status_code == 401


def test_admin_csrf_origin_and_purpose_are_enforced(identity):
    client, _, _ = identity
    csrf = login_admin(client)
    assert client.post("/admin/invites", data={"days": "7", "csrf_token": csrf}).status_code == 403
    assert (
        client.post(
            "/admin/invites", data={"days": "7", "csrf_token": "wrong"}, headers=ORIGIN
        ).status_code
        == 403
    )
    client.cookies.set("flowtrace_admin_csrf", "injected", domain="testserver.local", path="/admin")
    forged = client.post(
        "/admin/invites", data={"days": "7", "csrf_token": "injected"}, headers=ORIGIN
    )
    assert forged.status_code == 403


def test_disable_revokes_sessions_and_protects_last_admin(identity):
    client, _, admin_id = identity
    csrf = login_admin(client)
    tokens = register_user(client, invite(client, csrf))
    response = client.post(
        f"/admin/users/{tokens['user_id']}/enabled",
        data={"enabled": "false", "csrf_token": csrf, "confirm_target": str(tokens["user_id"])},
        headers=ORIGIN,
    )
    assert response.status_code == 200
    assert client.get("/api/v1/users/me", headers=bearer(tokens)).status_code == 401
    protected = client.post(
        f"/admin/users/{admin_id}/enabled",
        data={"enabled": "false", "csrf_token": csrf, "confirm_target": str(admin_id)},
        headers=ORIGIN,
    )
    assert protected.status_code == 409


def test_shared_book_permissions_and_revocation(identity):
    client, connection, _ = identity
    csrf = login_admin(client)
    alice = register_user(client, invite(client, csrf), "alice")
    bob = register_user(client, invite(client, csrf), "bob")
    book = client.get("/api/v1/books", headers=bearer(alice)).json()["items"][0]
    invitation = client.post(
        f"/api/v1/books/{book['id']}/invites", json={"role": "viewer"}, headers=bearer(alice)
    )
    assert invitation.status_code == 201
    joined = client.post(
        "/api/v1/books/join", json={"token": invitation.json()["token"]}, headers=bearer(bob)
    )
    assert joined.status_code == 200
    assert client.get(f"/api/v1/books/{book['id']}/members", headers=bearer(bob)).status_code == 200
    assert (
        client.post(
            f"/api/v1/books/{book['id']}/invites", json={"role": "editor"}, headers=bearer(bob)
        ).status_code
        == 403
    )
    assert (
        client.patch(
            f"/api/v1/books/{book['id']}/members/{bob['user_id']}",
            json={"role": "editor"},
            headers=bearer(alice),
        ).status_code
        == 204
    )
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        before = session.get(SyncScope, UUID(bob["user_id"])).permission_version
    assert (
        client.delete(
            f"/api/v1/books/{book['id']}/members/{bob['user_id']}", headers=bearer(alice)
        ).status_code
        == 204
    )
    assert client.get(f"/api/v1/books/{book['id']}/members", headers=bearer(bob)).status_code == 403
    assert (
        client.post(
            "/api/v1/books/join", json={"token": invitation.json()["token"]}, headers=bearer(bob)
        ).status_code
        == 422
    )
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert session.get(SyncScope, UUID(bob["user_id"])).permission_version > before
        assert not session.get(BookMembership, (UUID(book["id"]), UUID(bob["user_id"]))).active


def test_stale_admin_role_cannot_mutate(identity):
    client, connection, admin_id = identity
    csrf = login_admin(client)
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        for role in session.scalars(select(AdminRole).where(AdminRole.user_id == admin_id)):
            session.delete(role)
        session.commit()
    assert (
        client.post(
            "/admin/invites", data={"days": "7", "csrf_token": csrf}, headers=ORIGIN
        ).status_code
        == 403
    )


def test_web_writes_require_origin_and_session_csrf(identity):
    client, _, _ = identity
    admin_csrf = login_admin(client)
    native = register_user(client, invite(client, admin_csrf))
    response = client.post(
        "/api/v1/auth/login",
        json={
            "username": "alice",
            "password": PASSWORD,
            "client_id": str(uuid4()),
            "client_kind": "web",
        },
        headers=ORIGIN,
    )
    assert response.status_code == 200
    assert "refresh_token" not in response.json()
    web = response.json()
    web_csrf = client.cookies.get("flowtrace_web_csrf")
    book_id = client.get("/api/v1/books", headers=bearer(web)).json()["items"][0]["id"]
    url = f"/api/v1/books/{book_id}/invites"
    assert client.post(url, json={"role": "viewer"}, headers=bearer(web)).status_code == 403
    assert (
        client.post(url, json={"role": "viewer"}, headers={**bearer(web), **ORIGIN}).status_code
        == 403
    )
    protected = {**bearer(web), **ORIGIN, "x-csrf-token": web_csrf}
    assert client.post(url, json={"role": "viewer"}, headers=protected).status_code == 201
    assert (
        client.delete(f"/api/v1/sessions/{native['session_id']}", headers=bearer(web)).status_code
        == 403
    )
    rotated = client.post(
        "/api/v1/auth/refresh",
        json={"client_kind": "web"},
        headers={**ORIGIN, "x-csrf-token": web_csrf},
    )
    assert rotated.status_code == 200
    assert "refresh_token" not in rotated.json()
    assert "csrf_token" not in rotated.json()


def test_confirmation_precedes_account_and_session_mutation(identity):
    client, connection, _ = identity
    csrf = login_admin(client)
    user = register_user(client, invite(client, csrf))
    first = client.post(
        f"/admin/users/{user['user_id']}/enabled",
        data={"enabled": "false", "csrf_token": csrf},
        headers=ORIGIN,
    )
    assert first.status_code == 200 and "alice" in first.text and "confirm_target" in first.text
    assert client.get("/api/v1/users/me", headers=bearer(user)).status_code == 200
    preview = client.post(
        f"/admin/sessions/{user['session_id']}/revoke", data={"csrf_token": csrf}, headers=ORIGIN
    )
    assert preview.status_code == 200 and "confirm_target" in preview.text
    assert client.get("/api/v1/users/me", headers=bearer(user)).status_code == 200
    revoked = client.post(
        f"/admin/sessions/{user['session_id']}/revoke",
        data={"csrf_token": csrf, "confirm_target": user["session_id"]},
        headers=ORIGIN,
    )
    assert revoked.status_code == 200
    assert client.get("/api/v1/users/me", headers=bearer(user)).status_code == 401


def test_admin_password_change_revokes_other_devices(identity):
    client, _, _ = identity
    csrf = login_admin(client)
    old_api = client.post(
        "/api/v1/auth/login",
        json={"username": "test_owner", "password": PASSWORD, "client_id": str(uuid4())},
    ).json()
    assert client.get("/admin/password").status_code == 200
    replacement = "Updated-fixture-password-2026"
    result = client.post(
        "/admin/password",
        data={
            "csrf_token": csrf,
            "current_password": PASSWORD,
            "new_password": replacement,
            "repeat_password": replacement,
        },
        headers=ORIGIN,
    )
    assert result.status_code == 200 and "密码已更新" in result.text
    assert client.get("/api/v1/users/me", headers=bearer(old_api)).status_code == 401
    assert (
        client.post(
            "/api/v1/auth/login",
            json={"username": "test_owner", "password": PASSWORD, "client_id": str(uuid4())},
        ).status_code
        == 401
    )
    assert (
        client.post(
            "/api/v1/auth/login",
            json={"username": "test_owner", "password": replacement, "client_id": str(uuid4())},
        ).status_code
        == 200
    )
    assert client.get("/admin/overview").status_code == 200


def test_admin_session_and_api_session_are_not_interchangeable(identity):
    client, _, _ = identity
    csrf = login_admin(client)
    admin_cookie = client.cookies.get("flowtrace_admin_session")
    assert (
        client.get(
            "/api/v1/users/me", headers={"authorization": "Bearer " + admin_cookie}
        ).status_code
        == 403
    )
    tokens = register_user(client, invite(client, csrf))
    client.cookies.set(
        "flowtrace_admin_session", tokens["access_token"], domain="testserver.local", path="/admin"
    )
    assert client.get("/admin/overview").status_code == 403


def test_production_login_cookie_is_secure_httponly(identity):
    client, _, _ = identity
    client.app.state.settings.environment = "production"
    response = client.get("/admin/login")
    cookie = response.headers["set-cookie"].lower()
    assert "secure" in cookie and "httponly" in cookie and "samesite=strict" in cookie


def test_large_body_is_rejected_before_parsing(identity):
    client, _, _ = identity
    response = client.post("/api/v1/auth/login", content=b"x" * (1024 * 1024 + 1))
    assert response.status_code == 413
    assert response.json()["error"]["code"] == "body_too_large"


def test_local_recovery_restores_owner_and_revokes_previous_sessions(identity):
    client, connection, admin_id = identity
    login_admin(client)
    original = client.cookies.get("flowtrace_admin_session")
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        for role in session.scalars(select(AdminRole).where(AdminRole.user_id == admin_id)):
            session.delete(role)
        session.get(User, admin_id).enabled = False
        session.commit()
    replacement = "Local-recovered-fixture-2026"
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        recovered = recover_admin(session, "test_owner", replacement)
        session.commit()
        assert recovered.enabled and PASSWORDS.verify(replacement, recovered.password_hash)
        assert set(
            session.scalars(select(AdminRole.role).where(AdminRole.user_id == admin_id))
        ) == {"server_owner", "service_admin", "recovery_admin"}
        assert (
            session.scalar(select(AdminAudit.id).where(AdminAudit.action == "admin.local_recovery"))
            is not None
        )
        with pytest.raises(ApiError) as rejected:
            authenticate_access(session, original, admin=True)
        assert rejected.value.code == "session_invalid"


def test_duplicate_username_does_not_consume_registration_invite(identity):
    client, _, _ = identity
    csrf = login_admin(client)
    register_user(client, invite(client, csrf))
    fresh = invite(client, csrf)
    rejected = client.post(
        "/api/v1/auth/register",
        json={
            "username": "alice",
            "password": PASSWORD,
            "client_id": str(uuid4()),
            "invite_token": fresh,
        },
    )
    assert rejected.status_code == 409
    assert register_user(client, fresh, "bob")["user_id"]


def test_private_scope_does_not_inherit_system_admin_permissions(identity):
    client, connection, _ = identity
    csrf = login_admin(client)
    alice = register_user(client, invite(client, csrf))
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        administrator = authenticate_access(
            session, client.cookies.get("flowtrace_admin_session"), admin=True
        )
        with pytest.raises(ApiError) as denied:
            authorize_scope(session, administrator, UUID(alice["user_id"]), write=True)
        assert denied.value.code == "scope_forbidden"


def test_expired_admin_and_api_access_are_rejected(identity):
    client, connection, _ = identity
    csrf = login_admin(client)
    alice = register_user(client, invite(client, csrf))
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        record = session.get(UserSession, UUID(alice["session_id"]))
        record.access_expires_at = now() - timedelta(seconds=1)
        admin_record = session.scalar(
            select(UserSession).where(
                UserSession.access_hash == digest(client.cookies.get("flowtrace_admin_session"))
            )
        )
        admin_record.idle_expires_at = now() - timedelta(seconds=1)
        session.commit()
    assert client.get("/api/v1/users/me", headers=bearer(alice)).status_code == 401
    assert client.get("/admin/overview", follow_redirects=False).status_code == 303
    assert (
        client.post(
            "/api/v1/auth/refresh", json={"refresh_token": alice["refresh_token"]}
        ).status_code
        == 200
    )


def test_book_uuid_cannot_replace_a_user_scope(identity):
    client, _, _ = identity
    csrf = login_admin(client)
    alice = register_user(client, invite(client, csrf))
    response = client.post(
        "/api/v1/books", json={"id": alice["user_id"], "name": "Collision"}, headers=bearer(alice)
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "id_conflict"


def test_soft_deleted_book_is_not_listed_authorized_or_rest_replayed(identity):
    client, connection, _ = identity
    csrf = login_admin(client)
    alice = register_user(client, invite(client, csrf))
    bob = register_user(client, invite(client, csrf), "bob")
    book = client.get("/api/v1/books", headers=bearer(alice)).json()["items"][0]
    invitation = client.post(
        f"/api/v1/books/{book['id']}/invites", json={"role": "viewer"}, headers=bearer(alice)
    ).json()
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        session.get(Book, UUID(book["id"])).deleted = True
        session.commit()
    assert client.get("/api/v1/books", headers=bearer(alice)).json()["items"] == []
    assert (
        client.get(f"/api/v1/books/{book['id']}/members", headers=bearer(alice)).status_code == 403
    )
    assert (
        client.post(
            "/api/v1/books/join", json={"token": invitation["token"]}, headers=bearer(bob)
        ).status_code
        == 422
    )
    replay = client.post(
        "/api/v1/books", json={"id": book["id"], "name": book["name"]}, headers=bearer(alice)
    )
    assert replay.status_code == 409


def test_rest_text_nul_and_book_name_length_reject_before_database(identity):
    client, _, _ = identity
    csrf = login_admin(client)
    alice = register_user(client, invite(client, csrf))
    for name in ("private\x00name", "a" * 81):
        result = client.post(
            "/api/v1/books", json={"id": str(uuid4()), "name": name}, headers=bearer(alice)
        )
        assert result.status_code == 422
        assert "private" not in result.text
    result = client.post(
        "/api/v1/auth/login",
        json={
            "username": "alice",
            "password": PASSWORD,
            "client_id": str(uuid4()),
            "device_name": "bad\x00name",
        },
    )
    assert result.status_code == 422
