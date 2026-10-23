"""Real PostgreSQL and production HTTP acceptance for tracking/projection only.

Linked-source policy A and typed restructuring remain separate later slices.
"""

import json
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from pathlib import Path
from threading import Barrier
from uuid import UUID

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from flowtrace_server.sync.canonical import content_hash
from flowtrace_server.sync.models import (
    LedgerEntry,
    PullPage,
    PullSession,
    SnapshotPage,
    SyncChange,
    SyncEntity,
    SyncReceipt,
    SyncSnapshot,
)

from .helpers import account, epoch, expense, money, operation, push, revoke, share
from .test_http import body_for

pytestmark = pytest.mark.postgres
ROOT = Path(__file__).resolve().parents[3]
VECTORS = json.loads(
    (ROOT / "contracts/fixtures/ledger/refund-reimbursement.json").read_text("utf-8")
)


def headers(actor):
    return {"authorization": "Bearer " + actor.token}


def http_push(client, engine, actor, command):
    return client.post(
        "/api/v1/sync/push",
        json=body_for(engine, actor, [command]),
        headers=headers(actor),
    )


def current(client, actor, identifier, scope=None):
    reply = client.get(
        f"/api/v1/sync/entities/bill/{identifier}",
        params={"scope_id": str(scope or actor.book_id)},
        headers=headers(actor),
    )
    assert reply.status_code == 200, reply.text
    return reply.json()


def snapshot(client, engine, actor):
    reply = client.post(
        "/api/v1/sync/snapshots",
        json={
            "protocol_version": 1,
            "client_id": str(actor.principal.client_id),
            "sync_epoch": epoch(engine),
            "scope_ids": [str(actor.book_id)],
        },
        headers=headers(actor),
    )
    assert reply.status_code == 201, reply.text
    status = reply.json()
    body = {
        "client_id": str(actor.principal.client_id),
        "page_token": status["first_page_token"],
    }
    reply = client.post(
        f"/api/v1/sync/snapshots/{status['snapshot_id']}/pages",
        json=body,
        headers=headers(actor),
    )
    assert reply.status_code == 200, reply.text
    return status, body, reply.json()


def receipt(owner, source_id, *, kind="refund", amount="3000", account_id=None):
    return operation(
        owner.book_id,
        "bill",
        expense(
            owner.book_id,
            account_id,
            amount=amount,
            bill_type=kind,
            allocations=[
                {
                    "source_bill_id": str(source_id),
                    "source_amount_minor": amount,
                    "receipt_amount_minor": amount,
                    "rate": None,
                }
            ],
        ),
    )


def summary(refunded, reimbursed, remaining, reason="open"):
    return {
        "refund_source_minor": str(refunded),
        "reimbursement_source_minor": str(reimbursed),
        "remaining_source_minor": str(remaining),
        "settlement_reason": reason,
    }


def test_real_http_strict_tracking_vectors_and_no_invalid_rows(actors, postgres_engine, sync_http):
    alice, _, _ = actors
    for vector in VECTORS["tracking_vectors"]:
        payload = deepcopy(vector["payload"])
        payload["book_id"] = str(alice.book_id)
        payload["account_id"] = None
        command = operation(alice.book_id, "bill", payload)
        reply = http_push(sync_http, postgres_engine, alice, command)
        if vector["accepted"]:
            assert reply.status_code == 200, (vector["id"], reply.text)
            read = current(sync_http, alice, command["entity_id"])
            expected = (
                {"reimbursement_tracking": payload["reimbursement_tracking"]}
                if "reimbursement_tracking" in payload
                else {}
            )
            for wire in (read["event"]["data"]["payload"], read["editable_payload"]):
                assert {k: v for k, v in wire.items() if k == "reimbursement_tracking"} == expected
        else:
            assert reply.status_code == 422, (vector["id"], reply.text)
            with Session(postgres_engine) as session:
                assert session.get(SyncEntity, UUID(command["entity_id"])) is None
                assert (
                    session.get(
                        SyncReceipt,
                        (
                            alice.principal.user_id,
                            alice.principal.client_id,
                            UUID(command["operation_id"]),
                        ),
                    )
                    is None
                )


