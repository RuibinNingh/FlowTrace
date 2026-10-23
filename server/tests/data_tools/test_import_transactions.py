from copy import deepcopy
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from sync.helpers import account, actor, epoch, expense, operation, push, share

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.imports.models import ImportBatch, ImportItem
from flowtrace_server.imports.schemas import ImportRequest, UndoRequest
from flowtrace_server.imports.service import apply_import, preview_import, undo_import
from flowtrace_server.sync.models import LedgerEntry, SyncChange, SyncClient, SyncEntity


def request(engine, owner, payloads, *, namespace=None):
    return ImportRequest.model_validate(
        {
            "batch_id": str(uuid4()),
            "client_id": str(owner.principal.client_id),
            "sync_epoch": epoch(engine),
            "document": {
                "format": "flowtrace-data-v1",
                "source_namespace": namespace or "synthetic-" + uuid4().hex,
                "rows": [
                    {
                        "source_id": str(uuid4()),
                        "entity_type": "bill",
                        "scope_id": str(owner.book_id),
                        "payload": p,
                    }
                    for p in payloads
                ],
            },
        }
    )


def state(engine, owner):
    with Session(engine) as session:
        return {
            "entities": session.scalar(select(func.count()).select_from(SyncEntity)),
            "entries": session.scalar(select(func.count()).select_from(LedgerEntry)),
            "changes": session.scalar(select(func.count()).select_from(SyncChange)),
            "batches": session.scalar(select(func.count()).select_from(ImportBatch)),
            "items": session.scalar(select(func.count()).select_from(ImportItem)),
            "clients": session.scalar(select(func.count()).select_from(SyncClient)),
        }


@pytest.mark.postgres
def test_preview_is_read_only_and_same_amount_distinct_source_survive(postgres_engine):
    owner = actor(postgres_engine)
    cash = account(postgres_engine, owner, opening="10000")
    payload = expense(owner.book_id, cash, "125")
    body = request(postgres_engine, owner, [payload, payload])
    before = state(postgres_engine, owner)
    with Session(postgres_engine) as session:
        preview = preview_import(session, owner.principal, body)
    assert state(postgres_engine, owner) == before
    assert preview["rows"][1]["warning"] == "same_content_distinct_source"
    with Session(postgres_engine) as session:
        result = apply_import(session, owner.principal, body)
    assert len(result["created"]) == 2
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, cash).balance_minor == 9750
        changes = list(
            session.scalars(
                select(SyncChange).where(SyncChange.commit_id == UUID(result["commit_id"]))
            )
        )
        assert len(changes) > 0
        assert len({change.commit_id for change in changes}) == 1
    cut = state(postgres_engine, owner)
    with Session(postgres_engine) as session:
        assert apply_import(session, owner.principal, body)["replayed"]
    assert state(postgres_engine, owner) == cut
    repeat = body.model_copy(update={"batch_id": str(uuid4())})
    with Session(postgres_engine) as session:
        replay = apply_import(session, owner.principal, repeat)
    assert replay["created"] == [] and len(replay["duplicates"]) == 2


@pytest.mark.postgres
def test_failure_after_valid_row_and_precommit_failure_roll_back_entire_batch(postgres_engine):
    owner = actor(postgres_engine)
    cash = account(postgres_engine, owner, opening="10000")
    body = request(
        postgres_engine,
        owner,
        [expense(owner.book_id, cash, "125"), expense(owner.book_id, uuid4(), "125")],
    )
    before = state(postgres_engine, owner)
    with Session(postgres_engine) as session:
        preview = preview_import(session, owner.principal, body)
    assert not preview["can_apply"]
    assert preview["errors"][0]["row"] == 2
    assert state(postgres_engine, owner) == before
    with Session(postgres_engine) as session, pytest.raises(ApiError):
        apply_import(session, owner.principal, body)
    assert state(postgres_engine, owner) == before
    body = request(postgres_engine, owner, [expense(owner.book_id, cash, "125")])

    def crash(_):
        raise RuntimeError("synthetic_before_commit")

    with Session(postgres_engine) as session, pytest.raises(RuntimeError):
        apply_import(session, owner.principal, body, before_commit=crash)
    assert state(postgres_engine, owner) == before
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, cash).balance_minor == 10000


