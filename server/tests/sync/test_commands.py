from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select, text
from sqlalchemy.orm import Session

from flowtrace_server.books.models import Book, SyncScope
from flowtrace_server.sync.models import LedgerEntry, SyncChange, SyncEntity, SyncReceipt

from .helpers import account, expense, money, operation, push

pytestmark = pytest.mark.postgres


def test_all_six_entity_commands_and_empty_book_soft_delete(actors, postgres_engine):
    alice, bob, _ = actors
    book = operation(
        alice.principal.user_id,
        "book",
        {
            "name": "合成空账本",
            "currency": "CNY",
            "timezone": "Asia/Shanghai",
            "month_start_day": 31,
        },
    )
    created = push(postgres_engine, alice, book)[0]
    assert created["status"] == "applied" and created["revision"] == "1"
    assert push(postgres_engine, alice, book)[0] == {**created, "replayed": True}
    book_id = UUID(book["entity_id"])
    category = operation(
        book_id,
        "category",
        {"name": "合成分类", "kind": "expense", "parent_id": None, "icon": "food", "sort_order": 0},
    )
    tag = operation(book_id, "tag", {"name": "合成标签", "color": "#123456"})
    assert push(postgres_engine, alice, [category, tag])[0]["status"] == "applied"
    budget = operation(
        book_id,
        "budget",
        {
            "period_start": "2026-10-01",
            "period_end_exclusive": "2026-11-01",
            "total": money("300"),
            "categories": [{"category_id": category["entity_id"], "limit": money("200")}],
            "carry_forward": True,
        },
    )
    assert push(postgres_engine, alice, budget)[0]["status"] == "applied"
    remove_book = operation(book_id, "book", {}, identifier=book_id, action="delete", revision="1")
    assert push(postgres_engine, alice, remove_book)[0]["error"]["code"] == "book_not_empty"
    for command in [budget, tag, category]:
        assert (
            push(
                postgres_engine,
                alice,
                operation(
                    book_id,
                    command["entity_type"],
                    {},
                    identifier=UUID(command["entity_id"]),
                    action="delete",
                    revision="1",
                ),
            )[0]["status"]
            == "applied"
        )
    # An empty shared book emits each member's control notification, not their
    # private account entries. Use the normal membership service's lock contract.
    with Session(postgres_engine) as session:
        from flowtrace_server.books.models import BookMembership

        session.add(
            BookMembership(
                book_id=book_id, user_id=bob.principal.user_id, role="editor", active=True
            )
        )
        session.get(SyncScope, bob.principal.user_id).permission_version += 1
        session.commit()
    remove_book["operation_id"] = str(uuid4())
    applied = push(postgres_engine, alice, remove_book)[0]
    assert applied["status"] == "applied", applied
    with Session(postgres_engine) as session:
        assert session.get(Book, book_id).deleted is True
        events = list(
            session.scalars(
                select(SyncChange).where(SyncChange.commit_id == UUID(applied["commit_id"]))
            )
        )
        assert len(events) == 3 and all(row.data is None and row.deleted for row in events)


def test_reference_deletion_category_depth_and_budget_parent_overlap(actors, postgres_engine):
    alice, _, _ = actors
    parent = operation(
        alice.book_id,
        "category",
        {"name": "合成一级", "kind": "expense", "parent_id": None, "icon": "food", "sort_order": 0},
    )
    assert push(postgres_engine, alice, parent)[0]["status"] == "applied"
    child = operation(
        alice.book_id,
        "category",
        {
            "name": "合成二级",
            "kind": "expense",
            "parent_id": parent["entity_id"],
            "icon": "food",
            "sort_order": 1,
        },
    )
    assert push(postgres_engine, alice, child)[0]["status"] == "applied"
    deep = operation(
        alice.book_id, "category", {**child["payload"], "parent_id": child["entity_id"]}
    )
    assert push(postgres_engine, alice, deep)[0]["error"]["code"] == "category.invalid_parent"
    budget = operation(
        alice.book_id,
        "budget",
        {
            "period_start": "2026-10-01",
            "period_end_exclusive": "2026-11-01",
            "total": money("300"),
            "categories": [
                {"category_id": parent["entity_id"], "limit": money("100")},
                {"category_id": child["entity_id"], "limit": money("100")},
            ],
            "carry_forward": False,
        },
    )
    assert push(postgres_engine, alice, budget)[0]["error"]["code"] == "budget.category_overlap"
    identifier = account(postgres_engine, alice)
    bill = operation(
        alice.book_id, "bill", expense(alice.book_id, identifier, category_id=child["entity_id"])
    )
    assert push(postgres_engine, alice, bill)[0]["status"] == "applied"
    for kind, target, scope in [
        ("account", identifier, alice.principal.user_id),
        ("category", UUID(child["entity_id"]), alice.book_id),
        ("category", UUID(parent["entity_id"]), alice.book_id),
    ]:
        with Session(postgres_engine) as session:
            revision = str(session.get(SyncEntity, target).revision)
        result = push(
            postgres_engine,
            alice,
            operation(scope, kind, {}, identifier=target, action="delete", revision=revision),
        )[0]
        assert result["error"]["code"] == "entity_in_use"