def test_same_expense_omission_preserves_presence_and_type_change_does_not_inherit(
    actors, postgres_engine, sync_http
):
    alice, _, _ = actors
    command = operation(alice.book_id, "bill", expense(alice.book_id))
    assert http_push(sync_http, postgres_engine, alice, command).status_code == 200
    identifier = command["entity_id"]
    with Session(postgres_engine) as session:
        first_change = session.scalar(
            select(SyncChange).where(
                SyncChange.entity_id == UUID(identifier), SyncChange.revision == 1
            )
        )
        original_change_hash = content_hash(first_change.data)
    # The same operation's explicit false is a different frozen body, not a
    # semantically equivalent legacy request that can replay a cached receipt.
    altered = deepcopy(command)
    altered["payload"]["reimbursement_tracking"] = False
    mismatch = http_push(sync_http, postgres_engine, alice, altered)
    assert mismatch.status_code == 409
    assert mismatch.json()["error"]["code"] == "idempotency_mismatch"
    for revision, changes, present, value in [
        ("1", {"note": "legacy-omission"}, False, None),
        ("2", {"reimbursement_tracking": True}, True, True),
        ("3", {"note": "old-client-omits-true"}, True, True),
        ("4", {"reimbursement_tracking": False}, True, False),
        ("5", {"note": "old-client-omits-false"}, True, False),
        ("6", {"bill_type": "income"}, False, None),
    ]:
        payload = {**expense(alice.book_id), **changes}
        update = operation(
            alice.book_id,
            "bill",
            payload,
            identifier=identifier,
            action="update",
            revision=revision,
        )
        assert http_push(sync_http, postgres_engine, alice, update).status_code == 200
        read = current(sync_http, alice, identifier)
        for payload in (read["event"]["data"]["payload"], read["editable_payload"]):
            assert ("reimbursement_tracking" in payload) is present
            if present:
                assert payload["reimbursement_tracking"] is value
        with Session(postgres_engine) as session:
            raw = session.get(SyncEntity, UUID(identifier)).payload
            assert ("reimbursement_tracking" in raw) is present
        if changes.get("bill_type") == "income":
            assert "source_summary" not in read["event"]["data"]
            assert (
                "reimbursement_tracking"
                not in read["event"]["data"]["nonfinancial_editable_fields"]
            )
    with Session(postgres_engine) as session:
        first_change = session.scalar(
            select(SyncChange).where(
                SyncChange.entity_id == UUID(identifier), SyncChange.revision == 1
            )
        )
        assert content_hash(first_change.data) == original_change_hash
        assert "reimbursement_tracking" not in first_change.data["payload"]


def test_create_get_pull_snapshot_wire_preserves_absence_true_false_and_nonexpense(
    actors, postgres_engine, sync_http
):
    alice, _, _ = actors
    identifiers = {}
    for label, changes in {
        "absent": {},
        "true": {"reimbursement_tracking": True},
        "false": {"reimbursement_tracking": False},
        "income": {"bill_type": "income"},
    }.items():
        command = operation(alice.book_id, "bill", expense(alice.book_id, **changes))
        assert http_push(sync_http, postgres_engine, alice, command).status_code == 200
        identifiers[command["entity_id"]] = label
    reply = sync_http.post(
        "/api/v1/sync/pull",
        json={
            "sync_epoch": epoch(postgres_engine),
            "cursors": {},
            "limit": 200,
            "page_token": None,
        },
        headers=headers(alice),
    )
    assert reply.status_code == 200, reply.text
    pulls = [event for commit in reply.json()["commits"] for event in commit["events"]]
    _, _, page = snapshot(sync_http, postgres_engine, alice)
    assert content_hash(page["items"]) == page["page_sha256"]
    gets = [current(sync_http, alice, identifier)["event"] for identifier in identifiers]
    for collection in (pulls, page["items"], gets):
        found = set()
        for event in collection:
            if (
                event["entity_id"] not in identifiers
                or event["data"]["projection_kind"] != "bill_public"
            ):
                continue
            label = identifiers[event["entity_id"]]
            found.add(event["entity_id"])
            data = event["data"]
            if label in {"true", "false"}:
                assert data["payload"]["reimbursement_tracking"] is (label == "true")
            else:
                assert "reimbursement_tracking" not in data["payload"]
            if label == "income":
                assert "source_summary" not in data
                assert "reimbursement_tracking" not in data["nonfinancial_editable_fields"]
            else:
                assert data["source_summary"] == summary(0, 0, 100)
                assert "reimbursement_tracking" in data["nonfinancial_editable_fields"]
        assert found == set(identifiers)
    info = sync_http.get("/api/v1/server-info").json()
    assert "receipt-tracking-v1" not in json.dumps(info)
    assert "receipt-restructure-v1" not in json.dumps(info)
    conflicts = [
        operation(
            alice.book_id,
            "bill",
            expense(alice.book_id, bill_type="income" if label == "income" else "expense"),
            identifier=identifier,
            action="update",
            revision="0",
        )
        for identifier, label in identifiers.items()
        if label in {"income", "absent"}
    ]
    reply = sync_http.post(
        "/api/v1/sync/push",
        json=body_for(postgres_engine, alice, conflicts),
        headers=headers(alice),
    )
    assert reply.status_code == 200
    for item in reply.json()["results"]:
        assert item["status"] == "rejected"
        data = item["error"]["current"]["data"]
        assert "reimbursement_tracking" not in data["payload"]
        if data["payload"]["bill_type"] == "income":
            assert "source_summary" not in data


