"""Real PostgreSQL same-UUID moves, privacy and all-or-nothing receipts."""

from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from datetime import timedelta
from hashlib import sha256
from io import BytesIO
from threading import Event
from uuid import UUID, uuid4

import pytest
from PIL import Image
from sqlalchemy import select, text
from sqlalchemy.orm import Session

from flowtrace_server.attachments.gc import claim
from flowtrace_server.attachments.models import Attachment, AttachmentRef
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import now
from flowtrace_server.books.models import SyncScope
from flowtrace_server.sync import writer
from flowtrace_server.sync.models import LedgerEntry, SyncChange, SyncEntity, SyncReceipt
from flowtrace_server.sync.reader import create_snapshot, pull, read_entity, snapshot_page
from flowtrace_server.sync.schemas import PullRequest, SnapshotPageRequest, SnapshotRequest

from .helpers import Actor, account, epoch, expense, money, operation, push, revoke, share
from .test_attachment_http import declare
from .test_http import body_for
from .test_management import category_payload, create, tag_payload

pytestmark = pytest.mark.postgres


def new_book(engine, owner, currency="CNY"):
    command = operation(
        owner.principal.user_id,
        "book",
        {
            "name": "合成迁移目标",
            "currency": currency,
            "timezone": "America/New_York",
            "month_start_day": 15,
        },
    )
    assert push(engine, owner, command)[0]["status"] == "applied"
    return Actor(owner.principal, owner.token, UUID(command["entity_id"]))


def create_bill(engine, owner, payload=None):
    command = operation(owner.book_id, "bill", payload or expense(owner.book_id))
    assert push(engine, owner, command)[0]["status"] == "applied"
    return UUID(command["entity_id"])


def move_command(engine, bill_id, target, replacements=(), **metadata):
    with Session(engine) as session:
        bill = session.get(SyncEntity, bill_id)
        payload = deepcopy(bill.payload)
        payload.update(book_id=str(target.book_id), **metadata)
        payload["attachment_ids"] = [str(new) for _, new in replacements]
        command = operation(
            bill.scope_id,
            "bill",
            payload,
            identifier=bill_id,
            action="update",
            revision=str(bill.revision),
        )
    command["move"] = {
        "target_scope_id": str(target.book_id),
        "attachment_replacements": [
            {"source_id": str(old), "target_id": str(new)} for old, new in replacements
        ],
    }
    return command


def rows(engine, bill_id):
    with Session(engine) as session:
        bill = session.get(SyncEntity, bill_id)
        return {
            "scope": bill.scope_id,
            "revision": bill.revision,
            "payload": deepcopy(bill.payload),
            "entries": {
                entry.id: (
                    entry.account_id,
                    entry.amount_minor,
                    entry.currency,
                    entry.currency_scale,
                    entry.business_date,
                    entry.component,
                    entry.book_id,
                )
                for entry in session.scalars(
                    select(LedgerEntry).where(LedgerEntry.bill_id == bill_id)
                )
            },
            "refs": set(
                session.scalars(
                    select(AttachmentRef.attachment_id).where(AttachmentRef.bill_id == bill_id)
                )
            ),
        }


def account_state(engine, identifier):
    with Session(engine) as session:
        entity = session.get(SyncEntity, identifier)
        return entity.balance_minor, entity.revision, deepcopy(entity.payload)


def snapshot_items(engine, user, scope_ids):
    body = SnapshotRequest.model_validate(
        {
            "protocol_version": 1,
            "client_id": str(user.principal.client_id),
            "sync_epoch": epoch(engine),
            "scope_ids": [str(value) for value in scope_ids],
        }
    )
    with Session(engine) as session:
        snapshot = create_snapshot(session, user.principal, body)
    result, token = [], snapshot["first_page_token"]
    while token is not None:
        with Session(engine) as session:
            page = snapshot_page(
                session,
                user.principal,
                UUID(snapshot["snapshot_id"]),
                SnapshotPageRequest.model_validate(
                    {"client_id": str(user.principal.client_id), "page_token": token}
                ),
            )
        result.extend(page["items"])
        token = page["next_page_token"]
    return result


