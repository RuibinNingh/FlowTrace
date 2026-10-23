import json
from copy import deepcopy
from uuid import UUID

import pytest
from sqlalchemy.orm import Session

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.sync.models import SyncEntity
from flowtrace_server.sync.reader import create_snapshot, pull, read_entity, snapshot_page
from flowtrace_server.sync.responses import EntityReadResponse, PullResponse, SnapshotStatus
from flowtrace_server.sync.schemas import PullRequest, SnapshotPageRequest, SnapshotRequest

from .helpers import account, epoch, expense, money, operation, push, revoke, share

pytestmark = pytest.mark.postgres


def test_private_account_projection_metadata_edit_and_revocation(actors, postgres_engine):
    alice, bob, _ = actors
    share(postgres_engine, bob, alice)
    private = account(postgres_engine, alice)
    command = operation(
        bob.book_id, "bill", expense(bob.book_id, private, note="合成共享备注_不得进入私域")
    )
    first = push(postgres_engine, alice, command)[0]
    assert first["status"] == "applied", first
    identifier = UUID(command["entity_id"])
    with Session(postgres_engine) as session:
        public = read_entity(session, bob.principal, "bill", identifier, bob.book_id)
        full = read_entity(session, alice.principal, "bill", identifier, bob.book_id)
    EntityReadResponse.model_validate(public)
    EntityReadResponse.model_validate(full)
    assert public["editable_payload"] is None
    assert str(private) not in json.dumps(public)
    assert full["editable_payload"]["account_id"] == str(private)
    metadata = deepcopy(public["event"]["data"]["payload"])
    metadata["note"] = "合成改后共享备注_不得进入私域"
    metadata["preserve_hidden_financial_links"] = True
    update = operation(
        bob.book_id, "bill", metadata, identifier=identifier, action="update", revision="1"
    )
    assert push(postgres_engine, bob, update)[0]["status"] == "applied"
    malicious = deepcopy(update)
    from uuid import uuid4

    malicious["operation_id"] = str(uuid4())
    malicious["base_revision"] = "2"
    malicious["payload"]["money"] = money("200")
    assert (
        push(postgres_engine, bob, malicious)[0]["error"]["code"]
        == "hidden_financial_fields_changed"
    )
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, private).balance_minor == 99900
        assert session.get(SyncEntity, identifier).revision == 2
    revoke(postgres_engine, bob, alice)
    with Session(postgres_engine) as session:
        finance = read_entity(session, alice.principal, "bill", identifier, alice.principal.user_id)
        snapshot = create_snapshot(
            session,
            alice.principal,
            SnapshotRequest.model_validate(
                {
                    "protocol_version": 1,
                    "sync_epoch": epoch(postgres_engine),
                    "client_id": str(alice.principal.client_id),
                    "scope_ids": [str(alice.principal.user_id)],
                }
            ),
        )
        page = snapshot_page(
            session,
            alice.principal,
            UUID(snapshot["snapshot_id"]),
            SnapshotPageRequest.model_validate(
                {
                    "client_id": str(alice.principal.client_id),
                    "page_token": snapshot["first_page_token"],
                }
            ),
        )
    SnapshotStatus.model_validate(snapshot)
    EntityReadResponse.model_validate(finance)
    assert finance["event"]["data"]["projection_kind"] == "bill_private_finance"
    assert (
        finance["event"]["revision"] == "1"
    )  # Shared metadata never revises private financial history.
    assert str(private) in json.dumps(finance)
    assert "备注" not in json.dumps(finance, ensure_ascii=False)
    assert "备注" not in json.dumps(page, ensure_ascii=False)
    assert "attachment_ids" not in json.dumps(finance)
    with Session(postgres_engine) as session:
        with pytest.raises(ApiError):
            read_entity(session, alice.principal, "bill", identifier, bob.book_id)