def test_materialized_legacy_pull_snapshot_keep_original_objects_and_hashes(
    actors, postgres_engine, sync_http
):
    alice, _, _ = actors
    first = operation(alice.book_id, "bill", expense(alice.book_id))
    second = operation(alice.book_id, "bill", expense(alice.book_id, bill_type="income"))
    assert push(postgres_engine, alice, [first, second])[1]["status"] == "applied"
    request = {"sync_epoch": epoch(postgres_engine), "cursors": {}, "limit": 1, "page_token": None}
    first_pull = sync_http.post("/api/v1/sync/pull", json=request, headers=headers(alice)).json()
    token = first_pull["next_page_token"]
    assert token
    status, snapshot_body, _ = snapshot(sync_http, postgres_engine, alice)

    def strip(events):
        for event in events:
            data = event["data"]
            if data and data["projection_kind"] == "bill_public":
                data.pop("source_summary", None)
                data["payload"].pop("reimbursement_tracking", None)
                data["nonfinancial_editable_fields"] = [
                    value
                    for value in data["nonfinancial_editable_fields"]
                    if value != "reimbursement_tracking"
                ]

    from flowtrace_server.auth.service import digest

    with Session(postgres_engine) as session:
        pull_page = session.get(PullPage, digest(token))
        record = session.get(PullSession, pull_page.pull_id)
        assert record.user_id == alice.principal.user_id
        old_pull = deepcopy(pull_page.response)
        strip([event for commit in old_pull["commits"] for event in commit["events"]])
        pull_page.response = old_pull
        snap = session.get(SyncSnapshot, UUID(status["snapshot_id"]))
        row = session.scalar(select(SnapshotPage).where(SnapshotPage.snapshot_id == snap.id))
        old_snapshot = deepcopy(row.response)
        strip(old_snapshot["items"])
        old_snapshot["page_sha256"] = content_hash(old_snapshot["items"])
        row.response = old_snapshot
        manifest = deepcopy(snap.manifest)
        manifest["pages"][0]["sha256"] = old_snapshot["page_sha256"]
        snap.manifest, snap.manifest_sha256 = manifest, content_hash(manifest)
        session.commit()
    old_pull_hash, old_snapshot_hash = content_hash(old_pull), content_hash(old_snapshot)
    read_pull = sync_http.post(
        "/api/v1/sync/pull", json={**request, "page_token": token}, headers=headers(alice)
    )
    assert read_pull.status_code == 200, read_pull.text
    assert read_pull.json() == old_pull
    assert content_hash(read_pull.json()) == old_pull_hash
    read_snapshot = sync_http.post(
        f"/api/v1/sync/snapshots/{status['snapshot_id']}/pages",
        json=snapshot_body,
        headers=headers(alice),
    )
    assert read_snapshot.status_code == 200, read_snapshot.text
    assert read_snapshot.json() == old_snapshot
    assert content_hash(read_snapshot.json()) == old_snapshot_hash
    _, _, fresh = snapshot(sync_http, postgres_engine, alice)
    source = next(event for event in fresh["items"] if event["entity_id"] == first["entity_id"])
    assert source["data"]["source_summary"] == summary(0, 0, 100)