def test_credit_debt_fee_adjustment_exact_postings_and_invalid_kinds(actors, postgres_engine):
    alice, _, _ = actors
    bank = account(postgres_engine, alice)
    credit = account(postgres_engine, alice, opening="-10000", kind="credit_card")
    receivable = account(postgres_engine, alice, opening="0", kind="loan_receivable")
    payable = account(postgres_engine, alice, opening="0", kind="loan_payable")
    commands = [
        ("credit_repayment", bank, credit, "1000"),
        ("loan_borrow", payable, bank, "2000"),
        ("loan_lend", bank, receivable, "1000"),
        ("loan_collect", receivable, bank, "200"),
        ("loan_repay", bank, payable, "500"),
    ]
    for kind, first, second, amount in commands:
        result = push(
            postgres_engine,
            alice,
            operation(
                alice.book_id,
                "bill",
                expense(
                    alice.book_id,
                    amount=amount,
                    bill_type=kind,
                    from_account_id=str(first),
                    to_account_id=str(second),
                ),
            ),
        )[0]
        assert result["status"] == "applied", result
    transfer = operation(
        alice.book_id,
        "bill",
        expense(
            alice.book_id,
            amount="100",
            bill_type="transfer",
            from_account_id=str(bank),
            to_account_id=str(credit),
            fee={
                "money": money("10"),
                "account_id": str(bank),
                "flags": {"exclude_from_statistics": False, "exclude_from_budget": False},
            },
        ),
    )
    assert push(postgres_engine, alice, transfer)[0]["status"] == "applied"
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, bank).balance_minor == 99590
        assert session.get(SyncEntity, credit).balance_minor == -8900
        assert session.get(SyncEntity, receivable).balance_minor == 800
        assert session.get(SyncEntity, payable).balance_minor == -1500
    adjustment = operation(
        alice.book_id,
        "bill",
        expense(
            alice.book_id,
            bank,
            "410",
            bill_type="balance_adjustment",
            target_balance_minor="100000",
        ),
    )
    assert push(postgres_engine, alice, adjustment)[0]["status"] == "applied"
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, bank).balance_minor == 100000
    for kind in ["transfer", "credit_repayment"]:
        invalid = operation(
            alice.book_id,
            "bill",
            expense(
                alice.book_id,
                bill_type=kind,
                from_account_id=str(bank),
                to_account_id=str(receivable),
            ),
        )
        assert push(postgres_engine, alice, invalid)[0]["status"] == "rejected"
    assert (
        push(
            postgres_engine,
            alice,
            operation(
                alice.book_id,
                "bill",
                {},
                identifier=UUID(transfer["entity_id"]),
                action="delete",
                revision="1",
            ),
        )[0]["status"]
        == "applied"
    )
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, bank).balance_minor == 100110  # Main and fee retracted once.


