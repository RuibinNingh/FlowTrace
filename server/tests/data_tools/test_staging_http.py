"""Ordinary-main staged import boundary over isolated PostgreSQL."""

import asyncio
import hashlib
import json
from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from sync.helpers import actor, epoch, revoke, share

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import User, UserSession
from flowtrace_server.auth.service import issue_session
from flowtrace_server.config import Settings
from flowtrace_server.imports import staging_router
from flowtrace_server.imports.models import ImportBatch
from flowtrace_server.imports.staging_models import ImportPublication, ImportStage
from flowtrace_server.imports.staging_schemas import STAGE_CHUNK_BYTES
from flowtrace_server.jobs import store
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.main import create_app
from flowtrace_server.sync.models import SyncEntity
from flowtrace_server.worker.runtime import Worker

from .test_staging_parsers import source_file
from .test_staging_preview import categories

pytestmark = pytest.mark.postgres
PREFIX = "/api/v1/data-tools/import-stages"


def headers(owner):
    return {"authorization": "Bearer " + owner.token}


@pytest.fixture
def stage_http(postgres_engine, tmp_path):
    settings = Settings(
        _env_file=None,
        environment="test",
        data_directory=tmp_path,
        database_url=postgres_engine.url.render_as_string(hide_password=False),
        diagnostics_enabled=False,
    )
    app = create_app(settings)
    app.state.engine = postgres_engine
    owners = []
    worker = Worker(postgres_engine, settings)
    with TestClient(app) as client:
        client.stage_worker = worker
        client.stage_owners = owners
        yield client
    try:
        with Session(postgres_engine) as session, session.begin():
            for job in session.scalars(
                select(BackgroundJob).where(
                    BackgroundJob.owner_user_id.in_(owners),
                    BackgroundJob.kind.in_(["import_preview", "import_apply"]),
                    BackgroundJob.status.in_(["pending", "running", "retry_wait"]),
                )
            ):
                store.cancel(session, job.id)
    finally:
        worker.close()


def create(client, engine, owner, content=None, *, mapping=None, target=None, count=61):
    content = content or source_file("flowtrace_json", categories(target or owner, count))
    body = {
        "stage_id": str(uuid4()),
        "client_id": str(owner.principal.client_id),
        "sync_epoch": epoch(engine),
        "format": "flowtrace_json",
        "expected_bytes": len(content),
        "source_sha256": hashlib.sha256(content).hexdigest(),
        "mapping": mapping or {},
    }
    client.stage_owners.append(owner.principal.user_id)
    response = client.post(PREFIX, headers=headers(owner), json=body)
    assert response.status_code == 200, response.text
    return response.json(), body, content


def chunk(client, owner, stage, index, content, *, version=1, digest=None, **kwargs):
    return client.put(
        PREFIX + f"/{stage['stage_id']}/chunks/{index}",
        params={"stage_version": version},
        headers={
            **headers(owner),
            "content-type": "application/octet-stream",
            "x-chunk-sha256": digest or hashlib.sha256(content).hexdigest(),
        },
        content=content,
        **kwargs,
    )


def post(client, owner, stage, action, body):
    return client.post(PREFIX + f"/{stage['stage_id']}/{action}", headers=headers(owner), json=body)


def status(client, owner, stage):
    response = client.get(PREFIX + "/" + stage["stage_id"], headers=headers(owner))
    assert response.status_code == 200, response.text
    return response.json()


def upload_seal(client, owner, stage, body, content):
    for index, offset in enumerate(range(0, len(content), STAGE_CHUNK_BYTES)):
        response = chunk(client, owner, stage, index, content[offset : offset + STAGE_CHUNK_BYTES])
        assert response.status_code == 200, response.text
    response = post(
        client,
        owner,
        stage,
        "seal",
        {
            "stage_version": 1,
            "total_bytes": len(content),
            "source_sha256": body["source_sha256"],
        },
    )
    assert response.status_code == 200, response.text
    return response.json()


def run(client, engine, job_id):
    with Session(engine) as session, session.begin():
        earliest = session.scalar(select(func.min(BackgroundJob.available_at)))
        session.get(BackgroundJob, UUID(job_id)).available_at = earliest - timedelta(seconds=1)
    assert client.stage_worker.run_once()
    with Session(engine) as session:
        job = session.get(BackgroundJob, UUID(job_id))
        assert job.status == "succeeded", job.error_code
        assert set(job.result) == {"code", "created_count"}