def complete_upload(client, user, upload_id, content):
    headers = {"authorization": "Bearer " + user.token}
    sent = client.put(
        f"/api/v1/attachments/uploads/{upload_id}/content", headers=headers, content=content
    )
    assert sent.status_code == 200, sent.text
    done = client.post(f"/api/v1/attachments/uploads/{upload_id}/complete", headers=headers)
    assert done.status_code == 200, done.text


def test_move_preserves_uuid_money_entry_identity_and_atomic_public_private_events(
    actors, postgres_engine
):
    alice, _, _ = actors
    target = new_book(postgres_engine, alice)
    identifier = account(postgres_engine, alice)
    bill_id = create_bill(
        postgres_engine,
        alice,
        expense(
            alice.book_id,
            identifier,
            "1230",
            occurred_at="2026-10-21T12:34:56.123456+08:00",
            gross_amount_minor="1300",
            discount_minor="70",
            source="manual",
        ),
    )
    before, balance = rows(postgres_engine, bill_id), account_state(postgres_engine, identifier)
    command = move_command(postgres_engine, bill_id, target, note="合成明确迁移备注")
    applied = push(postgres_engine, alice, command)[0]
    assert applied["status"] == "applied", applied
    after = rows(postgres_engine, bill_id)
    assert after["scope"] == target.book_id and after["revision"] == 2
    assert after["payload"] == command["payload"]
    assert {
        identity: (*entry[:-1], target.book_id) for identity, entry in before["entries"].items()
    } == after["entries"]
    assert account_state(postgres_engine, identifier) == balance
    with Session(postgres_engine) as session:
        changes = list(
            session.scalars(
                select(SyncChange).where(SyncChange.commit_id == UUID(applied["commit_id"]))
            )
        )
        assert len(changes) == 3
        by_scope = {item.scope_id: item for item in changes}
        assert by_scope[alice.book_id].deleted and by_scope[alice.book_id].data is None
        public = by_scope[target.book_id]
        assert not public.deleted and public.revision == 2
        assert public.data["payload"]["book_id"] == str(target.book_id)
        assert public.data["payload"]["account_id"] is None
        private = by_scope[alice.principal.user_id]
        assert private.data["book_id"] == str(target.book_id)
        assert private.data["entries"][0]["money"]["amount_minor"] == "-1230"
        receipt = session.get(
            SyncReceipt,
            (alice.principal.user_id, alice.principal.client_id, UUID(command["operation_id"])),
        )
        assert set(receipt.required_scope_ids) == set(applied["scope_revisions"])
    assert push(postgres_engine, alice, command)[0] == {**applied, "replayed": True}
    changed = deepcopy(command)
    changed["payload"]["note"] = "不同迁移正文"
    assert push(postgres_engine, alice, changed)[0]["error"]["code"] == "idempotency_mismatch"
    assert rows(postgres_engine, bill_id) == after


def test_http_move_and_exact_response_loss_replay_use_target_for_current_reads(
    actors, postgres_engine, sync_http
):
    alice, _, _ = actors
    target = new_book(postgres_engine, alice)
    bill_id = create_bill(postgres_engine, alice)
    command = move_command(postgres_engine, bill_id, target)
    body, headers = (
        body_for(postgres_engine, alice, [command]),
        {"authorization": "Bearer " + alice.token},
    )
    first = sync_http.post("/api/v1/sync/push", json=body, headers=headers)
    assert first.status_code == 200, first.text
    replay = sync_http.post("/api/v1/sync/push", json=body, headers=headers)
    assert replay.status_code == 200, replay.text
    assert replay.json()["results"] == [{**first.json()["results"][0], "replayed": True}]
    route = f"/api/v1/sync/entities/bill/{bill_id}"
    assert (
        sync_http.get(route, params={"scope_id": str(alice.book_id)}, headers=headers).status_code
        == 404
    )
    current = sync_http.get(route, params={"scope_id": str(target.book_id)}, headers=headers)
    assert current.status_code == 200
    assert current.json()["editable_payload"]["book_id"] == str(target.book_id)
    assert current.json()["editable_payload"]["business_timezone"] == "Asia/Shanghai"


