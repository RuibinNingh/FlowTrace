import json
from uuid import UUID

import pytest
from sqlalchemy.orm import Session

from flowtrace_server.sync.models import SyncEntity

from .helpers import epoch, expense, operation

pytestmark = pytest.mark.postgres


def body_for(engine, actor, commands):
    return {
        "protocol_version": 1,
        "client_id": str(actor.principal.client_id),
        "sync_epoch": epoch(engine),
        "operations": commands,
    }


def test_http_strict_raw_input_and_single_conflict_status(actors, postgres_engine, sync_http):
    alice, _, _ = actors
    headers = {"authorization": "Bearer " + alice.token}
    command = operation(alice.book_id, "bill", expense(alice.book_id))
    body = body_for(postgres_engine, alice, [command])
    raw = (
        json.dumps(body)
        .encode()
        .replace(b'"protocol_version": 1', b'"protocol_version": 1, "protocol_version": 1')
    )
    duplicate = sync_http.post(
        "/api/v1/sync/push", content=raw, headers={**headers, "content-type": "application/json"}
    )
    assert duplicate.status_code == 400
    assert (
        sync_http.post(
            "/api/v1/sync/push", json={**body, "protocol_version": True}, headers=headers
        ).status_code
        == 422
    )
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, UUID(command["entity_id"])) is None
    first = sync_http.post("/api/v1/sync/push", json=body, headers=headers)
    assert first.status_code == 200, first.text
    assert first.json()["results"][0]["status"] == "applied"
    assert (
        sync_http.post("/api/v1/sync/push", json=body, headers=headers).json()["results"][0][
            "replayed"
        ]
        is True
    )
    body["operations"][0]["payload"]["money"]["amount_minor"] = "200"
    conflict = sync_http.post("/api/v1/sync/push", json=body, headers=headers)
    assert (
        conflict.status_code == 409 and conflict.json()["error"]["code"] == "idempotency_mismatch"
    )
    assert "payload" not in conflict.text
    read = sync_http.get(
        f"/api/v1/sync/entities/bill/{command['entity_id']}",
        params={"scope_id": str(alice.book_id)},
        headers=headers,
    )
    assert (
        read.status_code == 200
        and read.json()["editable_payload"]["money"]["amount_minor"] == "100"
    )
    scopes = sync_http.get("/api/v1/sync/scopes", headers=headers)
    assert scopes.status_code == 200 and scopes.json()["sync_epoch"] == body["sync_epoch"]
