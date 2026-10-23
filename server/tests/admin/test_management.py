import json
from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.admin.queries import AuditFilters, export_audit, list_audit
from flowtrace_server.admin.service import audit, set_admin_roles
from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import AdminRole, User, UserSession
from flowtrace_server.auth.service import (
    PASSWORDS,
    authenticate_access,
    create_user,
    issue_session,
    now,
)

from .conftest import ORIGIN, PASSWORD, login

pytestmark = pytest.mark.postgres


def add_user(connection, username, roles=()):
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        user = create_user(session, username, PASSWORD)
        identity = user.id
        for role in roles:
            session.add(AdminRole(user_id=identity, role=role))
        _, tokens = issue_session(session, user, uuid4(), "Synthetic client", "api_native")
        session.commit()
    return identity, tokens


def role_form(csrf, target, roles, password=PASSWORD):
    return {
        "csrf_token": csrf,
        "confirm_target": str(target),
        "roles": list(roles),
        "current_password": password,
    }


def test_recovery_only_portal_is_distinct_from_service_authority(admin_system):
    client, connection, _ = admin_system
    add_user(connection, "recovery_only", ["recovery_admin"])
    csrf = login(client, "recovery_only")
    page = client.get("/admin/overview")
    assert page.status_code == 200
    assert "恢复管理员" in page.text
    assert "暂无成功校验回执" in page.text
    assert 'href="/admin/users"' not in page.text
    for route in ("/admin/users", "/admin/invites", "/admin/audit", "/admin/diagnostics/export"):
        assert client.get(route).status_code == 403
    assert (
        client.post(
            "/admin/invites", data={"csrf_token": csrf, "days": "7"}, headers=ORIGIN
        ).status_code
        == 403
    )
    assert client.get("/admin/password").status_code == 200
    assert client.get("/admin/recovery").status_code == 200
    assert (
        client.post(
            "/admin/logout", data={"csrf_token": csrf}, headers=ORIGIN, follow_redirects=False
        ).status_code
        == 303
    )


def test_password_reset_requires_reauth_and_revokes_all_target_sessions(admin_system):
    client, connection, owner = admin_system
    target, tokens = add_user(connection, "reset_target")
    csrf = login(client)
    replacement = "Replacement-fixture-only-2026"
    data = {
        "csrf_token": csrf,
        "confirm_target": str(target),
        "current_password": "Wrong-password-2026",
        "new_password": replacement,
        "repeat_password": replacement,
    }
    failed = client.post(f"/admin/users/{target}/password", data=data, headers=ORIGIN)
    assert failed.status_code == 403
    assert replacement not in failed.text
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert PASSWORDS.verify(PASSWORD, session.get(User, target).password_hash)
        assert session.get(UserSession, UUID(tokens["session_id"])).revoked_at is None
        record = session.scalar(
            select(AdminAudit).where(AdminAudit.action == "user.password_reset")
        )
        assert record.summary == {"succeeded": False, "status": 403}
    data["current_password"] = PASSWORD
    succeeded = client.post(
        f"/admin/users/{target}/password", data=data, headers=ORIGIN, follow_redirects=False
    )
    assert succeeded.status_code == 303
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert PASSWORDS.verify(replacement, session.get(User, target).password_hash)
        assert session.get(UserSession, UUID(tokens["session_id"])).revoked_at is not None
        assert PASSWORDS.verify(PASSWORD, session.get(User, owner).password_hash)
        for record in session.scalars(select(AdminAudit)):
            assert replacement not in json.dumps(record.summary)
            assert PASSWORD not in json.dumps(record.summary)