def test_concurrent_identical_move_replays_after_entity_changes_scope(actors, postgres_engine):
    alice, _, _ = actors
    target = new_book(postgres_engine, alice)
    bill_id = create_bill(postgres_engine, alice)
    command = move_command(postgres_engine, bill_id, target)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: push(postgres_engine, alice, command)[0], range(2)))
    assert {item["status"] for item in results} == {"applied"}
    assert sorted(item["replayed"] for item in results) == [False, True]
    assert len({item["commit_id"] for item in results}) == 1
    assert rows(postgres_engine, bill_id)["revision"] == 2


def test_transfer_fee_keeps_three_postings_and_requires_explicit_live_target_references(
    actors, postgres_engine
):
    alice, _, _ = actors
    target = new_book(postgres_engine, alice)
    cash, bank = account(postgres_engine, alice), account(postgres_engine, alice, kind="bank")
    source_category = create(postgres_engine, alice, "category", category_payload())
    target_category = create(postgres_engine, target, "category", category_payload())
    target_tag = create(postgres_engine, target, "tag", tag_payload())
    archived = create(postgres_engine, target, "category", category_payload(archived=True))
    group = create(postgres_engine, target, "tag", tag_payload(kind="group"))
    bill_id = create_bill(
        postgres_engine,
        alice,
        {
            **expense(alice.book_id),
            "bill_type": "transfer",
            "from_account_id": str(cash),
            "to_account_id": str(bank),
            "fee": {
                "money": money("10"),
                "account_id": str(cash),
                "category_id": source_category["entity_id"],
                "flags": {"exclude_from_statistics": False, "exclude_from_budget": False},
            },
        },
    )
    before = rows(postgres_engine, bill_id)
    balance = account_state(postgres_engine, cash), account_state(postgres_engine, bank)
    command = move_command(postgres_engine, bill_id, target, tag_ids=[group["entity_id"]])
    assert push(postgres_engine, alice, command)[0]["error"]["code"] == "tag.group_not_selectable"
    command = move_command(postgres_engine, bill_id, target)
    command["payload"]["fee"]["category_id"] = archived["entity_id"]
    assert push(postgres_engine, alice, command)[0]["error"]["code"] == "category.archived"
    command = move_command(postgres_engine, bill_id, target, tag_ids=[target_tag["entity_id"]])
    command["payload"]["fee"]["category_id"] = target_category["entity_id"]
    result = push(postgres_engine, alice, command)[0]
    assert result["status"] == "applied", result
    after = rows(postgres_engine, bill_id)
    assert len(after["entries"]) == 3
    assert {
        key: (*value[:-1], target.book_id) for key, value in before["entries"].items()
    } == after["entries"]
    assert (account_state(postgres_engine, cash), account_state(postgres_engine, bank)) == balance


@pytest.mark.parametrize("removed", ["source", "target"])
def test_move_receipt_requires_both_current_editor_grants_even_after_scope_change(
    actors, postgres_engine, removed
):
    alice, bob, carol = actors
    share(postgres_engine, alice, carol)
    share(postgres_engine, bob, carol)
    identifier = account(postgres_engine, carol)
    source = Actor(carol.principal, carol.token, alice.book_id)
    bill_id = create_bill(postgres_engine, source, expense(alice.book_id, identifier))
    command = move_command(postgres_engine, bill_id, bob)
    assert push(postgres_engine, carol, command)[0]["status"] == "applied"
    revoke(postgres_engine, alice if removed == "source" else bob, carol)
    denied = push(postgres_engine, carol, command)[0]
    assert denied["error"]["http_status"] == 403
    assert denied["error"]["current"] is None
    assert "commit_id" not in str(denied) and "book_id" not in str(denied)
    assert rows(postgres_engine, bill_id)["scope"] == bob.book_id


