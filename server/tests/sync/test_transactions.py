from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from datetime import timedelta
from threading import Event
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import now
from flowtrace_server.books.models import SyncScope
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.sync.models import (
    LedgerEntry,
    SyncClient,
    SyncEntity,
    SyncReceipt,
)
from flowtrace_server.sync.reader import list_scopes, pull, read_entity
from flowtrace_server.sync.schemas import PullRequest

from .helpers import account, actor, epoch, expense, money, operation, push, revoke, share

pytestmark = pytest.mark.postgres


def test_syn01_lost_response_and_syn02_changed_body(actors, postgres_engine):
    alice, _, _ = actors
    identifier = account(postgres_engine, alice)
    command = operation(alice.book_id, "bill", expense(alice.book_id, identifier))
    applied = push(postgres_engine, alice, command)[0]
    replay = push(postgres_engine, alice, command)[0]
    assert applied["status"] == "applied"
    assert {**applied, "replayed": True} == replay
    changed = deepcopy(command)
    changed["payload"]["money"] = money("200")
    assert push(postgres_engine, alice, changed)[0]["error"]["code"] == "idempotency_mismatch"
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, identifier).balance_minor == 99900
        assert (
            session.scalar(
                select(func.count())
                .select_from(LedgerEntry)
                .where(LedgerEntry.bill_id == UUID(command["entity_id"]))
            )
            == 1
        )


def test_syn03_edit_edit_and_syn04_edit_delete_are_atomic(actors, postgres_engine):
    alice, _, _ = actors
    second_device = actor(postgres_engine, alice.principal.user_id)
    identifier = account(postgres_engine, alice)
    create = operation(alice.book_id, "bill", expense(alice.book_id, identifier))
    assert push(postgres_engine, alice, create)[0]["status"] == "applied"
    update = operation(
        alice.book_id,
        "bill",
        expense(alice.book_id, identifier, "200"),
        identifier=UUID(create["entity_id"]),
        action="update",
        revision="1",
    )
    assert push(postgres_engine, alice, update)[0]["revision"] == "2"
    stale = operation(
        alice.book_id,
        "bill",
        expense(alice.book_id, identifier, "300"),
        identifier=UUID(create["entity_id"]),
        action="update",
        revision="1",
    )
    conflict = push(postgres_engine, second_device, stale)[0]
    assert conflict["error"]["code"] == "revision_conflict"
    assert conflict["error"]["current"]["revision"] == "2"
    delete = operation(
        alice.book_id,
        "bill",
        {},
        identifier=UUID(create["entity_id"]),
        action="delete",
        revision="2",
    )
    assert push(postgres_engine, alice, delete)[0]["status"] == "applied"
    stale["operation_id"] = str(uuid4())
    stale["base_revision"] = "2"
    conflict = push(postgres_engine, second_device, stale)[0]
    assert conflict["error"]["current"]["deleted"] is True
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, identifier).balance_minor == 100000
        assert (
            list(
                session.scalars(
                    select(LedgerEntry).where(LedgerEntry.bill_id == UUID(create["entity_id"]))
                )
            )
            == []
        )


def test_concurrent_identical_operation_has_one_commit_and_posting(actors, postgres_engine):
    alice, _, _ = actors
    identifier = account(postgres_engine, alice)
    command = operation(alice.book_id, "bill", expense(alice.book_id, identifier))
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: push(postgres_engine, alice, command)[0], range(2)))
    assert {row["status"] for row in results} == {"applied"}
    assert sorted(row["replayed"] for row in results) == [False, True]
    assert len({row["commit_id"] for row in results}) == 1
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, identifier).balance_minor == 99900


def test_concurrent_same_key_different_hash_never_applies_both(actors, postgres_engine):
    alice, _, _ = actors
    identifier = account(postgres_engine, alice)
    first = operation(alice.book_id, "bill", expense(alice.book_id, identifier))
    second = deepcopy(first)
    second["payload"]["money"] = money("200")
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(
            pool.map(lambda command: push(postgres_engine, alice, command)[0], [first, second])
        )
    assert sorted(row["status"] for row in results) == ["applied", "rejected"]
    assert (
        next(row for row in results if row["status"] == "rejected")["error"]["code"]
        == "idempotency_mismatch"
    )
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, identifier).balance_minor in {99900, 99800}