def test_role_change_revokes_target_admin_session_and_keeps_api_session(admin_system):
    client, connection, _ = admin_system
    target, tokens = add_user(connection, "service_target", ["service_admin"])
    login(client, "service_target")
    old_admin = client.cookies.get("flowtrace_admin_session")
    csrf = login(client)
    response = client.post(
        f"/admin/users/{target}/roles",
        headers=ORIGIN,
        data=role_form(csrf, target, ["recovery_admin"]),
        follow_redirects=False,
    )
    assert response.status_code == 303
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert set(session.scalars(select(AdminRole.role).where(AdminRole.user_id == target))) == {
            "recovery_admin"
        }
        with pytest.raises(ApiError):
            authenticate_access(session, old_admin, admin=True)
        assert authenticate_access(session, tokens["access_token"]).user_id == target


def test_last_owner_is_protected_even_if_another_recovery_identity_exists(admin_system):
    client, connection, owner = admin_system
    csrf = login(client)
    first = client.post(
        f"/admin/users/{owner}/roles", headers=ORIGIN, data=role_form(csrf, owner, [])
    )
    assert first.status_code == 409
    assert "最后一个有效" in first.text
    add_user(connection, "second_recovery", ["recovery_admin"])
    second = client.post(
        f"/admin/users/{owner}/roles",
        headers=ORIGIN,
        data=role_form(csrf, owner, ["recovery_admin"]),
    )
    assert second.status_code == 409
    assert "服务器所有者" in second.text
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert "server_owner" in set(
            session.scalars(select(AdminRole.role).where(AdminRole.user_id == owner))
        )


def test_service_admin_cannot_reset_admin_or_grant_roles(admin_system):
    client, connection, owner = admin_system
    actor, _ = add_user(connection, "service_only", ["service_admin"])
    csrf = login(client, "service_only")
    assert client.get(f"/admin/users/{owner}/roles").status_code == 403
    assert client.get(f"/admin/users/{owner}/password").status_code == 403
    response = client.post(
        f"/admin/users/{actor}/roles",
        headers=ORIGIN,
        data=role_form(csrf, actor, ["server_owner", "recovery_admin"]),
    )
    assert response.status_code == 403
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert set(session.scalars(select(AdminRole.role).where(AdminRole.user_id == actor))) == {
            "service_admin"
        }


def test_current_database_role_wins_over_principal_role_snapshot(admin_system):
    client, connection, owner = admin_system
    target, _ = add_user(connection, "role_snapshot_target")
    login(client)
    token = client.cookies.get("flowtrace_admin_session")
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        captured = authenticate_access(session, token, admin=True)
        assert isinstance(captured, Principal)
        session.execute(
            delete(AdminRole).where(AdminRole.user_id == owner, AdminRole.role == "server_owner")
        )
        with pytest.raises(ApiError) as failure:
            set_admin_roles(session, captured, target, frozenset({"recovery_admin"}), PASSWORD)
        assert failure.value.code == "admin_forbidden"


def test_user_search_is_literal_and_paginated_without_private_payloads(admin_system):
    client, connection, owner = admin_system
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        password_hash = session.get(User, owner).password_hash
        for index in range(52):
            session.add(
                User(
                    id=uuid4(),
                    username=f"paged_{index:02d}",
                    password_hash=password_hash,
                    enabled=True,
                    created_at=now(),
                )
            )
        session.commit()
    login(client)
    page = client.get("/admin/users", params={"q": "paged_"})
    assert page.status_code == 200
    assert "共 52 个账号" in page.text
    assert page.text.count(">会话</a>") == 50
    second = client.get("/admin/users", params={"q": "paged_", "page": "2"})
    assert second.text.count(">会话</a>") == 2
    assert 'href="/admin/users?' in second.text
    assert "共 0 个账号" in client.get("/admin/users", params={"q": "%"}).text
    assert "password_hash" not in page.text


