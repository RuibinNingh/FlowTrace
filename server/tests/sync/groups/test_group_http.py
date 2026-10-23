"""Production-main group HTTP over an isolated PostgreSQL database."""

import asyncio
import json
from copy import deepcopy
from dataclasses import replace
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session
from starlette.requests import Request
from sync.helpers import account, actor, epoch, revoke, share

from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import User, UserSession
from flowtrace_server.auth.service import issue_session, now
from flowtrace_server.config import Settings
from flowtrace_server.main import create_app
from flowtrace_server.sync import group_router
from flowtrace_server.sync.canonical import content_hash
from flowtrace_server.sync.group_models import GroupPullSession
from flowtrace_server.sync.group_schemas import GroupPullCreate, page_hash_payload
from flowtrace_server.sync.group_service import discard_group_pull
from flowtrace_server.sync.models import SyncChange
from flowtrace_server.sync.reader import _change_dict

pytestmark = pytest.mark.postgres
PREFIX = "/api/v1/sync/group-pulls"


def headers(owner):
    return {"authorization": "Bearer " + owner.token}


def create_body(engine, owner):
    return {
        "protocol_version": 1,
        "request_id": str(uuid4()),
        "client_id": str(owner.principal.client_id),
        "sync_epoch": epoch(engine),
        "cursors": {},
    }


def cleanup_owned_http_fixture(engine, user_ids):
    """Exact fixture-owned cleanup; no claim of a client's normal logout.

    Preserve domain rows and request tombstones. A fresh valid API origin can
    remove only its owner's cache, then explicitly revoke these test sessions.
    """
    collected, revoked = 0, 0
    for user_id in user_ids:
        with Session(engine, expire_on_commit=False) as session:
            record, _ = issue_session(
                session,
                session.get(User, user_id),
                uuid4(),
                "group-http-fixture-cleanup",
                "api_native",
            )
            principal = Principal(user_id, record.id, record.client_id, record.purpose, frozenset())
            identifiers = list(
                session.scalars(
                    select(GroupPullSession.id).where(
                        GroupPullSession.user_id == user_id,
                        GroupPullSession.build_state.contains({"collected": True}).is_not(True),
                    )
                )
            )
            session.commit()
        for identifier in identifiers:
            with Session(engine) as session:
                discard_group_pull(session, principal, identifier)
            collected += 1
        with Session(engine) as session:
            rows = session.scalars(
                select(UserSession)
                .where(UserSession.user_id == user_id, UserSession.revoked_at.is_(None))
                .with_for_update()
            ).all()
            for row in rows:
                row.revoked_at = now()
            revoked += len(rows)
            session.commit()
    return {"fixture_handles_collected": collected, "fixture_sessions_sql_revoked": revoked}


@pytest.fixture
def group_http(postgres_engine, tmp_path, monkeypatch):
    with Session(postgres_engine) as session:
        before = set(session.scalars(select(User.id)))
    authenticate = group_router.authenticated_request

    def checked_authentication(session, request):
        try:
            asyncio.get_running_loop()
        except RuntimeError:
            pass
        else:
            raise AssertionError("synchronous database authentication ran on event loop")
        return authenticate(session, request)

    monkeypatch.setattr(group_router, "authenticated_request", checked_authentication)
    app = create_app(
        Settings(
            _env_file=None,
            database_url=None,
            data_directory=tmp_path,
            environment="test",
            diagnostics_enabled=False,
        )
    )
    app.state.engine = postgres_engine
    try:
        with TestClient(app) as client:
            yield client
    finally:
        with Session(postgres_engine) as session:
            created = set(session.scalars(select(User.id))) - before
        cleanup_owned_http_fixture(postgres_engine, created)


def test_http_schema_closed_streaming_main_group_and_stage_mounted(group_http, tmp_path):
    ordinary = create_app(
        Settings(
            _env_file=None,
            database_url=None,
            data_directory=tmp_path,
            environment="test",
            diagnostics_enabled=False,
        )
    )
    ordinary.state.engine = group_http.app.state.engine
    assert any(path.startswith(PREFIX) for path in ordinary.openapi()["paths"])
    assert any(
        path.startswith("/api/v1/data-tools/import-stages") for path in ordinary.openapi()["paths"]
    )
    with TestClient(ordinary) as client:
        assert client.get(PREFIX).status_code == 401
        capabilities = client.get("/api/v1/server-info").json()["capabilities"]
        assert "group-sync-v1" in capabilities
        assert "import-stages-v1" in capabilities
    operations = [
        operation
        for path, methods in group_http.app.openapi()["paths"].items()
        if path.startswith(PREFIX)
        for method, operation in methods.items()
        if method in {"get", "post"}
    ]
    assert len(operations) == 6 and len({value["operationId"] for value in operations}) == 6
    for operation in operations:
        if "requestBody" in operation:
            value = operation["requestBody"]["content"]["application/json"]["schema"]
            assert value["additionalProperties"] is False and "$ref" not in value
    # FastAPI includes routers lazily in the application; inspect the concrete
    # original routes rather than letting an empty application-path loop pass.
    assert len(group_router.router.routes) == 6
    for route in group_router.router.routes:
        assert route.body_field is None  # automatic body parsing would bypass streaming limit