def ready(client, engine, owner, *, target=None):
    stage, body, content = create(client, engine, owner, target=target)
    parsed = upload_seal(client, owner, stage, body, content)
    run(client, engine, parsed["job_id"])
    queued = post(client, owner, stage, "preview", {"stage_version": 1})
    assert queued.status_code == 200, queued.text
    run(client, engine, queued.json()["job_id"])
    return stage, status(client, owner, stage)


def test_stage_router_main_mounted_and_explicit_capability(postgres_engine, tmp_path):
    app = create_app(
        Settings(
            _env_file=None,
            environment="test",
            data_directory=tmp_path,
            database_url=postgres_engine.url.render_as_string(hide_password=False),
            diagnostics_enabled=False,
        )
    )
    assert any(path.startswith(PREFIX) for path in app.openapi()["paths"])
    with TestClient(app) as client:
        response = client.post(PREFIX, json={})
        assert response.status_code == 422
        assert client.get(PREFIX + "/" + str(uuid4())).status_code == 401
        capabilities = client.get("/api/v1/server-info").json()["capabilities"]
        assert "import-stages-v1" in capabilities
        assert "group-sync-v1" in capabilities


def test_main_openapi_closed_dtos_and_old_public_limits(stage_http):
    document = stage_http.app.openapi()
    paths, schemas = document["paths"], document["components"]["schemas"]
    operations = [
        operation
        for path, methods in paths.items()
        if path.startswith(PREFIX)
        for method, operation in methods.items()
        if method in {"get", "post", "put"}
    ]
    assert len(operations) == 17
    assert len({operation["operationId"] for operation in operations}) == 17
    for operation in operations:
        schema = operation["responses"]["200"]["content"]["application/json"]["schema"]
        response = schemas[schema["$ref"].rsplit("/", 1)[1]]
        assert response["type"] == "object" and response["additionalProperties"] is False
    assert "stage_id" in schemas["StageCreateRequest"]["required"]
    assert schemas["StageCreateRequest"]["additionalProperties"] is False
    assert schemas["ImportDocument"]["properties"]["rows"]["maxItems"] == 50
    assert schemas["ExportDocument"]["properties"]["rows"]["maxItems"] == 1000
    binary = paths[PREFIX + "/{stage_id}/chunks/{chunk_index}"]["put"]["requestBody"]["content"]
    assert set(binary) == {"application/octet-stream"}
    assert binary["application/octet-stream"]["schema"]["maxLength"] == STAGE_CHUNK_BYTES


def test_async_stage_auth_database_reads_run_off_event_loop(
    stage_http, postgres_engine, monkeypatch
):
    owner = actor(postgres_engine)
    actual, observed = staging_router.authenticated_request, []

    def checked(session, request):
        with pytest.raises(RuntimeError):
            asyncio.get_running_loop()
        observed.append(request.method)
        return actual(session, request)

    monkeypatch.setattr(staging_router, "authenticated_request", checked)
    stage, _, content = create(stage_http, postgres_engine, owner, b"synthetic-no-parse")
    assert status(stage_http, owner, stage)["status"] == "uploading"
    assert chunk(stage_http, owner, stage, 0, content).status_code == 200
    assert observed == ["POST", "GET", "PUT"]