def test_audit_filters_snapshot_pagination_and_closed_export(admin_system):
    client, connection, owner = admin_system
    marker = "sensitive-private-token-must-never-export"
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        for index in range(55):
            audit(session, owner, "fixture.event", uuid4(), succeeded=index % 2 == 0, count=index)
        session.add(
            AdminAudit(
                id=uuid4(),
                actor_id=owner,
                action="fixture.event",
                target_id=None,
                created_at=now() - timedelta(seconds=1),
                summary={
                    "succeeded": True,
                    "private": marker,
                    "count": {"nested": marker},
                    "status": marker,
                },
            )
        )
        session.flush()
        filters = AuditFilters.parse({"action": "fixture.event", "actor": str(owner)})
        first = list_audit(session, filters)
        second = list_audit(session, filters, 2)
        assert first["total"] == 56 and len(first["audits"]) == 50 and len(second["audits"]) == 6
        assert not set(item.id for item in first["audits"]).intersection(
            item.id for item in second["audits"]
        )
        audit(session, owner, "fixture.event", count=999)
        session.flush()
        assert list_audit(session, filters)["total"] == 56
        failed = list_audit(
            session, AuditFilters.parse({"action": "fixture.event", "result": "failed"})
        )
        assert failed["total"] == 27
        content, count = export_audit(session, filters)
        assert count == 56 and marker.encode() not in content
        assert all(
            set(json.loads(line)).issubset(
                {"id", "created_at", "actor_id", "action", "target_id", "succeeded", "summary"}
            )
            for line in content.splitlines()[1:]
        )


def test_csrf_and_audit_export_reauthentication(admin_system):
    client, connection, _ = admin_system
    target, _ = add_user(connection, "csrf_target")
    csrf = login(client)
    forged = role_form("forged", target, ["service_admin"])
    assert (
        client.post(f"/admin/users/{target}/roles", data=forged, headers=ORIGIN).status_code == 403
    )
    rejected = client.post(
        "/admin/audit/export",
        data={"csrf_token": csrf, "current_password": "Wrong-password-2026"},
        headers=ORIGIN,
    )
    assert rejected.status_code == 403
    succeeded = client.post(
        "/admin/audit/export",
        data={"csrf_token": csrf, "current_password": PASSWORD},
        headers=ORIGIN,
    )
    assert succeeded.status_code == 200
    assert succeeded.headers["content-type"].startswith("application/x-ndjson")
    assert {value.strip() for value in succeeded.headers["cache-control"].split(",")} >= {
        "private",
        "no-store",
    }
    assert PASSWORD not in succeeded.text


def test_audit_export_limit_rejects_wide_filter(admin_system):
    _, connection, owner = admin_system
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        session.bulk_insert_mappings(
            AdminAudit,
            [
                {
                    "id": uuid4(),
                    "actor_id": owner,
                    "action": "fixture.bulk",
                    "target_id": None,
                    "created_at": now(),
                    "summary": {},
                }
                for _ in range(5001)
            ],
        )
        with pytest.raises(ApiError) as failure:
            export_audit(session, AuditFilters.parse({"action": "fixture.bulk"}))
        assert failure.value.code == "audit_export_filter_required"


def test_disable_last_owner_rejects_even_with_enabled_recovery(admin_system):
    client, connection, owner = admin_system
    add_user(connection, "enabled_recovery", ["recovery_admin"])
    csrf = login(client)
    response = client.post(
        f"/admin/users/{owner}/enabled",
        headers=ORIGIN,
        data={"csrf_token": csrf, "confirm_target": str(owner), "enabled": "false"},
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "last_owner_protected"
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        assert session.get(User, owner).enabled


@pytest.mark.parametrize(
    "query",
    [
        {"actor": "not-uuid"},
        {"action": "bad<script>"},
        {"result": "unknown"},
        {"page": "0"},
        {"since": "2026-10-23", "until": "2026-10-22"},
        {"since": "0001-01-01T00:00:00+23:59"},
    ],
)
def test_invalid_audit_filters_reject_without_database_errors(admin_system, query):
    client, _, _ = admin_system
    login(client)
    assert client.get("/admin/audit", params=query).status_code == 422