def test_http_create_step_replay_status_chain_preserves_exact_raw(group_http, postgres_engine):
    owner = actor(postgres_engine)
    account(postgres_engine, owner, opening="9007199254740993")
    body = create_body(postgres_engine, owner)
    response = group_http.post(PREFIX, headers=headers(owner), json=body)
    assert response.status_code == 201 and "no-store" in response.headers["cache-control"]
    status, used, first = response.json(), None, None
    url = PREFIX + "/" + status["pull_id"]
    for _ in range(30):
        if status["status"] == "ready":
            break
        step_body = {"client_id": body["client_id"], "step_token": status["next_step_token"]}
        response = group_http.post(url + "/steps", headers=headers(owner), json=step_body)
        assert response.status_code == 200, response.text
        if first is None:
            first, used = response.json(), step_body
        status = response.json()
    assert status["status"] == "ready"
    assert group_http.post(url + "/steps", headers=headers(owner), json=used).json() == first
    assert (
        group_http.get(url, headers=headers(owner), params={"client_id": body["client_id"]}).json()
        == status
    )
    token, events = status["first_page_token"], []
    while token is not None:
        response = group_http.post(
            url + "/pages",
            headers=headers(owner),
            json={"client_id": body["client_id"], "page_token": token},
        )
        assert response.status_code == 200 and "no-store" in response.headers["cache-control"]
        page = response.json()
        assert page["page_sha256"] == content_hash(page_hash_payload(page))
        if page["kind"] == "data":
            events.extend(event for fragment in page["fragments"] for event in fragment["events"])
        token = page["next_page_token"]
    with Session(postgres_engine) as session:
        expected = [
            _change_dict(row)
            for row in session.scalars(
                select(SyncChange).where(
                    SyncChange.scope_id.in_([owner.book_id, owner.principal.user_id])
                )
            )
        ]
    assert {content_hash(value) for value in expected} == {content_hash(value) for value in events}
    listing = group_http.get(PREFIX, headers=headers(owner)).json()["pulls"]
    assert len(listing) == 1 and set(listing[0]) == {
        "pull_id",
        "request_id",
        "client_id",
        "sync_epoch",
        "status",
        "expires_at",
    }


def test_http_strict_json_queries_and_size_never_create_a_pull(group_http, postgres_engine):
    owner = actor(postgres_engine)
    body, auth = create_body(postgres_engine, owner), headers(owner)
    raw = json.dumps(body).replace(
        '"protocol_version": 1', '"protocol_version": 1, "protocol_version": 1'
    )
    assert (
        group_http.post(
            PREFIX, headers={**auth, "content-type": "application/json"}, content=raw
        ).status_code
        == 400
    )
    for changes in (
        {"url": "http://private.invalid/Synthetic-secret"},
        {"protocol_version": True},
        {"protocol_version": 1.0},
    ):
        assert group_http.post(PREFIX, headers=auth, json={**body, **changes}).status_code in {
            400,
            422,
        }
    assert (
        group_http.post(
            PREFIX, headers={**auth, "content-type": "text/plain"}, content="{}"
        ).status_code
        == 415
    )
    assert (
        group_http.post(
            PREFIX,
            headers={**auth, "content-type": "application/json"},
            content=b"x" * (1024 * 1024 + 1),
        ).status_code
        == 413
    )
    assert group_http.get(PREFIX + "?url=http://private.invalid", headers=auth).status_code == 422
    fake = PREFIX + "/" + str(uuid4())
    query = "?client_id=" + body["client_id"] + "&client_id=" + body["client_id"]
    assert group_http.get(fake + query, headers=auth).status_code == 422
    assert group_http.get(PREFIX, headers=auth).json() == {"pulls": []}