@pytest.mark.parametrize("role", [None, "viewer"])
@pytest.mark.parametrize("missing", ["source", "target"])
def test_move_needs_editor_on_both_books(actors, postgres_engine, role, missing):
    alice, bob, carol = actors
    if missing == "source":
        share(postgres_engine, bob, carol)
        if role:
            share(postgres_engine, alice, carol, role)
    else:
        share(postgres_engine, alice, carol)
        if role:
            share(postgres_engine, bob, carol, role)
    bill_id = create_bill(postgres_engine, alice)
    before = rows(postgres_engine, bill_id)
    command = move_command(postgres_engine, bill_id, bob)
    assert push(postgres_engine, carol, command)[0]["error"]["http_status"] == 403
    assert rows(postgres_engine, bill_id) == before


def test_move_cannot_change_another_members_private_finance_or_shared_account(
    actors, postgres_engine
):
    alice, bob, _ = actors
    target = new_book(postgres_engine, alice)
    share(postgres_engine, alice, bob)
    share(postgres_engine, target, bob)
    private_id = account(postgres_engine, alice)
    shared_id = account(postgres_engine, alice, shared=True)
    for identifier, actor, expected in [
        (private_id, bob, "not_found"),
        (shared_id, alice, "move_shared_account"),
    ]:
        bill_id = create_bill(postgres_engine, alice, expense(alice.book_id, identifier))
        before = rows(postgres_engine, bill_id)
        denied = push(postgres_engine, actor, move_command(postgres_engine, bill_id, target))[0]
        assert denied["error"]["code"] == expected
        assert rows(postgres_engine, bill_id) == before


@pytest.mark.parametrize(
    "field,value",
    [
        ("money", money("200")),
        ("business_date", "2026-10-20"),
        ("business_timezone", "Asia/Tokyo"),
        ("occurred_at", "2026-10-21T01:23:45.123456Z"),
        ("source", "import"),
    ],
)
def test_move_rejects_hidden_financial_or_historical_changes(actors, postgres_engine, field, value):
    alice, _, _ = actors
    target = new_book(postgres_engine, alice)
    bill_id = create_bill(postgres_engine, alice)
    before = rows(postgres_engine, bill_id)
    command = move_command(postgres_engine, bill_id, target)
    command["payload"][field] = value
    denied = push(postgres_engine, alice, command)[0]
    assert denied["error"]["code"] == "move_financial_fields_changed", denied
    assert rows(postgres_engine, bill_id) == before


def test_move_rejects_different_reporting_currency_and_unmapped_source_category(
    actors, postgres_engine
):
    alice, _, _ = actors
    target = new_book(postgres_engine, alice, "USD")
    bill_id = create_bill(postgres_engine, alice)
    assert (
        push(postgres_engine, alice, move_command(postgres_engine, bill_id, target))[0]["error"][
            "code"
        ]
        == "move_currency_mismatch"
    )
    category = operation(
        alice.book_id,
        "category",
        {"name": "来源分类", "kind": "expense", "parent_id": None, "icon": "", "sort_order": 0},
    )
    assert push(postgres_engine, alice, category)[0]["status"] == "applied"
    bill_id = create_bill(
        postgres_engine, alice, expense(alice.book_id, category_id=category["entity_id"])
    )
    target = new_book(postgres_engine, alice)
    assert (
        push(postgres_engine, alice, move_command(postgres_engine, bill_id, target))[0]["error"][
            "code"
        ]
        == "not_found"
    )
    assert (
        push(
            postgres_engine,
            alice,
            move_command(postgres_engine, bill_id, target, category_id=None),
        )[0]["status"]
        == "applied"
    )