def test_receipt_create_update_delete_source_revision_same_commit_replay_no_double_posting(
    actors, postgres_engine, sync_http
):
    alice, _, _ = actors
    bank = account(postgres_engine, alice)
    source = operation(alice.book_id, "bill", expense(alice.book_id, bank, amount="10000"))
    assert push(postgres_engine, alice, source)[0]["status"] == "applied"
    refund = receipt(alice, source["entity_id"], amount="3000", account_id=bank)
    reimbursement = receipt(
        alice, source["entity_id"], kind="reimbursement", amount="2000", account_id=bank
    )
    amended = operation(
        alice.book_id,
        "bill",
        {
            **refund["payload"],
            "money": money("4000"),
            "allocations": [
                {
                    "source_bill_id": source["entity_id"],
                    "source_amount_minor": "4000",
                    "receipt_amount_minor": "4000",
                    "rate": None,
                }
            ],
        },
        identifier=refund["entity_id"],
        action="update",
        revision="1",
    )
    removed = operation(
        alice.book_id,
        "bill",
        {},
        identifier=reimbursement["entity_id"],
        action="delete",
        revision="1",
    )
    for revision, command, expected in [
        (2, refund, summary(3000, 0, 7000)),
        (3, reimbursement, summary(3000, 2000, 5000)),
        (4, amended, summary(4000, 2000, 4000)),
        (5, removed, summary(4000, 0, 6000)),
    ]:
        reply = http_push(sync_http, postgres_engine, alice, command)
        assert reply.status_code == 200, reply.text
        result = reply.json()["results"][0]
        read = current(sync_http, alice, source["entity_id"])
        assert read["event"]["revision"] == str(revision)
        assert read["event"]["data"]["source_summary"] == expected
        with Session(postgres_engine) as session:
            events = list(
                session.scalars(
                    select(SyncChange).where(SyncChange.commit_id == UUID(result["commit_id"]))
                )
            )
            source_event = next(
                event
                for event in events
                if str(event.entity_id) == source["entity_id"] and event.scope_id == alice.book_id
            )
            assert source_event.revision == revision
            assert source_event.data["source_summary"] == expected
            assert any(str(event.entity_id) == command["entity_id"] for event in events)
    replay = http_push(sync_http, postgres_engine, alice, removed)
    assert replay.status_code == 200 and replay.json()["results"][0]["replayed"] is True
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, UUID(source["entity_id"])).revision == 5
        assert session.get(SyncEntity, bank).balance_minor == 94000
        assert (
            session.scalar(
                select(func.count())
                .select_from(LedgerEntry)
                .where(LedgerEntry.bill_id == UUID(source["entity_id"]))
            )
            == 1
        )
        private_source = list(
            session.scalars(
                select(SyncChange).where(
                    SyncChange.scope_id == alice.principal.user_id,
                    SyncChange.entity_id == UUID(source["entity_id"]),
                )
            )
        )
        assert len(private_source) == 1  # Aggregate refresh never duplicates expense finance.
        assert private_source[0].data["entries"][0]["money"]["amount_minor"] == "-10000"


def test_foreign_receipts_only_expose_source_aggregate_and_viewer_cannot_write(
    actors, postgres_engine, sync_http
):
    alice, bob, carol = actors
    share(postgres_engine, alice, bob, "viewer")
    share(postgres_engine, carol, alice)
    bank = account(postgres_engine, alice)
    source = operation(alice.book_id, "bill", expense(alice.book_id, bank, amount="10000"))
    push(postgres_engine, alice, source)
    foreign = receipt(carol, source["entity_id"], amount="3000", account_id=bank)
    foreign["payload"]["note"] = "private-foreign-receipt-note-never-shared"
    assert push(postgres_engine, alice, foreign)[0]["status"] == "applied"
    reply = current(sync_http, bob, source["entity_id"], alice.book_id)
    assert reply["event"]["revision"] == "2"
    assert reply["event"]["data"]["source_summary"] == summary(3000, 0, 7000)
    encoded = json.dumps(reply)
    for secret in (foreign["entity_id"], str(carol.book_id), str(bank), foreign["payload"]["note"]):
        assert secret not in encoded
    assert reply["editable_payload"] is None
    denied = operation(
        alice.book_id,
        "bill",
        expense(alice.book_id, reimbursement_tracking=True),
        identifier=source["entity_id"],
        action="update",
        revision="2",
    )
    assert http_push(sync_http, postgres_engine, bob, denied).status_code == 403
    revoke(postgres_engine, alice, bob)
    assert (
        sync_http.get(
            f"/api/v1/sync/entities/bill/{source['entity_id']}",
            params={"scope_id": str(alice.book_id)},
            headers=headers(bob),
        ).status_code
        == 403
    )