def test_http_real_auth_origin_csrf_and_other_owner_are_enforced(group_http, postgres_engine):
    native, stranger = actor(postgres_engine), actor(postgres_engine)
    with Session(postgres_engine, expire_on_commit=False) as session:
        record, tokens = issue_session(
            session, session.get(User, native.principal.user_id), uuid4(), "合成Web", "api_web"
        )
        session.commit()
    browser = replace(
        native,
        principal=Principal(
            record.user_id, record.id, record.client_id, record.purpose, frozenset()
        ),
        token=tokens["access_token"],
    )
    body = create_body(postgres_engine, browser)
    assert group_http.post(PREFIX, json=body).status_code == 401
    assert group_http.post(PREFIX, headers=headers(browser), json=body).status_code == 403
    auth = {**headers(browser), "origin": "http://testserver", "x-csrf-token": tokens["csrf_token"]}
    assert (
        group_http.post(
            PREFIX, headers={**auth, "origin": "http://private.invalid"}, json=body
        ).status_code
        == 403
    )
    response = group_http.post(PREFIX, headers=auth, json=body)
    assert response.status_code == 201, response.text
    url = PREFIX + "/" + response.json()["pull_id"]
    assert (
        group_http.post(
            url + "/discard", headers=headers(browser), json={"client_id": body["client_id"]}
        ).status_code
        == 403
    )
    assert (
        group_http.post(
            url + "/discard", headers=auth, json={"client_id": str(uuid4())}
        ).status_code
        == 403
    )
    assert (
        group_http.get(
            url, headers=headers(stranger), params={"client_id": str(stranger.principal.client_id)}
        ).status_code
        == 404
    )
    assert group_http.get(PREFIX, headers=headers(stranger)).json() == {"pulls": []}
    assert (
        group_http.post(
            url + "/discard", headers=auth, json={"client_id": body["client_id"]}
        ).status_code
        == 200
    )


def test_lost_create_response_new_origin_revoked_scope_lists_handle_then_discards(
    group_http, postgres_engine
):
    owner, member = actor(postgres_engine), actor(postgres_engine)
    share(postgres_engine, owner, member)
    body = create_body(postgres_engine, member)
    lost = group_http.post(PREFIX, headers=headers(member), json=body).json()
    other_device = actor(postgres_engine, existing_user=member.principal.user_id)
    other = group_http.post(
        PREFIX, headers=headers(other_device), json=create_body(postgres_engine, other_device)
    ).json()
    with Session(postgres_engine, expire_on_commit=False) as session:
        record, tokens = issue_session(
            session,
            session.get(User, member.principal.user_id),
            member.principal.client_id,
            "重开原设备",
            "api_native",
        )
        session.get(UserSession, member.principal.session_id).revoked_at = now()
        session.commit()
    renewed = replace(
        member,
        principal=Principal(
            record.user_id, record.id, record.client_id, record.purpose, frozenset()
        ),
        token=tokens["access_token"],
    )
    revoke(postgres_engine, owner, member)
    assert group_http.post(PREFIX, headers=headers(renewed), json=body).status_code == 409
    response = group_http.get(PREFIX, headers=headers(renewed))
    assert response.status_code == 200
    entries = response.json()["pulls"]
    handle = next(
        row
        for row in entries
        if all(row[key] == body[key] for key in ("request_id", "client_id", "sync_epoch"))
    )
    assert handle["pull_id"] == lost["pull_id"]
    assert all(
        set(row) == {"pull_id", "request_id", "client_id", "sync_epoch", "status", "expires_at"}
        for row in entries
    )
    assert (
        group_http.post(
            PREFIX + "/" + handle["pull_id"] + "/discard",
            headers=headers(renewed),
            json={"client_id": body["client_id"]},
        ).status_code
        == 200
    )
    entries = group_http.get(PREFIX, headers=headers(renewed)).json()["pulls"]
    assert [row["pull_id"] for row in entries] == [other["pull_id"]]
    assert group_http.post(PREFIX, headers=headers(renewed), json=body).status_code == 410
    replacement = group_http.post(
        PREFIX, headers=headers(renewed), json=create_body(postgres_engine, renewed)
    )
    assert replacement.status_code == 201
    # Deliberately corrupted >2 rows must fail explicitly, not silently truncate.
    with Session(postgres_engine) as session:
        row = session.get(GroupPullSession, UUID(replacement.json()["pull_id"]))
        values = {
            column.name: deepcopy(getattr(row, column.name))
            for column in GroupPullSession.__table__.columns
        }
        values.update(id=uuid4(), request_id=uuid4())
        session.add(GroupPullSession(**values))
        session.commit()
    response = group_http.get(PREFIX, headers=headers(renewed))
    assert (
        response.status_code == 503
        and response.json()["error"]["code"] == "group_list_inconsistent"
    )


def test_stream_bound_stops_receiving_before_third_chunk():
    calls = 0

    async def receive():
        nonlocal calls
        calls += 1
        assert calls <= 2
        return {"type": "http.request", "body": b"x" * (600 * 1024), "more_body": True}

    request = Request(
        {"type": "http", "method": "POST", "headers": [(b"content-type", b"application/json")]},
        receive=receive,
    )
    with pytest.raises(ApiError) as error:
        asyncio.run(group_router._strict_body(request, GroupPullCreate))
    assert error.value.status == 413 and calls == 2