def test_move_rejects_receipt_and_allocated_source_without_disclosing_foreign_links(
    actors, postgres_engine
):
    alice, _, _ = actors
    target = new_book(postgres_engine, alice)
    source_id = create_bill(postgres_engine, alice)
    receipt = {
        **expense(alice.book_id, amount="20"),
        "bill_type": "refund",
        "allocations": [
            {
                "source_bill_id": str(source_id),
                "source_amount_minor": "20",
                "receipt_amount_minor": "20",
            }
        ],
    }
    receipt_id = create_bill(postgres_engine, alice, receipt)
    for identifier in [source_id, receipt_id]:
        before = rows(postgres_engine, identifier)
        denied = push(postgres_engine, alice, move_command(postgres_engine, identifier, target))[0]
        assert denied["error"]["code"] == "move_has_allocations"
        assert str(source_id) not in str(denied) and str(receipt_id) not in str(denied)
        assert rows(postgres_engine, identifier) == before


def test_move_preserves_historical_adjustment_delta_after_later_income(actors, postgres_engine):
    alice, _, _ = actors
    target = new_book(postgres_engine, alice)
    identifier = account(postgres_engine, alice, opening="10000")
    create_bill(postgres_engine, alice, expense(alice.book_id, identifier, "1000"))
    adjustment = create_bill(
        postgres_engine,
        alice,
        {
            **expense(alice.book_id, identifier, "500"),
            "bill_type": "balance_adjustment",
            "target_balance_minor": "9500",
        },
    )
    create_bill(
        postgres_engine,
        alice,
        {**expense(alice.book_id, identifier, "1000"), "bill_type": "income"},
    )
    before = rows(postgres_engine, adjustment)
    state = account_state(postgres_engine, identifier)
    assert state[0] == 10500
    applied = push(postgres_engine, alice, move_command(postgres_engine, adjustment, target))[0]
    assert applied["status"] == "applied", applied
    assert account_state(postgres_engine, identifier) == state
    after = rows(postgres_engine, adjustment)
    assert {
        key: (*value[:-1], target.book_id) for key, value in before["entries"].items()
    } == after["entries"]


def test_ready_attachment_clone_replaces_only_this_bill_and_unready_same_intent_retries(
    actors, postgres_engine, sync_http, tmp_path
):
    alice, _, _ = actors
    sync_http.app.state.settings.data_directory = tmp_path
    target = new_book(postgres_engine, alice)
    old, upload, content = declare(sync_http, alice, alice.book_id)
    complete_upload(sync_http, alice, upload, content)
    new, upload, content = declare(sync_http, alice, target.book_id)
    first = create_bill(postgres_engine, alice, expense(alice.book_id, attachment_ids=[str(old)]))
    retained = create_bill(
        postgres_engine, alice, expense(alice.book_id, attachment_ids=[str(old)])
    )
    command = move_command(postgres_engine, first, target, [(old, new)])
    before = rows(postgres_engine, first)
    denied = push(postgres_engine, alice, command)[0]
    assert denied["error"]["code"] == "attachment_not_ready"
    assert rows(postgres_engine, first) == before
    with Session(postgres_engine) as session:
        assert (
            session.get(
                SyncReceipt,
                (alice.principal.user_id, alice.principal.client_id, UUID(command["operation_id"])),
            )
            is None
        )
    complete_upload(sync_http, alice, upload, content)
    assert push(postgres_engine, alice, command)[0]["status"] == "applied"
    assert rows(postgres_engine, first)["refs"] == {new}
    assert rows(postgres_engine, retained)["refs"] == {old}
    with Session(postgres_engine) as session:
        assert session.get(Attachment, old).scope_id == alice.book_id
        assert session.get(Attachment, old).orphaned_at is None
        assert session.get(Attachment, new).scope_id == target.book_id
        assert session.get(Attachment, new).orphaned_at is None
    headers = {"authorization": "Bearer " + alice.token}
    assert sync_http.get(f"/api/v1/attachments/{old}/content", headers=headers).content == content
    assert sync_http.get(f"/api/v1/attachments/{new}/content", headers=headers).content == content


