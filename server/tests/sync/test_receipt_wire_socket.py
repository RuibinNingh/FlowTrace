"""One owned loopback socket proves production response serialization end to end."""

import socket
from threading import Thread
from time import monotonic, sleep

import httpx
import pytest
import uvicorn
from sqlalchemy.orm import Session

from flowtrace_server.auth.models import UserSession
from flowtrace_server.auth.service import now
from flowtrace_server.config import Settings
from flowtrace_server.main import create_app
from flowtrace_server.sync.canonical import content_hash

from .helpers import actor, epoch, expense, operation
from .test_http import body_for
from .test_receipt_lookup import state
from .test_receipt_tracking import current, headers, http_push, snapshot

pytestmark = pytest.mark.postgres


def test_owned_receipts_socket_create_get_pull_snapshot_wire(postgres_engine, tmp_path):
    owner = actor(postgres_engine)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    # A collision refuses startup. Never connect a test to an unrelated listener.
    listener.bind(("127.0.0.1", 18086))
    listener.listen(128)
    app = create_app(
        Settings(_env_file=None, database_url=None, environment="test", data_directory=tmp_path)
    )
    app.state.engine = postgres_engine
    server = uvicorn.Server(
        uvicorn.Config(app, host="127.0.0.1", port=18086, access_log=False, log_level="error")
    )
    thread = Thread(target=server.run, kwargs={"sockets": [listener]}, daemon=True)
    thread.start()
    try:
        deadline = monotonic() + 10
        while not server.started and thread.is_alive() and monotonic() < deadline:
            sleep(0.01)
        assert server.started
        with httpx.Client(base_url="http://127.0.0.1:18086", timeout=10) as client:
            identifiers = {}
            receipts = []
            for label, changes in {
                "legacy": {},
                "true": {"reimbursement_tracking": True},
                "false": {"reimbursement_tracking": False},
                "income": {"bill_type": "income"},
            }.items():
                command = operation(owner.book_id, "bill", expense(owner.book_id, **changes))
                response = http_push(client, postgres_engine, owner, command)
                assert response.status_code == 200, response.text
                identifiers[command["entity_id"]] = label
                receipts.append((body_for(postgres_engine, owner, [command]), response.json()))
            before_lookup = state(postgres_engine, owner)
            for frozen, original in receipts:
                checked = client.post(
                    "/api/v1/sync/receipts/lookup", json=frozen, headers=headers(owner)
                )
                assert checked.status_code == 200, checked.text
                assert checked.json() == {"results": [{**original["results"][0], "replayed": True}]}
            assert state(postgres_engine, owner) == before_lookup
            scopes = client.get("/api/v1/sync/scopes", headers=headers(owner))
            assert scopes.status_code == 200
            pulled = client.post(
                "/api/v1/sync/pull",
                json={
                    "sync_epoch": epoch(postgres_engine),
                    "cursors": {},
                    "limit": 200,
                    "page_token": None,
                },
                headers=headers(owner),
            )
            assert pulled.status_code == 200
            events = [event for commit in pulled.json()["commits"] for event in commit["events"]]
            _, _, page = snapshot(client, postgres_engine, owner)
            assert content_hash(page["items"]) == page["page_sha256"]
            for batch in (
                events,
                page["items"],
                [current(client, owner, identifier)["event"] for identifier in identifiers],
            ):
                seen = set()
                for event in batch:
                    if event["entity_id"] not in identifiers:
                        continue
                    seen.add(event["entity_id"])
                    label = identifiers[event["entity_id"]]
                    data = event["data"]
                    if label in {"true", "false"}:
                        assert data["payload"]["reimbursement_tracking"] is (label == "true")
                    else:
                        assert "reimbursement_tracking" not in data["payload"]
                    assert ("source_summary" in data) is (label != "income")
                assert seen == set(identifiers)
            for identifier in identifiers:
                command = operation(
                    owner.book_id, "bill", {}, identifier=identifier, action="delete", revision="1"
                )
                assert http_push(client, postgres_engine, owner, command).status_code == 200
    finally:
        server.should_exit = True
        thread.join(timeout=10)
        listener.close()
        with Session(postgres_engine) as session:
            session.get(UserSession, owner.principal.session_id).revoked_at = now()
            session.commit()
    assert not thread.is_alive()
    with socket.socket() as probe:
        assert probe.connect_ex(("127.0.0.1", 18086)) != 0