def test_http_full_actual_worker_parse_rows_preview_apply_undo_and_replays(
    stage_http, postgres_engine
):
    owner = actor(postgres_engine)
    stage, body, content = create(stage_http, postgres_engine, owner)
    repeated = stage_http.post(PREFIX, headers=headers(owner), json=body)
    assert repeated.status_code == 200 and repeated.json() == stage
    parsed = upload_seal(stage_http, owner, stage, body, content)
    run(stage_http, postgres_engine, parsed["job_id"])
    page_url = PREFIX + f"/{stage['stage_id']}/rows"
    page = stage_http.get(
        page_url, headers=headers(owner), params={"stage_version": 1, "limit": 17}
    )
    assert page.status_code == 200, page.text
    assert len(page.json()["rows"]) == 17
    assert {row["status"] for row in page.json()["rows"]} == {"parsed"}
    cursor, positions = None, []
    while True:
        result = stage_http.get(
            page_url,
            headers=headers(owner),
            params={"stage_version": 1, "limit": 17, **({"cursor": cursor} if cursor else {})},
        )
        assert result.status_code == 200 and len(result.content) <= 1024 * 1024
        positions += [row["position"] for row in result.json()["rows"]]
        cursor = result.json()["next_cursor"]
        if cursor is None:
            break
    assert positions == list(range(1, 62))
    preview = post(stage_http, owner, stage, "preview", {"stage_version": 1})
    assert preview.status_code == 200
    assert post(stage_http, owner, stage, "preview", {"stage_version": 1}).json() == preview.json()
    run(stage_http, postgres_engine, preview.json()["job_id"])
    current = status(stage_http, owner, stage)
    assert current["status"] == "ready" and current["row_count"] == 61
    with Session(postgres_engine) as session:
        assert session.get(ImportBatch, UUID(stage["batch_id"])) is None
    apply = {
        "stage_version": 1,
        "batch_id": stage["batch_id"],
        "preview_hash": current["preview_hash"],
    }
    queued = post(stage_http, owner, stage, "apply", apply)
    assert queued.status_code == 200, queued.text
    assert set(queued.json()) == {"stage_id", "stage_version", "job_id", "status"}
    assert post(stage_http, owner, stage, "apply", apply).json() == queued.json()
    run(stage_http, postgres_engine, queued.json()["job_id"])
    assert status(stage_http, owner, stage)["status"] == "applied"
    assert (
        post(stage_http, owner, stage, "apply", apply).json()["job_id"] == queued.json()["job_id"]
    )
    undo = {"stage_version": 1, "batch_id": stage["batch_id"]}
    queued = post(stage_http, owner, stage, "undo", undo)
    assert queued.status_code == 200
    assert post(stage_http, owner, stage, "undo", undo).json() == queued.json()
    run(stage_http, postgres_engine, queued.json()["job_id"])
    assert status(stage_http, owner, stage)["status"] == "undone"
    with Session(postgres_engine) as session:
        assert (
            len(
                list(
                    session.scalars(
                        select(ImportPublication).where(
                            ImportPublication.stage_id == UUID(stage["stage_id"])
                        )
                    )
                )
            )
            == 2
        )
        assert (
            session.scalar(
                select(func.count())
                .select_from(SyncEntity)
                .where(SyncEntity.scope_id == owner.book_id, SyncEntity.deleted.is_(False))
            )
            == 1
        )


def test_http_chunk_exact_bounds_order_hash_replay_and_sealed_replay(stage_http, postgres_engine):
    owner = actor(postgres_engine)
    content = b"a" * STAGE_CHUNK_BYTES + b"last"
    stage, body, _ = create(stage_http, postgres_engine, owner, content)
    assert chunk(stage_http, owner, stage, 1, b"last").status_code == 409
    wrong = chunk(stage_http, owner, stage, 0, content[:STAGE_CHUNK_BYTES], digest="0" * 64)
    assert wrong.status_code == 422 and wrong.json()["error"]["code"] == "import_stage_chunk_hash"
    assert chunk(stage_http, owner, stage, 0, b"x" * (STAGE_CHUNK_BYTES + 1)).status_code == 413
    assert chunk(stage_http, owner, stage, 0, b"").status_code == 422
    first = chunk(stage_http, owner, stage, 0, content[:STAGE_CHUNK_BYTES])
    assert first.status_code == 200 and not first.json()["replayed"]
    assert chunk(stage_http, owner, stage, 0, content[:STAGE_CHUNK_BYTES]).json()["replayed"]
    assert chunk(stage_http, owner, stage, 0, b"b" * STAGE_CHUNK_BYTES).status_code == 409
    assert chunk(stage_http, owner, stage, 1, b"last").status_code == 200
    seal_body = {
        "stage_version": 1,
        "total_bytes": len(content),
        "source_sha256": body["source_sha256"],
    }
    seal = post(stage_http, owner, stage, "seal", seal_body)
    assert seal.status_code == 200
    assert (
        post(stage_http, owner, stage, "seal", seal_body).json()["job_id"] == seal.json()["job_id"]
    )
    assert chunk(stage_http, owner, stage, 1, b"last").json()["replayed"]
    assert status(stage_http, owner, stage)["received_bytes"] == len(content)