def test_formal_receipt_constraint_failure_rolls_back_move_refs_and_scope_revisions(
    actors, postgres_engine, sync_http, tmp_path
):
    alice, _, _ = actors
    sync_http.app.state.settings.data_directory = tmp_path
    target = new_book(postgres_engine, alice)
    old, ticket, content = declare(sync_http, alice, alice.book_id)
    complete_upload(sync_http, alice, ticket, content)
    new, ticket, content = declare(sync_http, alice, target.book_id)
    complete_upload(sync_http, alice, ticket, content)
    identifier = account(postgres_engine, alice)
    bill_id = create_bill(
        postgres_engine, alice, expense(alice.book_id, identifier, attachment_ids=[str(old)])
    )
    command = move_command(postgres_engine, bill_id, target, [(old, new)])
    before, state = rows(postgres_engine, bill_id), account_state(postgres_engine, identifier)
    with Session(postgres_engine) as session:
        revisions = dict(session.execute(select(SyncScope.id, SyncScope.revision)).all())

    # before_commit receives no Session; use an operation-specific DB trigger to
    # reject exactly this synthetic operation's formal receipt.
    trigger_name = "synthetic_move_" + uuid4().hex
    with postgres_engine.begin() as connection:
        connection.execute(
            text(
                f"CREATE FUNCTION {trigger_name}() RETURNS trigger LANGUAGE plpgsql AS $$ "
                "BEGIN IF NEW.operation_id = '" + command["operation_id"] + "'::uuid THEN "
                "RAISE check_violation USING MESSAGE = 'synthetic receipt rejection'; "
                "END IF; RETURN NEW; END $$"
            )
        )
        connection.execute(
            text(
                f"CREATE TRIGGER {trigger_name} BEFORE INSERT ON sync_receipts "
                f"FOR EACH ROW EXECUTE FUNCTION {trigger_name}()"
            )
        )
    try:
        rejected = push(postgres_engine, alice, command)[0]
        assert rejected["error"]["http_status"] == 503, rejected
    finally:
        with postgres_engine.begin() as connection:
            connection.execute(text(f"DROP TRIGGER {trigger_name} ON sync_receipts"))
            connection.execute(text(f"DROP FUNCTION {trigger_name}()"))
    assert rows(postgres_engine, bill_id) == before
    assert account_state(postgres_engine, identifier) == state
    with Session(postgres_engine) as session:
        assert dict(session.execute(select(SyncScope.id, SyncScope.revision)).all()) == revisions
        assert session.get(Attachment, old).orphaned_at is None
        assert session.get(Attachment, new).orphaned_at is not None
    assert push(postgres_engine, alice, command)[0]["status"] == "applied"


def test_concurrent_opposing_moves_take_stable_scope_locks_and_keep_balances(
    actors, postgres_engine, monkeypatch
):
    alice, bob, _ = actors
    share(postgres_engine, alice, bob)
    share(postgres_engine, bob, alice)
    first_account, second_account = account(postgres_engine, alice), account(postgres_engine, bob)
    left = create_bill(postgres_engine, alice, expense(alice.book_id, first_account, "100"))
    right = create_bill(postgres_engine, bob, expense(bob.book_id, second_account, "200"))
    commands = [
        move_command(postgres_engine, left, bob),
        move_command(postgres_engine, right, alice),
    ]
    state = (
        account_state(postgres_engine, first_account),
        account_state(postgres_engine, second_account),
    )
    entered, second_locks, release = Event(), Event(), Event()
    lock_scopes = writer.lock_scopes

    def observed_lock(session, identifiers):
        if bob.principal.user_id in identifiers:
            second_locks.set()
        return lock_scopes(session, identifiers)

    monkeypatch.setattr(writer, "lock_scopes", observed_lock)

    def pause(_operation, _result):
        entered.set()
        assert release.wait(3)

    with ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(push, postgres_engine, alice, commands[0], before_commit=pause)
        assert entered.wait(3)
        second = pool.submit(push, postgres_engine, bob, commands[1])
        try:
            assert second_locks.wait(3), "different user must reach scope locking"
            assert not second.done()
        finally:
            release.set()
        assert first.result(timeout=5)[0]["status"] == "applied"
        assert second.result(timeout=5)[0]["status"] == "applied"
    assert (
        account_state(postgres_engine, first_account),
        account_state(postgres_engine, second_account),
    ) == state
    assert rows(postgres_engine, left)["scope"] == bob.book_id
    assert rows(postgres_engine, right)["scope"] == alice.book_id


