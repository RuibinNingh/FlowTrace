"""Existing receipt proof must never execute a frozen command or refresh a lease."""

import json
from copy import deepcopy
from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session

from flowtrace_server.auth.models import UserSession
from flowtrace_server.auth.service import now
from flowtrace_server.books.models import BookMembership, SyncScope
from flowtrace_server.sync.models import (
    LedgerEntry,
    SyncChange,
    SyncClient,
    SyncEntity,
    SyncReceipt,
)

from .helpers import actor, expense, operation, push, revoke, share
from .test_http import body_for

pytestmark = pytest.mark.postgres
LOOKUP = "/api/v1/sync/receipts/lookup"


def lookup(http, owner, body):
    return http.post(LOOKUP, json=body, headers={"authorization": "Bearer " + owner.token})


def state(engine, owner):
    """Snapshot every affected persistent table, including the device/session lease."""
    with Session(engine) as session:
        scopes = [owner.book_id, owner.principal.user_id]
        queries = {
            "entities": select(SyncEntity.__table__).where(SyncEntity.scope_id.in_(scopes)),
            "changes": select(SyncChange.__table__).where(SyncChange.scope_id.in_(scopes)),
            "entries": select(LedgerEntry.__table__).where(
                LedgerEntry.bill_id.in_(
                    select(SyncEntity.id).where(SyncEntity.scope_id.in_(scopes))
                )
            ),
            "scopes": select(SyncScope.__table__).where(SyncScope.id.in_(scopes)),
            "members": select(BookMembership.__table__).where(
                BookMembership.user_id == owner.principal.user_id
            ),
            "receipts": select(SyncReceipt.__table__).where(
                SyncReceipt.user_id == owner.principal.user_id
            ),
            "clients": select(SyncClient.__table__).where(
                SyncClient.user_id == owner.principal.user_id
            ),
            "sessions": select(UserSession.__table__).where(
                UserSession.user_id == owner.principal.user_id
            ),
        }
        return {
            key: sorted(
                (
                    json.dumps(dict(row), sort_keys=True, default=str)
                    for row in session.execute(query).mappings()
                )
            )
            for key, query in queries.items()
        }


def applied(engine, owner):
    command = operation(owner.book_id, "bill", expense(owner.book_id, amount="125"))
    body = body_for(engine, owner, [command])
    result = push(engine, owner, command)[0]
    assert result["status"] == "applied"
    return body, result


def test_lookup_returns_exact_existing_applied_without_any_persistent_change(
    actors, postgres_engine, sync_http
):
    owner, _, _ = actors
    body, original = applied(postgres_engine, owner)
    before = state(postgres_engine, owner)
    for _ in range(2):
        response = lookup(sync_http, owner, body)
        assert response.status_code == 200, response.text
        assert response.json() == {"results": [{**original, "replayed": True}]}
        result = response.json()["results"][0]
        assert set(result) == {
            "operation_id",
            "status",
            "entity_id",
            "revision",
            "commit_id",
            "scope_revisions",
            "replayed",
        }
        assert state(postgres_engine, owner) == before


def test_missing_receipt_never_executes_even_if_original_entity_exists(
    actors, postgres_engine, sync_http
):
    owner, _, _ = actors
    body, _ = applied(postgres_engine, owner)
    with Session(postgres_engine) as session:
        session.delete(
            session.get(
                SyncReceipt,
                (
                    owner.principal.user_id,
                    owner.principal.client_id,
                    UUID(body["operations"][0]["operation_id"]),
                ),
            )
        )
        session.commit()
    before = state(postgres_engine, owner)
    response = lookup(sync_http, owner, body)
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "receipt_not_found"
    assert state(postgres_engine, owner) == before
    new_body = body_for(
        postgres_engine, owner, [operation(owner.book_id, "bill", expense(owner.book_id))]
    )
    response = lookup(sync_http, owner, new_body)
    assert response.status_code == 404
    assert state(postgres_engine, owner) == before


@pytest.mark.parametrize("change", ["amount", "explicit_default"])
def test_hash_uses_original_omission_and_rejects_modified_intent(
    actors, postgres_engine, sync_http, change
):
    owner, _, _ = actors
    body, _ = applied(postgres_engine, owner)
    changed = deepcopy(body)
    payload = changed["operations"][0]["payload"]
    if change == "amount":
        payload["money"]["amount_minor"] = "126"
    else:
        payload["reimbursement_tracking"] = False
    before = state(postgres_engine, owner)
    response = lookup(sync_http, owner, changed)
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "idempotency_mismatch"
    assert state(postgres_engine, owner) == before


@pytest.mark.parametrize(
    "case", ["wrong_client", "wrong_epoch", "missing_client", "expired", "frozen"]
)
def test_lookup_does_not_create_extend_or_unfreeze_device(actors, postgres_engine, sync_http, case):
    owner, _, _ = actors
    body, _ = applied(postgres_engine, owner)
    if case == "wrong_client":
        body["client_id"] = str(uuid4())
    elif case == "wrong_epoch":
        body["sync_epoch"] = str(uuid4())
    else:
        with Session(postgres_engine) as session:
            client = session.get(SyncClient, (owner.principal.user_id, owner.principal.client_id))
            if case == "missing_client":
                session.delete(client)
            elif case == "expired":
                client.valid_until = now() - timedelta(seconds=1)
            else:
                client.frozen = True
            session.commit()
    before = state(postgres_engine, owner)
    response = lookup(sync_http, owner, body)
    assert response.status_code == {"wrong_client": 403, "wrong_epoch": 409}.get(case, 410)
    assert state(postgres_engine, owner) == before