def test_http_chunk_stream_without_content_length_stops_at_route_limit(stage_http, postgres_engine):
    owner = actor(postgres_engine)
    stage, _, _ = create(stage_http, postgres_engine, owner, b"x" * STAGE_CHUNK_BYTES)
    consumed = []

    def pieces():
        for index in range(9):
            consumed.append(index)
            yield b"x" * 65536

    response = stage_http.put(
        PREFIX + f"/{stage['stage_id']}/chunks/0?stage_version=1",
        headers={
            **headers(owner),
            "content-type": "application/octet-stream",
            "x-chunk-sha256": "0" * 64,
        },
        content=pieces(),
    )
    assert response.status_code == 413
    assert status(stage_http, owner, stage)["received_bytes"] == 0


def test_http_chunk_headers_query_and_no_auth_never_store_bytes(stage_http, postgres_engine):
    owner = actor(postgres_engine)
    content = b"controlled-source-only"
    stage, _, _ = create(stage_http, postgres_engine, owner, content)
    url = PREFIX + f"/{stage['stage_id']}/chunks/0"
    good = {
        **headers(owner),
        "content-type": "application/octet-stream",
        "x-chunk-sha256": hashlib.sha256(content).hexdigest(),
    }
    cases = [
        ("?stage_version=1", good | {"content-type": "application/json"}),
        ("?stage_version=1", good | {"x-chunk-sha256": "BAD"}),
        ("?stage_version=1&stage_version=2", good),
        ("?stage_version=1&url=https://synthetic.invalid/never-fetch", good),
        ("?stage_version=0", good),
    ]
    for query, request_headers in cases:
        denied = stage_http.put(url + query, headers=request_headers, content=content)
        assert denied.status_code == 422
    assert (
        stage_http.put(
            url + "?stage_version=1",
            headers={key: value for key, value in good.items() if key != "authorization"},
            content=content,
        ).status_code
        == 401
    )
    assert (
        stage_http.put(
            url + "?stage_version=1",
            headers=[*good.items(), ("x-chunk-sha256", "1" * 64)],
            content=content,
        ).status_code
        == 422
    )
    assert status(stage_http, owner, stage)["received_bytes"] == 0


@pytest.mark.parametrize("mutation", ["missing_id", "path", "url", "wrong_type"])
def test_http_create_closed_fixed_identifier_and_types(stage_http, postgres_engine, mutation):
    owner = actor(postgres_engine)
    stage, body, _ = create(stage_http, postgres_engine, owner)
    body["stage_id"] = str(uuid4())
    if mutation == "missing_id":
        body.pop("stage_id")
    elif mutation in {"path", "url"}:
        body[mutation] = "synthetic-never-fetch"
    else:
        body["expected_bytes"] = str(body["expected_bytes"])
    response = stage_http.post(PREFIX, headers=headers(owner), json=body)
    assert response.status_code == 422 and "synthetic-never-fetch" not in response.text
    assert status(stage_http, owner, stage)["stage_version"] == 1


def test_http_json_duplicate_nonfinite_depth_and_generic_limit(stage_http, postgres_engine):
    owner = actor(postgres_engine)
    _, body, _ = create(stage_http, postgres_engine, owner)
    body["stage_id"] = str(uuid4())
    raw = json.dumps(body)
    duplicate = raw.replace('"stage_id":', '"stage_id":"' + str(uuid4()) + '","stage_id":', 1)
    for content, expected in (
        (duplicate, 400),
        (raw.replace(str(body["expected_bytes"]), "NaN", 1), 422),
    ):
        response = stage_http.post(
            PREFIX, headers={**headers(owner), "content-type": "application/json"}, content=content
        )
        # A nonfinite typed integer is rejected by FastAPI before our decoder.
        assert response.status_code == expected
    nested = body | {"mapping": {"source_namespace": [[[["x"]]]]}}
    response = stage_http.post(PREFIX, headers=headers(owner), json=nested)
    assert response.status_code == 422
    too_large = stage_http.post(PREFIX, headers=headers(owner), content=b" " * (1024 * 1024 + 1))
    assert too_large.status_code == 413 and too_large.json()["error"]["code"] == "body_too_large"