def test_syn10_cross_scope_commit_is_not_split_or_leaked(actors, postgres_engine):
    alice, bob, _ = actors
    share(postgres_engine, alice, bob)
    private = account(postgres_engine, alice)
    shared = account(postgres_engine, alice, opening="0", shared=True)
    with Session(postgres_engine) as session:
        from flowtrace_server.sync.reader import list_scopes

        control = list_scopes(session, alice.principal)
    cursors = {row["scope_id"]: row["revision"] for row in control["scopes"]}
    transfer = operation(
        alice.book_id,
        "bill",
        expense(
            alice.book_id,
            bill_type="transfer",
            from_account_id=str(private),
            to_account_id=str(shared),
        ),
    )
    applied = push(postgres_engine, alice, transfer)[0]
    assert applied["status"] == "applied", applied
    with Session(postgres_engine) as session:
        own = pull(
            session,
            alice.principal,
            PullRequest.model_validate(
                {
                    "sync_epoch": epoch(postgres_engine),
                    "cursors": cursors,
                    "limit": 1,
                    "page_token": None,
                }
            ),
        )
        other = pull(
            session,
            bob.principal,
            PullRequest.model_validate(
                {
                    "sync_epoch": epoch(postgres_engine),
                    "cursors": {},
                    "limit": 200,
                    "page_token": None,
                }
            ),
        )
    PullResponse.model_validate(own)
    PullResponse.model_validate(other)
    group = next(commit for commit in own["commits"] if commit["commit_id"] == applied["commit_id"])
    assert len(group["events"]) == 4
    assert own["next_page_token"] is None
    assert own["checkpoint"] is not None
    assert str(private) not in json.dumps(other)
    public_group = next(
        commit for commit in other["commits"] if commit["commit_id"] == applied["commit_id"]
    )
    assert len(public_group["events"]) == 2
    finance = next(
        event["data"]
        for event in group["events"]
        if event["data"]["projection_kind"] == "bill_private_finance"
    )
    assert str(shared) not in json.dumps(finance)
    public = next(
        event["data"] for event in public_group["events"] if event["entity_type"] == "bill"
    )
    metadata = {
        **public["payload"],
        "note": "仅改合成备注",
        "preserve_hidden_financial_links": True,
    }
    update = operation(
        alice.book_id,
        "bill",
        metadata,
        identifier=UUID(transfer["entity_id"]),
        action="update",
        revision="1",
    )
    assert push(postgres_engine, bob, update)[0]["status"] == "applied"
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, private).balance_minor == 99900
        assert session.get(SyncEntity, shared).balance_minor == 100


def test_cross_book_refund_redacts_source_but_authorized_read_reconstructs(actors, postgres_engine):
    alice, bob, _ = actors
    share(postgres_engine, bob, alice)
    private = account(postgres_engine, alice)
    source = operation(alice.book_id, "bill", expense(alice.book_id))
    assert push(postgres_engine, alice, source)[0]["status"] == "applied"
    refund = operation(
        bob.book_id,
        "bill",
        expense(
            bob.book_id,
            private,
            "50",
            bill_type="refund",
            allocations=[
                {
                    "source_bill_id": source["entity_id"],
                    "source_amount_minor": "50",
                    "receipt_amount_minor": "50",
                }
            ],
        ),
    )
    result = push(postgres_engine, alice, refund)[0]
    assert result["status"] == "applied", result
    with Session(postgres_engine) as session:
        other = read_entity(session, bob.principal, "bill", UUID(refund["entity_id"]), bob.book_id)
        own = read_entity(session, alice.principal, "bill", UUID(refund["entity_id"]), bob.book_id)
    assert other["event"]["data"]["hidden_allocation_count"] == 1
    assert source["entity_id"] not in json.dumps(other)
    assert str(private) not in json.dumps(other)
    assert own["editable_payload"]["allocations"][0]["source_bill_id"] == source["entity_id"]
    metadata = {
        **other["event"]["data"]["payload"],
        "note": "合成跨本备注",
        "preserve_hidden_financial_links": True,
    }
    update = operation(
        bob.book_id,
        "bill",
        metadata,
        identifier=UUID(refund["entity_id"]),
        action="update",
        revision="1",
    )
    assert push(postgres_engine, bob, update)[0]["status"] == "applied"
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, private).balance_minor == 100050