@pytest.mark.parametrize("case", ["revoked", "viewer"])
def test_current_original_scope_write_rights_required(actors, postgres_engine, sync_http, case):
    owner, member, _ = actors
    share(postgres_engine, owner, member)
    command = operation(owner.book_id, "bill", expense(owner.book_id))
    body = body_for(postgres_engine, member, [command])
    assert push(postgres_engine, member, command)[0]["status"] == "applied"
    if case == "revoked":
        revoke(postgres_engine, owner, member)
    else:
        with Session(postgres_engine) as session:
            membership = session.get(BookMembership, (owner.book_id, member.principal.user_id))
            membership.role = "viewer"
            session.get(SyncScope, owner.book_id).permission_version += 1
            session.commit()
    before = state(postgres_engine, member)
    response = lookup(sync_http, member, body)
    assert response.status_code == 403
    assert state(postgres_engine, member) == before


def test_different_device_cannot_read_another_devices_receipt(actors, postgres_engine, sync_http):
    owner, _, _ = actors
    body, _ = applied(postgres_engine, owner)
    second = actor(postgres_engine, existing_user=owner.principal.user_id)
    applied(postgres_engine, second)  # Establish its own valid SyncClient only.
    body["client_id"] = str(second.principal.client_id)
    before = state(postgres_engine, owner)
    response = lookup(sync_http, second, body)
    assert response.status_code == 404
    assert state(postgres_engine, owner) == before


def test_revoked_secondary_source_scope_blocks_receipt_even_with_primary_scope(
    actors, postgres_engine, sync_http
):
    owner, foreign, _ = actors
    share(postgres_engine, foreign, owner)
    source = operation(foreign.book_id, "bill", expense(foreign.book_id, amount="10000"))
    assert push(postgres_engine, owner, source)[0]["status"] == "applied"
    command = operation(
        owner.book_id,
        "bill",
        expense(
            owner.book_id,
            amount="3000",
            bill_type="refund",
            allocations=[
                {
                    "source_bill_id": source["entity_id"],
                    "source_amount_minor": "3000",
                    "receipt_amount_minor": "3000",
                    "rate": None,
                }
            ],
        ),
    )
    original = push(postgres_engine, owner, command)[0]
    assert original["status"] == "applied"
    body = body_for(postgres_engine, owner, [command])
    before = state(postgres_engine, owner)
    response = lookup(sync_http, owner, body)
    assert response.status_code == 200, response.text
    assert response.json()["results"][0]["scope_revisions"] == original["scope_revisions"]
    assert state(postgres_engine, owner) == before
    revoke(postgres_engine, foreign, owner)
    before = state(postgres_engine, owner)
    response = lookup(sync_http, owner, body)
    assert response.status_code == 403
    assert response.json()["error"]["details"] == {}
    assert state(postgres_engine, owner) == before


def test_revoked_session_cannot_read_old_success(actors, postgres_engine, sync_http):
    owner, _, _ = actors
    body, _ = applied(postgres_engine, owner)
    with Session(postgres_engine) as session:
        session.get(UserSession, owner.principal.session_id).revoked_at = now()
        session.commit()
    before = state(postgres_engine, owner)
    response = lookup(sync_http, owner, body)
    assert response.status_code == 401
    assert state(postgres_engine, owner) == before


def test_rejected_receipt_does_not_expose_current_projection_or_apply(
    actors, postgres_engine, sync_http
):
    owner, _, _ = actors
    body, _ = applied(postgres_engine, owner)
    command = deepcopy(body["operations"][0])
    command["operation_id"] = str(uuid4())
    assert push(postgres_engine, owner, command)[0]["status"] == "rejected"
    rejected_body = body_for(postgres_engine, owner, [command])
    before = state(postgres_engine, owner)
    response = lookup(sync_http, owner, rejected_body)
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "receipt_not_applied"
    assert response.json()["error"]["details"] == {}
    assert state(postgres_engine, owner) == before


@pytest.mark.parametrize("case", ["empty", "two", "bool", "null", "unknown", "duplicate"])
def test_closed_single_raw_request_validation(actors, postgres_engine, sync_http, case):
    owner, _, _ = actors
    body, _ = applied(postgres_engine, owner)
    if case == "empty":
        body["operations"] = []
    elif case == "two":
        body["operations"].append(operation(owner.book_id, "bill", expense(owner.book_id)))
    elif case == "bool":
        body["protocol_version"] = True
    elif case == "null":
        body["operations"] = None
    elif case == "unknown":
        body["extra"] = "must_reject"
    raw = json.dumps(body)
    if case == "duplicate":
        raw = raw.replace('"protocol_version": 1', '"protocol_version": 1, "protocol_version": 1')
    before = state(postgres_engine, owner)
    response = sync_http.post(
        LOOKUP,
        content=raw,
        headers={"authorization": "Bearer " + owner.token, "content-type": "application/json"},
    )
    assert response.status_code == (400 if case == "duplicate" else 422)
    assert state(postgres_engine, owner) == before