def test_fx_refund_and_reimbursement_allocation_conservation(actors, postgres_engine):
    alice, _, _ = actors
    usd = account(postgres_engine, alice, opening="10000", currency="USD")
    receipt = account(postgres_engine, alice, opening="0")
    missing = operation(
        alice.book_id, "bill", {**expense(alice.book_id, usd), "money": money("101", "USD")}
    )
    assert push(postgres_engine, alice, missing)[0]["error"]["code"] == "fx.rate_required"
    original = operation(
        alice.book_id,
        "bill",
        {
            **missing["payload"],
            "reporting": {
                "rate": "0.5",
                "rate_date": "2026-10-21",
                "rate_source": "synthetic",
                "report_currency": "CNY",
                "report_scale": 2,
                "report_amount_minor": "51",
            },
        },
    )
    assert push(postgres_engine, alice, original)[0]["status"] == "applied"
    refund = operation(
        alice.book_id,
        "bill",
        expense(
            alice.book_id,
            receipt,
            "20",
            bill_type="refund",
            allocations=[
                {
                    "source_bill_id": original["entity_id"],
                    "source_amount_minor": "40",
                    "receipt_amount_minor": "20",
                    "rate": "0.5",
                }
            ],
        ),
    )
    assert push(postgres_engine, alice, refund)[0]["status"] == "applied"
    reimbursement = operation(
        alice.book_id,
        "bill",
        expense(
            alice.book_id,
            receipt,
            "31",
            bill_type="reimbursement",
            allocations=[
                {
                    "source_bill_id": original["entity_id"],
                    "source_amount_minor": "61",
                    "receipt_amount_minor": "31",
                    "rate": "0.5",
                }
            ],
        ),
    )
    assert push(postgres_engine, alice, reimbursement)[0]["status"] == "applied"
    excess = operation(
        alice.book_id,
        "bill",
        expense(
            alice.book_id,
            receipt,
            "1",
            bill_type="reimbursement",
            allocations=[
                {
                    "source_bill_id": original["entity_id"],
                    "source_amount_minor": "1",
                    "receipt_amount_minor": "1",
                    "rate": "1",
                }
            ],
        ),
    )
    assert (
        push(postgres_engine, alice, excess)[0]["error"]["code"] == "allocation.exceeds_remaining"
    )
    # Explicit pure income component is not secretly deducted from an expense.
    income_refund = operation(
        alice.book_id,
        "bill",
        expense(alice.book_id, receipt, "5", bill_type="refund", income_component_minor="5"),
    )
    assert push(postgres_engine, alice, income_refund)[0]["status"] == "applied"
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, usd).balance_minor == 9899
        assert session.get(SyncEntity, receipt).balance_minor == 56
        assert session.get(SyncEntity, UUID(original["entity_id"])).revision == 3


def test_formal_receipt_database_failure_rolls_back_ledger(actors, postgres_engine):
    alice, _, _ = actors
    identifier = account(postgres_engine, alice)
    command = operation(alice.book_id, "bill", expense(alice.book_id, identifier))
    operation_id = UUID(command["operation_id"])
    with postgres_engine.begin() as connection:
        connection.execute(
            text(
                "ALTER TABLE sync_receipts ADD CONSTRAINT ck_sync_test_receipt_reject "
                f"CHECK (operation_id <> '{operation_id}'::uuid) NOT VALID"
            )
        )
    try:
        result = push(postgres_engine, alice, command)[0]
        assert result["error"]["code"] == "sync_unavailable"
        with Session(postgres_engine) as session:
            assert session.get(SyncEntity, identifier).balance_minor == 100000
            assert session.get(SyncEntity, UUID(command["entity_id"])) is None
            assert (
                session.get(
                    SyncReceipt, (alice.principal.user_id, alice.principal.client_id, operation_id)
                )
                is None
            )
            assert (
                session.scalar(
                    select(func.count())
                    .select_from(LedgerEntry)
                    .where(LedgerEntry.bill_id == UUID(command["entity_id"]))
                )
                == 0
            )
    finally:
        with postgres_engine.begin() as connection:
            connection.execute(
                text("ALTER TABLE sync_receipts DROP CONSTRAINT ck_sync_test_receipt_reject")
            )


def test_diagnostic_failure_does_not_change_committed_receipt(actors, postgres_engine, monkeypatch):
    from flowtrace_server.sync import writer

    def fail(*args, **kwargs):
        raise OSError("synthetic diagnostic failure")

    monkeypatch.setattr(writer, "event", fail)
    alice, _, _ = actors
    command = operation(alice.book_id, "bill", expense(alice.book_id))
    applied = push(postgres_engine, alice, command)[0]
    assert applied["status"] == "applied"
    assert push(postgres_engine, alice, command)[0] == {**applied, "replayed": True}