def test_syn05_late_commit_cannot_be_skipped_by_pull(actors, postgres_engine):
    alice, bob, carol = actors
    share(postgres_engine, alice, bob)
    share(postgres_engine, alice, carol, "viewer")
    with Session(postgres_engine) as session:
        session.get(SyncScope, alice.book_id).revision = 40
        session.commit()
    allocated, release = Event(), Event()

    def pause(operation, result):
        assert result["scope_revisions"][str(alice.book_id)] == "41"
        allocated.set()
        assert release.wait(2), "test must release uncommitted writer"

    a = operation(alice.book_id, "bill", expense(alice.book_id))
    b = operation(alice.book_id, "bill", expense(alice.book_id, amount="200"))
    with ThreadPoolExecutor(max_workers=3) as pool:
        future_a = pool.submit(push, postgres_engine, alice, a, before_commit=pause)
        assert allocated.wait(2)
        future_b = pool.submit(push, postgres_engine, bob, b)
        try:
            with Session(postgres_engine) as session:
                before = pull(
                    session,
                    carol.principal,
                    PullRequest.model_validate(
                        {
                            "sync_epoch": epoch(postgres_engine),
                            "cursors": {str(alice.book_id): "40"},
                            "limit": 100,
                            "page_token": None,
                        }
                    ),
                )
            assert before["checkpoint"][str(alice.book_id)] == "40"
            assert not any(
                event["scope_id"] == str(alice.book_id)
                for commit in before["commits"]
                for event in commit["events"]
            )
            assert not future_b.done()
        finally:
            release.set()
        assert future_a.result(timeout=4)[0]["status"] == "applied"
        assert future_b.result(timeout=4)[0]["scope_revisions"][str(alice.book_id)] == "42"
    with Session(postgres_engine) as session:
        after = pull(
            session,
            carol.principal,
            PullRequest.model_validate(
                {
                    "sync_epoch": epoch(postgres_engine),
                    "cursors": {str(alice.book_id): "40"},
                    "limit": 100,
                    "page_token": None,
                }
            ),
        )
    assert [
        event["scope_revision"]
        for commit in after["commits"]
        for event in commit["events"]
        if event["scope_id"] == str(alice.book_id)
    ] == ["41", "42"]


def test_syn06_revoked_replay_discloses_no_old_receipt_body(actors, postgres_engine):
    alice, bob, _ = actors
    share(postgres_engine, alice, bob)
    command = operation(alice.book_id, "bill", expense(alice.book_id, note="合成共享私密备注"))
    assert push(postgres_engine, bob, command)[0]["status"] == "applied"
    revoke(postgres_engine, alice, bob)
    result = push(postgres_engine, bob, command)[0]
    assert result["error"]["http_status"] == 403
    assert result["error"]["current"] is None
    assert "备注" not in str(result)


def test_syn11_failed_dependency_has_no_financial_write(actors, postgres_engine):
    alice, _, _ = actors
    invalid = operation(
        alice.principal.user_id,
        "account",
        {
            "name": "合成未知币种",
            "kind": "cash",
            "opening": money(currency="AAA"),
            "hidden": False,
            "include_in_net_assets": True,
        },
    )
    dependent = operation(
        alice.book_id, "bill", expense(alice.book_id), depends=invalid["operation_id"]
    )
    result = push(postgres_engine, alice, [invalid, dependent])
    assert result[0]["status"] == "rejected"
    assert result[1]["error"]["code"] == "dependency_failed"
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, UUID(dependent["entity_id"])) is None
        assert (
            session.get(
                SyncReceipt,
                (alice.principal.user_id, alice.principal.client_id, UUID(invalid["operation_id"])),
            ).status
            == "rejected"
        )


def test_overflow_rejection_retracts_no_old_state(actors, postgres_engine):
    alice, _, _ = actors
    identifier = account(postgres_engine, alice, opening="-9223372036854775808")
    command = operation(alice.book_id, "bill", expense(alice.book_id, identifier, "1"))
    assert push(postgres_engine, alice, command)[0]["error"]["code"] == "money.out_of_range"
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, identifier).balance_minor == -9223372036854775808
        assert session.get(SyncEntity, UUID(command["entity_id"])) is None
        assert (
            session.scalar(
                select(func.count())
                .select_from(LedgerEntry)
                .where(LedgerEntry.account_id == identifier)
            )
            == 0
        )


def test_syn07_expired_device_and_syn08_epoch_reject_before_receipts(actors, postgres_engine):
    alice, _, _ = actors
    command = operation(alice.book_id, "bill", expense(alice.book_id))
    initial_epoch = epoch(postgres_engine)
    assert push(postgres_engine, alice, command)[0]["status"] == "applied"
    with Session(postgres_engine) as session:
        device = session.get(SyncClient, (alice.principal.user_id, alice.principal.client_id))
        device.valid_until = now() - timedelta(days=1)
        session.commit()
    assert push(postgres_engine, alice, command)[0]["error"]["code"] == "resync_required"
    with Session(postgres_engine) as session:
        assert list_scopes(session, alice.principal)["requires_rebuild"] is True
    try:
        with Session(postgres_engine) as session:
            session.get(ServerState, 1).sync_epoch = uuid4()
            session.commit()
        assert (
            push(postgres_engine, alice, command, epoch=initial_epoch)[0]["error"]["code"]
            == "epoch_changed"
        )
    finally:
        with Session(postgres_engine) as session:
            session.get(ServerState, 1).sync_epoch = UUID(initial_epoch)
            session.commit()


def test_syn12_foreign_private_account_is_not_found(actors, postgres_engine):
    alice, bob, _ = actors
    identifier = account(postgres_engine, alice)
    command = operation(bob.book_id, "bill", expense(bob.book_id, identifier))
    denied = push(postgres_engine, bob, command)[0]
    assert denied["error"]["http_status"] == 404
    with Session(postgres_engine) as session:
        with pytest.raises(ApiError) as error:
            read_entity(session, bob.principal, "account", identifier, bob.principal.user_id)
    assert error.value.status == 404