def test_shared_editor_tracking_metadata_preserves_hidden_finance_and_legacy_omission(
    actors, postgres_engine, sync_http
):
    alice, bob, _ = actors
    share(postgres_engine, bob, alice)
    bank = account(postgres_engine, alice)
    source = operation(bob.book_id, "bill", expense(bob.book_id, bank, amount="10000"))
    push(postgres_engine, alice, source)
    with Session(postgres_engine) as session:
        before = [
            (row.id, row.amount_minor)
            for row in session.scalars(
                select(LedgerEntry).where(LedgerEntry.bill_id == UUID(source["entity_id"]))
            )
        ]
    for revision, setting in [("1", True), ("2", None), ("3", False)]:
        read = current(sync_http, bob, source["entity_id"])
        payload = read["event"]["data"]["payload"]
        payload.pop("reimbursement_tracking", None)
        if setting is not None:
            payload["reimbursement_tracking"] = setting
        payload["preserve_hidden_financial_links"] = True
        payload["note"] = "shared-expense-metadata-only"
        command = operation(
            bob.book_id,
            "bill",
            payload,
            identifier=source["entity_id"],
            action="update",
            revision=revision,
        )
        reply = http_push(sync_http, postgres_engine, bob, command)
        assert reply.status_code == 200, reply.text
    with Session(postgres_engine) as session:
        entity = session.get(SyncEntity, UUID(source["entity_id"]))
        assert entity.payload["reimbursement_tracking"] is False
        assert entity.payload["account_id"] == str(bank)
        assert session.get(SyncEntity, bank).balance_minor == 90000
        assert [
            (row.id, row.amount_minor)
            for row in session.scalars(select(LedgerEntry).where(LedgerEntry.bill_id == entity.id))
        ] == before


def test_aggregate_and_revision_rollback_together_before_commit_and_retry_once(
    actors, postgres_engine, sync_http
):
    alice, _, _ = actors
    bank = account(postgres_engine, alice)
    source = operation(alice.book_id, "bill", expense(alice.book_id, bank, amount="10000"))
    push(postgres_engine, alice, source)
    command = receipt(alice, source["entity_id"], amount="3000", account_id=bank)

    def fail(_operation, _result):
        raise RuntimeError("injected_before_commit")

    with pytest.raises(RuntimeError, match="injected_before_commit"):
        push(postgres_engine, alice, command, before_commit=fail)
    read = current(sync_http, alice, source["entity_id"])
    assert read["event"]["revision"] == "1"
    assert read["event"]["data"]["source_summary"] == summary(0, 0, 10000)
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, UUID(command["entity_id"])) is None
        assert session.get(SyncEntity, bank).balance_minor == 90000
        assert (
            session.get(
                SyncReceipt,
                (alice.principal.user_id, alice.principal.client_id, UUID(command["operation_id"])),
            )
            is None
        )
    assert http_push(sync_http, postgres_engine, alice, command).status_code == 200
    assert current(sync_http, alice, source["entity_id"])["event"]["revision"] == "2"


def test_two_foreign_receipts_serialize_on_source_and_never_overallocate(
    actors, postgres_engine, sync_http
):
    alice, bob, carol = actors
    share(postgres_engine, alice, bob)
    share(postgres_engine, alice, carol)
    source = operation(alice.book_id, "bill", expense(alice.book_id, amount="10000"))
    push(postgres_engine, alice, source)
    barrier = Barrier(2)

    def send(actor, kind):
        command = receipt(actor, source["entity_id"], kind=kind, amount="7000")
        barrier.wait(timeout=5)
        return push(postgres_engine, actor, command)[0]

    with ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(send, bob, "refund")
        second = pool.submit(send, carol, "reimbursement")
        results = [first.result(timeout=15), second.result(timeout=15)]
    assert sorted(row["status"] for row in results) == ["applied", "rejected"]
    rejected = next(row for row in results if row["status"] == "rejected")
    assert rejected["error"]["code"] == "allocation.exceeds_remaining"
    read = current(sync_http, alice, source["entity_id"])
    assert read["event"]["revision"] == "2"
    value = read["event"]["data"]["source_summary"]
    assert int(value["refund_source_minor"]) + int(value["reimbursement_source_minor"]) == 7000
    assert value["remaining_source_minor"] == "3000"


