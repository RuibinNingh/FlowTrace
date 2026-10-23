import json
from uuid import uuid4

import pytest
from sqlalchemy.orm import Session
from sync.helpers import account, actor, expense, operation, push, revoke, share

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.exports.schemas import ExportRequest
from flowtrace_server.exports.service import export_document, json_bytes


@pytest.mark.postgres
def test_export_filters_exact_money_order_configuration_and_no_unselected_scope(postgres_engine):
    owner = actor(postgres_engine)
    stranger = actor(postgres_engine)
    cash = account(postgres_engine, owner)
    commands = [
        operation(
            owner.book_id, "bill", expense(owner.book_id, cash, "125", business_date="2026-10-20")
        ),
        operation(
            owner.book_id, "bill", expense(owner.book_id, cash, "25", business_date="2026-10-21")
        ),
    ]
    assert all(r["status"] == "applied" for r in push(postgres_engine, owner, commands))
    body = ExportRequest(
        scope_ids=[str(owner.book_id)],
        date_from="2026-10-21",
        include_configuration=False,
        order="date_desc",
    )
    with Session(postgres_engine) as session:
        exported = export_document(session, owner.principal, body)
    parsed = json.loads(json_bytes(exported))
    assert len(parsed["document"]["rows"]) == 1
    row = parsed["document"]["rows"][0]
    assert row["payload"]["money"]["amount_minor"] == "25"
    assert row["payload"]["account_id"] == str(cash)
    assert str(stranger.book_id) not in json.dumps(parsed)
    assert set(parsed["scope_versions"]) == {str(owner.book_id), str(owner.principal.user_id)}


@pytest.mark.postgres
def test_shared_viewer_cannot_export_private_finance_or_after_revoke(postgres_engine):
    owner, viewer = actor(postgres_engine), actor(postgres_engine)
    cash = account(postgres_engine, owner)
    assert (
        push(
            postgres_engine,
            owner,
            operation(owner.book_id, "bill", expense(owner.book_id, cash, "125")),
        )[0]["status"]
        == "applied"
    )
    share(postgres_engine, owner, viewer, "viewer")
    body = ExportRequest(scope_ids=[str(owner.book_id)])
    with Session(postgres_engine) as session, pytest.raises(ApiError) as error:
        export_document(session, viewer.principal, body)
    assert error.value.code == "scope_forbidden"
    revoke(postgres_engine, owner, viewer)
    with Session(postgres_engine) as session, pytest.raises(ApiError) as error:
        export_document(session, viewer.principal, body)
    assert error.value.code == "scope_forbidden"


def test_export_rejects_unknown_scope_and_invalid_filters():
    from pydantic import ValidationError

    with pytest.raises(ValidationError):
        ExportRequest(scope_ids=[str(uuid4())], date_from="2026-11-02", date_to="2026-11-01")
    with pytest.raises(ValidationError):
        ExportRequest(scope_ids=[str(uuid4())], sort="arbitrary_sql")


@pytest.mark.postgres
def test_export_roundtrip_preserves_historical_adjustment_after_earlier_bill_edit(postgres_engine):
    """A historical target must not be reinterpreted against today's balance."""
    from uuid import UUID

    from sqlalchemy import select
    from sync.helpers import epoch

    from flowtrace_server.imports.parsers import parse_json
    from flowtrace_server.imports.schemas import ImportRequest
    from flowtrace_server.imports.service import apply_import, target_ids
    from flowtrace_server.sync.models import LedgerEntry, SyncEntity

    owner, destination = actor(postgres_engine), actor(postgres_engine)
    cash = account(postgres_engine, owner, opening="10000")
    source = operation(
        owner.book_id, "bill", expense(owner.book_id, cash, "100", business_date="2026-10-22")
    )
    adjustment = operation(
        owner.book_id,
        "bill",
        expense(
            owner.book_id,
            cash,
            "100",
            bill_type="balance_adjustment",
            target_balance_minor="10000",
            business_date="2026-10-20",
        ),
    )
    income = operation(
        owner.book_id,
        "bill",
        expense(owner.book_id, cash, "25", bill_type="income", business_date="2026-10-21"),
    )
    assert all(
        result["status"] == "applied"
        for result in push(postgres_engine, owner, [source, adjustment, income])
    )
    edited = expense(owner.book_id, cash, "50", business_date="2026-10-22")
    assert (
        push(
            postgres_engine,
            owner,
            operation(
                owner.book_id,
                "bill",
                edited,
                identifier=source["entity_id"],
                action="update",
                revision="1",
            ),
        )[0]["status"]
        == "applied"
    )
    with Session(postgres_engine) as session:
        exported = export_document(
            session,
            owner.principal,
            ExportRequest(scope_ids=[str(owner.principal.user_id), str(owner.book_id)]),
        )
    document = parse_json(json_bytes(exported))
    body = ImportRequest(
        batch_id=str(uuid4()),
        client_id=str(destination.principal.client_id),
        sync_epoch=epoch(postgres_engine),
        document=document,
        scope_mapping={str(owner.principal.user_id): str(destination.principal.user_id)},
    )
    with Session(postgres_engine) as session:
        result = apply_import(session, destination.principal, body)
        mapped = target_ids(destination.principal, body)
        assert session.get(SyncEntity, cash).balance_minor == 10075
        restored_cash = session.get(SyncEntity, UUID(mapped[str(cash)]))
        assert restored_cash.balance_minor == 10075
        restored_adjustment = session.get(SyncEntity, UUID(mapped[adjustment["entity_id"]]))
        assert restored_adjustment.payload["target_balance_minor"] == "10000"
        posting = session.scalar(
            select(LedgerEntry).where(LedgerEntry.bill_id == restored_adjustment.id)
        )
        assert posting.amount_minor == 100
        assert len(result["created"]) == len(document.rows)