@pytest.mark.postgres
def test_undo_restores_postings_and_modified_item_prevents_entire_undo(postgres_engine):
    owner = actor(postgres_engine)
    cash = account(postgres_engine, owner, opening="10000")
    body = request(
        postgres_engine,
        owner,
        [expense(owner.book_id, cash, "125"), expense(owner.book_id, cash, "75")],
    )
    with Session(postgres_engine) as session:
        result = apply_import(session, owner.principal, body)
    undo = UndoRequest(client_id=body.client_id, sync_epoch=body.sync_epoch)
    changed = deepcopy(body.document.rows[0].payload)
    changed["note"] = "合法后续修改"
    assert (
        push(
            postgres_engine,
            owner,
            operation(
                owner.book_id,
                "bill",
                changed,
                identifier=result["created"][0],
                action="update",
                revision="1",
            ),
        )[0]["status"]
        == "applied"
    )
    before = state(postgres_engine, owner)
    with Session(postgres_engine) as session, pytest.raises(ApiError) as error:
        undo_import(session, owner.principal, UUID(body.batch_id), undo)
    assert error.value.code == "import_undo_conflict"
    assert state(postgres_engine, owner) == before
    untouched = request(postgres_engine, owner, [expense(owner.book_id, cash, "50")])
    with Session(postgres_engine) as session:
        apply_import(session, owner.principal, untouched)
        result = undo_import(session, owner.principal, UUID(untouched.batch_id), undo)
    assert result["status"] == "undone"
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, cash).balance_minor == 9800
        assert apply_import(session, owner.principal, untouched)["status"] == "undone"


@pytest.mark.postgres
def test_readonly_member_cannot_preview_apply_or_undo(postgres_engine):
    owner, viewer = actor(postgres_engine), actor(postgres_engine)
    share(postgres_engine, owner, viewer, "viewer")
    body = request(postgres_engine, viewer, [expense(owner.book_id, None, "125")])
    body.document.rows[0].scope_id = str(owner.book_id)
    for function in (preview_import, apply_import):
        with Session(postgres_engine) as session, pytest.raises(ApiError) as error:
            function(session, viewer.principal, body)
        assert error.value.code == "scope_forbidden"


@pytest.mark.postgres
def test_all_eleven_bill_types_sources_revisions_and_undo_one_atomic_commit(postgres_engine):
    owner = actor(postgres_engine)
    bank = account(postgres_engine, owner, opening="10000", kind="bank")
    cash = account(postgres_engine, owner, opening="0")
    card = account(postgres_engine, owner, opening="-100", kind="credit_card")
    receivable = account(postgres_engine, owner, opening="0", kind="loan_receivable")
    payable = account(postgres_engine, owner, opening="0", kind="loan_payable")
    source_id = str(uuid4())
    payloads = [
        expense(owner.book_id, bank, "25", bill_type="income"),
        expense(owner.book_id, bank, "100"),
    ]
    for kind, first, second, amount in [
        ("transfer", bank, cash, "10"),
        ("credit_repayment", bank, card, "20"),
        ("loan_borrow", payable, bank, "30"),
        ("loan_lend", bank, receivable, "20"),
        ("loan_collect", receivable, bank, "5"),
        ("loan_repay", bank, payable, "10"),
    ]:
        payloads.append(
            expense(
                owner.book_id,
                amount=amount,
                bill_type=kind,
                from_account_id=str(first),
                to_account_id=str(second),
            )
        )
    for kind, amount in [("refund", "20"), ("reimbursement", "30")]:
        payloads.append(
            expense(
                owner.book_id,
                bank,
                amount,
                bill_type=kind,
                allocations=[
                    {
                        "source_bill_id": source_id,
                        "source_amount_minor": amount,
                        "receipt_amount_minor": amount,
                    }
                ],
            )
        )
    # 10000 +25-100-10-20+30-20+5-10+20+30 = 9950, then exact +50 adjustment.
    payloads.append(
        expense(
            owner.book_id, bank, "50", bill_type="balance_adjustment", target_balance_minor="10000"
        )
    )
    body = request(postgres_engine, owner, payloads)
    body.document.rows[1].source_id = source_id
    with Session(postgres_engine) as session:
        result = apply_import(session, owner.principal, body)
    assert len(result["created"]) == 11
    from flowtrace_server.imports.service import target_ids

    targets = target_ids(owner.principal, body)
    with Session(postgres_engine) as session:
        source = session.get(SyncEntity, UUID(targets[source_id]))
        assert source.revision == 3
        events = list(
            session.scalars(
                select(SyncChange).where(
                    SyncChange.commit_id == UUID(result["commit_id"]),
                    SyncChange.entity_id == source.id,
                    SyncChange.entity_type == "bill",
                    SyncChange.scope_id == owner.book_id,
                )
            )
        )
        assert len(events) == 1 and events[0].revision == 3
        assert events[0].data["source_summary"] == {
            "refund_source_minor": "20",
            "reimbursement_source_minor": "30",
            "remaining_source_minor": "50",
            "settlement_reason": "open",
        }
        assert session.get(SyncEntity, bank).balance_minor == 10000
        assert session.get(SyncEntity, cash).balance_minor == 10
        assert session.get(SyncEntity, card).balance_minor == -80
    with Session(postgres_engine) as session:
        undo_import(
            session,
            owner.principal,
            UUID(body.batch_id),
            UndoRequest(client_id=body.client_id, sync_epoch=body.sync_epoch),
        )
        assert session.get(SyncEntity, bank).balance_minor == 10000
        assert session.get(SyncEntity, cash).balance_minor == 0
        assert session.get(SyncEntity, card).balance_minor == -100
        assert session.get(SyncEntity, receivable).balance_minor == 0
        assert session.get(SyncEntity, payable).balance_minor == 0


