from copy import deepcopy
from datetime import date
from uuid import UUID

import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session

from flowtrace_server.sync.models import LedgerEntry, SyncEntity

from .helpers import account, expense, money, operation, push

pytestmark = pytest.mark.postgres


def adjusted_then_income(engine, owner):
    identifier = account(engine, owner, opening="10000")
    assert (
        push(
            engine,
            owner,
            operation(owner.book_id, "bill", expense(owner.book_id, identifier, "1000")),
        )[0]["status"]
        == "applied"
    )
    payload = expense(
        owner.book_id,
        identifier,
        "500",
        bill_type="balance_adjustment",
        target_balance_minor="9500",
    )
    adjustment = operation(owner.book_id, "bill", payload)
    assert push(engine, owner, adjustment)[0]["status"] == "applied"
    assert (
        push(
            engine,
            owner,
            operation(
                owner.book_id,
                "bill",
                expense(owner.book_id, identifier, "1000", bill_type="income"),
            ),
        )[0]["status"]
        == "applied"
    )
    return identifier, adjustment, payload


def financial_state(engine, account_id, adjustment_id):
    with Session(engine) as session:
        return session.get(SyncEntity, account_id).balance_minor, list(
            session.scalars(
                select(LedgerEntry.amount_minor).where(LedgerEntry.bill_id == adjustment_id)
            )
        )


@pytest.mark.parametrize(
    "changes",
    [
        pytest.param({"note": "只改合成备注"}, id="note"),
        pytest.param(
            {"business_date": "2026-10-22", "occurred_at": "2026-10-22T03:04:05.123456Z"}, id="time"
        ),
        pytest.param(
            {"flags": {"exclude_from_statistics": True, "exclude_from_budget": False}}, id="flags"
        ),
    ],
)
def test_adjustment_metadata_keeps_signed_entry_and_delete_undoes_it(
    actors, postgres_engine, changes
):
    owner, _, _ = actors
    identifier, adjustment, payload = adjusted_then_income(postgres_engine, owner)
    assert financial_state(postgres_engine, identifier, UUID(adjustment["entity_id"])) == (
        10500,
        [500],
    )
    changed = operation(
        owner.book_id,
        "bill",
        {**payload, **changes},
        identifier=UUID(adjustment["entity_id"]),
        action="update",
        revision="1",
    )
    assert push(postgres_engine, owner, changed)[0]["status"] == "applied"
    assert financial_state(postgres_engine, identifier, UUID(adjustment["entity_id"])) == (
        10500,
        [500],
    )
    if "business_date" in changes:
        with Session(postgres_engine) as session:
            assert session.scalar(
                select(LedgerEntry.business_date).where(
                    LedgerEntry.bill_id == UUID(adjustment["entity_id"])
                )
            ) == date(2026, 10, 22)
    deletion = operation(
        owner.book_id,
        "bill",
        {},
        identifier=UUID(adjustment["entity_id"]),
        action="delete",
        revision="2",
    )
    assert push(postgres_engine, owner, deletion)[0]["status"] == "applied"
    assert financial_state(postgres_engine, identifier, UUID(adjustment["entity_id"])) == (
        10000,
        [],
    )


def test_adjustment_explicit_financial_edit_rebases_without_its_old_entry(actors, postgres_engine):
    owner, _, _ = actors
    identifier, adjustment, payload = adjusted_then_income(postgres_engine, owner)
    changed = operation(
        owner.book_id,
        "bill",
        {**payload, "money": money("400"), "target_balance_minor": "9600"},
        identifier=UUID(adjustment["entity_id"]),
        action="update",
        revision="1",
    )
    assert push(postgres_engine, owner, changed)[0]["status"] == "applied"
    assert financial_state(postgres_engine, identifier, UUID(adjustment["entity_id"])) == (
        9600,
        [-400],
    )


def test_invalid_adjustment_financial_edit_preserves_original_entry(actors, postgres_engine):
    owner, _, _ = actors
    identifier, adjustment, payload = adjusted_then_income(postgres_engine, owner)
    changed = operation(
        owner.book_id,
        "bill",
        {**deepcopy(payload), "money": money("999"), "target_balance_minor": "9600"},
        identifier=UUID(adjustment["entity_id"]),
        action="update",
        revision="1",
    )
    result = push(postgres_engine, owner, changed)[0]
    assert result["error"]["code"] == "adjustment.amount_mismatch"
    assert financial_state(postgres_engine, identifier, UUID(adjustment["entity_id"])) == (
        10500,
        [500],
    )