def test_attachment_mismatch_scope_and_mapping_leave_original_references(
    actors, postgres_engine, sync_http, tmp_path
):
    alice, bob, _ = actors
    sync_http.app.state.settings.data_directory = tmp_path
    target = new_book(postgres_engine, alice)
    old, ticket, content = declare(sync_http, alice, alice.book_id)
    complete_upload(sync_http, alice, ticket, content)
    bill_id = create_bill(postgres_engine, alice, expense(alice.book_id, attachment_ids=[str(old)]))
    buffer = BytesIO()
    Image.new("RGB", (2, 1), "red").save(buffer, format="PNG")
    other = buffer.getvalue()
    new = uuid4()
    declared = sync_http.post(
        "/api/v1/attachments/uploads",
        headers={"authorization": "Bearer " + alice.token},
        json={
            "attachment_id": str(new),
            "scope_id": str(target.book_id),
            "sha256": sha256(other).hexdigest(),
            "size_bytes": len(other),
            "media_type": "image/png",
        },
    )
    assert declared.status_code == 201, declared.text
    complete_upload(sync_http, alice, declared.json()["upload_id"], other)
    before = rows(postgres_engine, bill_id)
    wrong_bytes = move_command(postgres_engine, bill_id, target, [(old, new)])
    assert (
        push(postgres_engine, alice, wrong_bytes)[0]["error"]["code"] == "move_attachment_mismatch"
    )
    missing = move_command(postgres_engine, bill_id, target)
    assert push(postgres_engine, alice, missing)[0]["error"]["code"] == "move_attachment_mapping"
    foreign, _, _ = declare(sync_http, bob, bob.book_id)
    wrong_scope = move_command(postgres_engine, bill_id, target, [(old, foreign)])
    denied = push(postgres_engine, alice, wrong_scope)[0]
    assert denied["error"]["http_status"] == 403
    assert str(foreign) not in str(denied) and "sha256" not in str(denied)
    assert rows(postgres_engine, bill_id) == before


@pytest.mark.parametrize("first", ["move", "gc"])
def test_gc_and_move_share_scope_attachment_lock_order(
    actors, postgres_engine, sync_http, tmp_path, first
):
    alice, _, _ = actors
    sync_http.app.state.settings.data_directory = tmp_path
    target = new_book(postgres_engine, alice)
    old, ticket, content = declare(sync_http, alice, alice.book_id)
    complete_upload(sync_http, alice, ticket, content)
    new, ticket, content = declare(sync_http, alice, target.book_id)
    complete_upload(sync_http, alice, ticket, content)
    bill_id = create_bill(postgres_engine, alice, expense(alice.book_id, attachment_ids=[str(old)]))
    command = move_command(postgres_engine, bill_id, target, [(old, new)])
    with Session(postgres_engine) as session:
        session.get(Attachment, new).orphaned_at = now() - timedelta(days=8)
        session.commit()
    if first == "gc":
        before = rows(postgres_engine, bill_id)
        try:
            with Session(postgres_engine) as session:
                assert claim(session, new).status == "deleting"
                session.commit()
            assert (
                push(postgres_engine, alice, command)[0]["error"]["code"] == "attachment_not_ready"
            )
            assert rows(postgres_engine, bill_id) == before
        finally:
            # Only this synthetic row was aged/claimed, without deleting its
            # bytes. Restore its original ready state so unrelated whole-DB GC
            # tests cannot collect it after this concurrency scenario finishes.
            with Session(postgres_engine) as session:
                record = session.get(Attachment, new)
                record.status, record.orphaned_at = "ready", now()
                session.commit()
        return
    entered, gc_entered, release = Event(), Event(), Event()

    def pause(_operation, _result):
        entered.set()
        assert release.wait(3)

    def collect_one():
        with Session(postgres_engine) as session:
            gc_entered.set()
            result = claim(session, new)
            session.commit()
            return result

    with ThreadPoolExecutor(max_workers=2) as pool:
        moving = pool.submit(push, postgres_engine, alice, command, before_commit=pause)
        assert entered.wait(3)
        collecting = pool.submit(collect_one)
        try:
            assert gc_entered.wait(3)
            assert not collecting.done()
        finally:
            release.set()
        assert moving.result(timeout=5)[0]["status"] == "applied"
        assert collecting.result(timeout=5) is None
    assert rows(postgres_engine, bill_id)["refs"] == {new}
    with Session(postgres_engine) as session:
        assert session.get(Attachment, new).status == "ready"
        assert session.get(Attachment, new).orphaned_at is None