@pytest.mark.postgres
def test_new_book_settings_account_and_bill_are_one_dependency_graph(postgres_engine):
    owner = actor(postgres_engine)
    book_id, account_id, expense_id = map(str, (uuid4(), uuid4(), uuid4()))
    body = request(postgres_engine, owner, [expense(book_id, account_id, "125")])
    from flowtrace_server.imports.schemas import ImportRow

    body.document.rows[0].source_id = expense_id
    body.document.rows[0].scope_id = book_id
    # Deliberately reversed dependencies; output creates the graph in a safe order.
    body.document.rows.extend(
        [
            ImportRow(
                source_id=account_id,
                entity_type="account",
                scope_id=book_id,
                payload={
                    "name": "导入合成现金",
                    "kind": "cash",
                    "opening": {"currency": "CNY", "currency_scale": 2, "amount_minor": "10000"},
                    "include_in_net_assets": True,
                    "hidden": False,
                },
            ),
            ImportRow(
                source_id=book_id,
                entity_type="book",
                scope_id=str(owner.principal.user_id),
                payload={
                    "name": "合成迁移账本",
                    "currency": "CNY",
                    "timezone": "Asia/Shanghai",
                    "month_start_day": 15,
                    "display_mode": "year",
                },
            ),
        ]
    )
    with Session(postgres_engine) as session:
        result = apply_import(session, owner.principal, body)
    assert len(result["created"]) == 3
    from flowtrace_server.imports.service import target_ids

    targets = target_ids(owner.principal, body)
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, UUID(targets[account_id])).balance_minor == 9875
        assert session.get(SyncEntity, UUID(targets[book_id])).payload["month_start_day"] == 15
        undo_import(
            session,
            owner.principal,
            UUID(body.batch_id),
            UndoRequest(client_id=body.client_id, sync_epoch=body.sync_epoch),
        )
        assert all(session.get(SyncEntity, UUID(i)).deleted for i in result["created"])


@pytest.mark.postgres
def test_public_template_reimbursement_is_negative_posting_with_tracking(postgres_engine):
    from flowtrace_server.imports.qianji_template import TemplateMapping, parse_qianji_csv

    from .test_parsers import table

    owner = actor(postgres_engine)
    cash = account(postgres_engine, owner, opening="10000")
    record = {
        "时间": "2026-10-21",
        "类型": "报销",
        "金额": "10.25",
        "优惠券": "1.25",
        "账户1": "现金",
    }
    parsed = parse_qianji_csv(
        table([record], tuple(record)),
        TemplateMapping(
            scope_id=str(owner.book_id), timezone="Asia/Shanghai", account_names={"现金": str(cash)}
        ),
    )
    body = ImportRequest(
        batch_id=str(uuid4()),
        client_id=str(owner.principal.client_id),
        sync_epoch=epoch(postgres_engine),
        document=parsed.document,
    )
    with Session(postgres_engine) as session:
        result = apply_import(session, owner.principal, body)
        bill = session.get(SyncEntity, UUID(result["created"][0]))
        assert bill.payload["bill_type"] == "expense"
        assert bill.payload["reimbursement_tracking"] is True
        assert session.get(SyncEntity, cash).balance_minor == 9100
        entry = session.scalar(select(LedgerEntry).where(LedgerEntry.bill_id == bill.id))
        assert entry.amount_minor == -900


@pytest.mark.postgres
def test_legacy_batch_retry_keeps_hash_when_new_optional_import_metadata_is_empty(postgres_engine):
    from flowtrace_server.imports.parsers import digest

    owner = actor(postgres_engine)
    cash = account(postgres_engine, owner, opening="10000")
    body = request(postgres_engine, owner, [expense(owner.book_id, cash, "125")])
    with Session(postgres_engine) as session:
        original = apply_import(session, owner.principal, body)
        # Simulate a batch stored by the earlier released schema, whose canonical
        # body did not yet define either optional metadata field.
        legacy_body = body.model_dump()
        legacy_body.pop("attachment_transfers")
        legacy_body["document"].pop("posting_hints")
        session.get(ImportBatch, UUID(body.batch_id)).content_hash = digest(legacy_body)
        session.commit()
        replayed = apply_import(session, owner.principal, body)
        assert replayed["replayed"] and replayed["created"] == original["created"]
        assert session.get(SyncEntity, cash).balance_minor == 9875