def test_http_unicode_mapping_version_invalidation_cancel_and_stale_cursor(
    stage_http, postgres_engine
):
    owner = actor(postgres_engine)
    stage, _, _ = create(stage_http, postgres_engine, owner)
    response = stage_http.put(
        PREFIX + f"/{stage['stage_id']}/mapping",
        headers=headers(owner),
        json={"stage_version": 1, "mapping": {"source_namespace": "中文来源"}},
    )
    assert response.status_code == 200 and response.json()["stage_version"] == 2
    assert post(stage_http, owner, stage, "preview", {"stage_version": 1}).status_code == 409
    cancelled = post(stage_http, owner, stage, "cancel", {"stage_version": 2})
    assert cancelled.status_code == 200 and cancelled.json()["status"] == "cancelled"
    assert cancelled.json()["received_bytes"] == 0
    assert post(stage_http, owner, stage, "cancel", {"stage_version": 3}).json() == cancelled.json()
    # Unicode dictionary keys belong to resource-name mappings, unlike sync's ASCII protocol keys.
    _, body, _ = create(stage_http, postgres_engine, owner)
    body["stage_id"], body["format"] = str(uuid4()), "qianji_csv"
    body["mapping"] = {
        "template_mapping": {
            "scope_id": str(owner.book_id),
            "timezone": "Asia/Shanghai",
            "account_names": {"合成现金": str(uuid4())},
        }
    }
    accepted = stage_http.post(PREFIX, headers=headers(owner), json=body)
    assert accepted.status_code == 200, accepted.text


def test_http_owner_origin_reauthorize_current_session_and_fixed_create_conflict(
    stage_http, postgres_engine
):
    owner, foreign = actor(postgres_engine), actor(postgres_engine)
    stage, body, _ = create(stage_http, postgres_engine, owner)
    assert (
        stage_http.get(PREFIX + "/" + stage["stage_id"], headers=headers(foreign)).status_code
        == 404
    )
    foreign_body = body | {"client_id": str(foreign.principal.client_id)}
    assert stage_http.post(PREFIX, headers=headers(foreign), json=foreign_body).status_code == 409
    another = actor(postgres_engine, owner.principal.user_id)
    assert (
        stage_http.get(PREFIX + "/" + stage["stage_id"], headers=headers(another)).status_code
        == 409
    )
    reauth = {
        "stage_version": 1,
        "client_id": str(another.principal.client_id),
        "sync_epoch": body["sync_epoch"],
    }
    response = post(stage_http, another, stage, "reauthorize", reauth)
    assert response.status_code == 200 and response.json()["stage_version"] == 2
    assert post(stage_http, another, stage, "reauthorize", reauth).status_code == 409
    assert (
        stage_http.get(PREFIX + "/" + stage["stage_id"], headers=headers(owner)).status_code == 409
    )
    assert status(stage_http, another, stage)["stage_version"] == 2
    with Session(postgres_engine) as session, session.begin():
        session.get(UserSession, another.principal.session_id).revoked_at = store.stamp(session)
    assert (
        stage_http.get(PREFIX + "/" + stage["stage_id"], headers=headers(another)).status_code
        == 401
    )


def test_http_web_csrf_applies_to_create_and_raw_chunk(stage_http, postgres_engine):
    owner = actor(postgres_engine)
    with Session(postgres_engine) as session, session.begin():
        record, tokens = issue_session(
            session, session.get(User, owner.principal.user_id), uuid4(), "合成stage Web", "api_web"
        )
        client_id = str(record.client_id)
    content = b"synthetic-stage"
    body = {
        "stage_id": str(uuid4()),
        "client_id": client_id,
        "sync_epoch": epoch(postgres_engine),
        "format": "flowtrace_json",
        "expected_bytes": len(content),
        "source_sha256": hashlib.sha256(content).hexdigest(),
    }
    web_headers = {
        "authorization": "Bearer " + tokens["access_token"],
        "origin": "http://testserver",
    }
    assert stage_http.post(PREFIX, headers=web_headers, json=body).status_code == 403
    permitted = stage_http.post(
        PREFIX, headers=web_headers | {"x-csrf-token": tokens["csrf_token"]}, json=body
    )
    assert permitted.status_code == 200
    url = PREFIX + f"/{body['stage_id']}/chunks/0?stage_version=1"
    raw_headers = web_headers | {
        "content-type": "application/octet-stream",
        "x-chunk-sha256": body["source_sha256"],
    }
    assert stage_http.put(url, headers=raw_headers, content=content).status_code == 403
    assert (
        stage_http.put(
            url, headers=raw_headers | {"x-csrf-token": tokens["csrf_token"]}, content=content
        ).status_code
        == 200
    )