def test_fully_settled_refund_reimbursement_and_mixed_reasons_are_authoritative(
    actors, postgres_engine, sync_http
):
    alice, _, _ = actors
    for refund_amount, reimbursement_amount, reason in [
        ("10000", "0", "refunded"),
        ("0", "10000", "reimbursed"),
        ("6000", "4000", "mixed"),
    ]:
        source = operation(alice.book_id, "bill", expense(alice.book_id, amount="10000"))
        push(postgres_engine, alice, source)
        for kind, amount in [("refund", refund_amount), ("reimbursement", reimbursement_amount)]:
            if amount != "0":
                assert (
                    push(
                        postgres_engine,
                        alice,
                        receipt(alice, source["entity_id"], kind=kind, amount=amount),
                    )[0]["status"]
                    == "applied"
                )
        read = current(sync_http, alice, source["entity_id"])
        assert read["event"]["data"]["source_summary"] == summary(
            refund_amount, reimbursement_amount, 0, reason
        )
        update = operation(
            alice.book_id,
            "bill",
            expense(
                alice.book_id,
                amount="10000",
                note="same-money-settled",
                reimbursement_tracking=True,
            ),
            identifier=source["entity_id"],
            action="update",
            revision=read["event"]["revision"],
        )
        assert http_push(sync_http, postgres_engine, alice, update).status_code == 200


def test_summary_uses_source_currency_not_receipt_cash_or_excess_income(
    actors, postgres_engine, sync_http
):
    alice, _, _ = actors
    bank = account(postgres_engine, alice)
    euros = account(postgres_engine, alice, opening="0", currency="EUR")
    source = operation(alice.book_id, "bill", expense(alice.book_id, bank, amount="10000"))
    assert push(postgres_engine, alice, source)[0]["status"] == "applied"
    command = operation(
        alice.book_id,
        "bill",
        expense(
            alice.book_id,
            euros,
            bill_type="refund",
            money=money("1100", "EUR"),
            income_component_minor="100",
            allocations=[
                {
                    "source_bill_id": source["entity_id"],
                    "source_amount_minor": "8000",
                    "receipt_amount_minor": "1000",
                    "rate": "0.125",
                }
            ],
            reporting={
                "rate": "8",
                "rate_date": "2026-10-21",
                "rate_source": "manual",
                "report_currency": "CNY",
                "report_scale": 2,
                "report_amount_minor": "8800",
            },
        ),
    )
    reply = http_push(sync_http, postgres_engine, alice, command)
    assert reply.status_code == 200, reply.text
    read = current(sync_http, alice, source["entity_id"])
    assert read["event"]["data"]["source_summary"] == summary(8000, 0, 2000)
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, bank).balance_minor == 90000
        assert session.get(SyncEntity, euros).balance_minor == 1100


def test_same_uuid_move_keeps_tracking_presence_and_excludes_it_from_financial_fingerprint(
    actors, postgres_engine, sync_http
):
    alice, _, carol = actors
    share(postgres_engine, carol, alice)
    bank = account(postgres_engine, alice)
    for original, incoming, expected in [
        ({}, {}, {}),
        ({"reimbursement_tracking": True}, {}, {"reimbursement_tracking": True}),
        (
            {"reimbursement_tracking": True},
            {"reimbursement_tracking": False},
            {"reimbursement_tracking": False},
        ),
    ]:
        source = operation(alice.book_id, "bill", expense(alice.book_id, bank, **original))
        assert push(postgres_engine, alice, source)[0]["status"] == "applied"
        command = operation(
            alice.book_id,
            "bill",
            expense(carol.book_id, bank, **incoming),
            identifier=source["entity_id"],
            action="update",
            revision="1",
        )
        command["move"] = {"target_scope_id": str(carol.book_id), "attachment_replacements": []}
        reply = http_push(sync_http, postgres_engine, alice, command)
        assert reply.status_code == 200, reply.text
        read = current(sync_http, alice, source["entity_id"], carol.book_id)
        assert {
            key: value
            for key, value in read["editable_payload"].items()
            if key == "reimbursement_tracking"
        } == expected
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, bank).balance_minor == 99700