def test_incremental_and_snapshot_have_one_current_target_and_no_source_leak(
    actors, postgres_engine
):
    alice, bob, _ = actors
    share(postgres_engine, alice, bob, "viewer")
    target = new_book(postgres_engine, alice)
    identifier = account(postgres_engine, alice)
    bill_id = create_bill(postgres_engine, alice, expense(alice.book_id, identifier))
    command = move_command(postgres_engine, bill_id, target, note="仅目标有权查看")
    applied = push(postgres_engine, alice, command)[0]
    current = snapshot_items(
        postgres_engine, alice, [alice.book_id, target.book_id, alice.principal.user_id]
    )
    matching = [item for item in current if item["entity_id"] == str(bill_id)]
    assert {(item["scope_id"], item["data"]["projection_kind"]) for item in matching} == {
        (str(target.book_id), "bill_public"),
        (str(alice.principal.user_id), "bill_private_finance"),
    }
    assert all(
        item["data"].get("book_id", item["data"].get("payload", {}).get("book_id"))
        == str(target.book_id)
        for item in matching
    )
    assert all(
        item["entity_id"] != str(bill_id)
        for item in snapshot_items(postgres_engine, bob, [alice.book_id])
    )
    for user, scope in [(bob, target.book_id), (alice, alice.book_id)]:
        with Session(postgres_engine) as session, pytest.raises(ApiError):
            read_entity(session, user.principal, "bill", bill_id, scope)
    with Session(postgres_engine) as session:
        data = pull(
            session,
            alice.principal,
            PullRequest.model_validate(
                {
                    "sync_epoch": epoch(postgres_engine),
                    "cursors": {},
                    "limit": 100,
                    "page_token": None,
                }
            ),
        )
    commit = next(item for item in data["commits"] if item["commit_id"] == applied["commit_id"])
    events = [item for item in commit["events"] if item["entity_id"] == str(bill_id)]
    assert len(events) == 3 and {item["revision"] for item in events} == {"2"}
    with Session(postgres_engine) as session:
        source_only = pull(
            session,
            bob.principal,
            PullRequest.model_validate(
                {
                    "sync_epoch": epoch(postgres_engine),
                    "cursors": {},
                    "limit": 100,
                    "page_token": None,
                }
            ),
        )
    assert "仅目标有权查看" not in str(source_only)
    source_commit = next(
        item for item in source_only["commits"] if item["commit_id"] == applied["commit_id"]
    )
    assert len(source_commit["events"]) == 1
    assert source_commit["events"][0]["deleted"] is True
    stale = operation(
        alice.book_id,
        "bill",
        expense(alice.book_id),
        identifier=bill_id,
        action="update",
        revision="2",
    )
    assert push(postgres_engine, alice, stale)[0]["error"]["code"] == "not_found"
    assert rows(postgres_engine, bill_id)["scope"] == target.book_id