def test_http_stale_preview_and_current_revocation_cannot_authorize_apply(
    stage_http, postgres_engine
):
    owner, member = actor(postgres_engine), actor(postgres_engine)
    share(postgres_engine, owner, member)
    stage, current = ready(stage_http, postgres_engine, member, target=owner)
    body = {"stage_version": 1, "batch_id": stage["batch_id"], "preview_hash": "0" * 64}
    assert post(stage_http, member, stage, "apply", body).status_code == 409
    body["preview_hash"] = current["preview_hash"]
    revoke(postgres_engine, owner, member)
    denied = post(stage_http, member, stage, "apply", body)
    # Locks are ordered by scope UUID. A changed own control scope can reject
    # the frozen preview before reaching the now-forbidden shared book.
    assert (denied.status_code, denied.json()["error"]["code"]) in {
        (403, "scope_forbidden"),
        (409, "import_stage_preview_changed"),
    }
    with Session(postgres_engine) as session:
        assert session.get(ImportBatch, UUID(stage["batch_id"])) is None


def test_http_published_explicit_reauth_preserves_apply_hash_then_only_new_origin_undo(
    stage_http, postgres_engine
):
    owner = actor(postgres_engine)
    stage, current = ready(stage_http, postgres_engine, owner)
    body = {
        "stage_version": 1,
        "batch_id": stage["batch_id"],
        "preview_hash": current["preview_hash"],
    }
    applied = post(stage_http, owner, stage, "apply", body)
    run(stage_http, postgres_engine, applied.json()["job_id"])
    with Session(postgres_engine) as session:
        original_hash = session.get(ImportPublication, UUID(stage["stage_id"])).content_hash
    another = actor(postgres_engine, owner.principal.user_id)
    reauth = {
        "stage_version": 1,
        "client_id": str(another.principal.client_id),
        "sync_epoch": epoch(postgres_engine),
    }
    response = post(stage_http, another, stage, "reauthorize", reauth)
    assert response.status_code == 200, response.text
    assert response.json()["status"] == "applied" and response.json()["stage_version"] == 2
    assert post(stage_http, another, stage, "apply", body | {"stage_version": 2}).status_code == 409
    undo = post(
        stage_http, another, stage, "undo", {"stage_version": 2, "batch_id": stage["batch_id"]}
    )
    assert undo.status_code == 200, undo.text
    run(stage_http, postgres_engine, undo.json()["job_id"])
    assert status(stage_http, another, stage)["status"] == "undone"
    with Session(postgres_engine) as session:
        assert session.get(ImportPublication, UUID(stage["stage_id"])).content_hash == original_hash


def test_http_published_reauth_budget_rolls_back_origin_and_version(
    stage_http, postgres_engine, monkeypatch
):
    owner = actor(postgres_engine)
    stage, current = ready(stage_http, postgres_engine, owner)
    body = {
        "stage_version": 1,
        "batch_id": stage["batch_id"],
        "preview_hash": current["preview_hash"],
    }
    applied = post(stage_http, owner, stage, "apply", body)
    run(stage_http, postgres_engine, applied.json()["job_id"])
    another = actor(postgres_engine, owner.principal.user_id)
    calls = 0

    def budget(*_):
        def check():
            nonlocal calls
            calls += 1
            if calls >= 5:
                raise ApiError("import_stage_reauthorization_timeout", 503)

        return check

    monkeypatch.setattr(staging_router, "_reauthorization_budget", budget)
    response = post(
        stage_http,
        another,
        stage,
        "reauthorize",
        {
            "stage_version": 1,
            "client_id": str(another.principal.client_id),
            "sync_epoch": epoch(postgres_engine),
        },
    )
    assert response.status_code == 503 and calls >= 5
    assert status(stage_http, owner, stage)["stage_version"] == 1
    with Session(postgres_engine) as session:
        assert (
            session.get(ImportStage, UUID(stage["stage_id"])).origin_session_id
            == owner.principal.session_id
        )
