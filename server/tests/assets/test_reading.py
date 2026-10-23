from copy import deepcopy
from uuid import UUID, uuid4

import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session
from sync.helpers import actor, expense, money, operation, push, revoke, share

from flowtrace_server.reports.service import read_book_report
from flowtrace_server.sync.models import LedgerEntry, SyncChange, SyncEntity

from .helpers import config_post, headers, new_account, overview, payload

pytestmark = pytest.mark.postgres


def create_bill(engine, who, **changes):
    body = expense(who.book_id, **changes)
    command = operation(who.book_id, "bill", body)
    result = push(engine, who, command)[0]
    assert result["status"] == "applied", result
    return UUID(command["entity_id"])


def test_current_and_as_of_are_distinct_and_net_debt_not_counted_twice(
    assets_http,
    postgres_engine,
):
    who = actor(postgres_engine)
    wallet = new_account(postgres_engine, who, opening="9007199254740993", hidden=True)
    new_account(postgres_engine, who, kind="loan_receivable", opening="300")
    new_account(postgres_engine, who, kind="loan_payable", opening="-200")
    new_account(postgres_engine, who, kind="credit_card", opening="-100")
    new_account(postgres_engine, who, opening="999", include_in_net_assets=False)
    create_bill(postgres_engine, who, account_id=wallet, amount="100")
    result = overview(assets_http, who)
    assert result.status_code == 200, result.text
    data = result.json()
    assert data["balance_mode"] == "current" and data["available"]
    assert data["totals"] == {
        "assets_minor": "9007199254741193",
        "liabilities_minor": "300",
        "net_minor": "9007199254740893",
        "borrowed_minor": "200",
        "lent_minor": "300",
    }
    historic = overview(assets_http, who, as_of="2026-10-20", balance_mode="as_of").json()
    assert int(historic["totals"]["net_minor"]) - int(data["totals"]["net_minor"]) == 100


def test_legacy_unknown_opening_date_refuses_history_but_current_provable(
    assets_http,
    postgres_engine,
):
    who = actor(postgres_engine)
    new_account(postgres_engine, who, opening_date=None)
    assert overview(assets_http, who).json()["available"]
    history = assets_http.get(
        "/api/v1/assets/history",
        headers=headers(who),
        params={"start_date": "2026-10-20", "end_date_exclusive": "2026-10-22"},
    ).json()
    assert len(history["points"]) == 2
    assert all(
        not row["available"]
        and row["totals"] is None
        and "asset.opening_date_required" in row["issues"]
        for row in history["points"]
    )
    as_of = overview(assets_http, who, balance_mode="as_of").json()
    assert not as_of["available"] and as_of["totals"] is None


def test_missing_valuation_is_not_partial_net_and_new_rates_do_not_change_old_bill(
    assets_http,
    postgres_engine,
):
    who = actor(postgres_engine)
    source = new_account(postgres_engine, who, opening="20000")
    target = new_account(
        postgres_engine,
        who,
        opening=money("0", "EUR"),
        opening_date="2026-01-01",
    )
    bill = {
        "bill_type": "transfer",
        "book_id": str(who.book_id),
        "money": money("10000"),
        "target_money": money("1250", "EUR"),
        "from_account_id": str(source),
        "to_account_id": str(target),
        "business_date": "2026-10-21",
        "business_timezone": "Asia/Shanghai",
        "transfer_fx": {"rate": "0.125", "rate_date": "2026-10-21", "rate_source": "manual"},
    }
    command = operation(who.book_id, "bill", bill)
    assert push(postgres_engine, who, command)[0]["status"] == "applied"
    frozen = payload(postgres_engine, UUID(command["entity_id"]))
    missing = overview(assets_http, who).json()
    assert not missing["available"] and missing["totals"] is None
    assert missing["totals_by_currency"]["CNY"]["net_minor"] == "10000"
    assert missing["totals_by_currency"]["EUR"]["net_minor"] == "1250"
    rate = {
        "id": str(uuid4()),
        "from_currency": "EUR",
        "to_currency": "CNY",
        "effective_date": "2026-10-21",
        "rate": "8",
        "rate_source": "manual",
    }
    added = config_post(
        assets_http, postgres_engine, who, "/api/v1/currencies/rates", {"rate": rate}
    )
    assert added.status_code == 200
    valued = overview(assets_http, who).json()
    assert valued["available"] and valued["totals"]["net_minor"] == "20000"
    assert payload(postgres_engine, UUID(command["entity_id"])) == frozen
    on_next_day = overview(assets_http, who, as_of="2026-10-22").json()
    assert not on_next_day["available"]
    explicit_carry = overview(
        assets_http, who, as_of="2026-10-22", valuation_policy="latest_on_or_before"
    ).json()
    assert explicit_carry["available"]
    assert next(a for a in explicit_carry["accounts"] if a["id"] == str(target))["rate_date"] == (
        "2026-10-21"
    )


def test_private_entries_keep_signed_money_after_book_revocation_hide_every_detail(
    assets_http,
    postgres_engine,
):
    owner, member, outsider = actor(postgres_engine), actor(postgres_engine), actor(postgres_engine)
    share(postgres_engine, owner, member)
    account_id = new_account(postgres_engine, member)
    command = operation(
        owner.book_id, "bill", expense(owner.book_id, account_id, note="只在有权账本可见")
    )
    assert push(postgres_engine, member, command)[0]["status"] == "applied"
    path = f"/api/v1/assets/accounts/{account_id}/entries"
    params = {"start_date": "2026-10-01", "end_date_exclusive": "2026-11-01"}
    details = assets_http.get(path, params=params, headers=headers(member)).json()
    assert details["entries"][0]["note"] == "只在有权账本可见"
    assert assets_http.get(path, params=params, headers=headers(owner)).status_code == 403
    assert assets_http.get(path, params=params, headers=headers(outsider)).status_code == 403
    revoke(postgres_engine, owner, member)
    safe = assets_http.get(path, params=params, headers=headers(member))
    assert safe.status_code == 200
    row = safe.json()["entries"][0]
    assert row["money"]["amount_minor"] == "-100" and not row["detail_available"]
    assert all(
        row[key] is None for key in ("bill_id", "book_id", "bill_type", "note", "category_id")
    )
    assert row["tag_ids"] == [] and row["attachment_ids"] == []
    assert str(owner.book_id) not in safe.text and command["entity_id"] not in safe.text
    assert "只在有权账本可见" not in safe.text
    assert safe.json()["opening_balance"]["amount_minor"] == "10000"
    assert safe.json()["closing_balance"]["amount_minor"] == "9900"


def test_shared_asset_viewer_is_scoped_and_revoked(assets_http, postgres_engine):
    owner, viewer = actor(postgres_engine), actor(postgres_engine)
    new_account(postgres_engine, owner, opening="10000", scope=owner.book_id)
    private_id = new_account(postgres_engine, owner, opening="30000", note="私人")
    share(postgres_engine, owner, viewer, "viewer")
    read = overview(assets_http, viewer, scope_id=str(owner.book_id))
    assert read.status_code == 200 and read.json()["totals"]["net_minor"] == "10000"
    assert str(private_id) not in read.text and "私人" not in read.text
    assert overview(assets_http, viewer, scope_id=str(owner.principal.user_id)).status_code == 403
    revoke(postgres_engine, owner, viewer)
    assert overview(assets_http, viewer, scope_id=str(owner.book_id)).status_code == 403


def test_prepaid_investment_principal_fee_and_interest_are_separate(assets_http, postgres_engine):
    who = actor(postgres_engine)
    cash = new_account(postgres_engine, who, opening="10000", kind="prepaid", provider_id="meal")
    invested = new_account(postgres_engine, who, opening="0", kind="investment", provider_id="fund")
    debt = new_account(postgres_engine, who, opening="0", kind="loan_receivable")
    bills = [
        {
            "bill_type": "transfer",
            "from_account_id": str(cash),
            "to_account_id": str(invested),
            "money": money("3000"),
            "fee": {
                "money": money("50"),
                "account_id": str(cash),
                "flags": {"exclude_from_statistics": False, "exclude_from_budget": False},
            },
        },
        {
            "bill_type": "loan_lend",
            "from_account_id": str(invested),
            "to_account_id": str(debt),
            "money": money("1000"),
        },
        {
            "bill_type": "loan_collect",
            "from_account_id": str(debt),
            "to_account_id": str(invested),
            "money": money("1000"),
        },
        {"bill_type": "income", "account_id": str(invested), "money": money("100")},
    ]
    for bill in bills:
        command = operation(
            who.book_id,
            "bill",
            {
                "book_id": str(who.book_id),
                "business_date": "2026-10-21",
                "business_timezone": "Asia/Shanghai",
                **bill,
            },
        )
        assert push(postgres_engine, who, command)[0]["status"] == "applied"
    total = overview(assets_http, who).json()
    assert total["totals"]["net_minor"] == "10050"
    with Session(postgres_engine) as session:
        report = read_book_report(session, who.principal, who.book_id, "2026-10-01", "2026-11-01")
    assert report["report"]["totals"]["income_minor"] == "100"
    assert report["report"]["totals"]["expense_minor"] == "50"


def test_opening_definition_and_archived_references_are_enforced(assets_http, postgres_engine):
    who = actor(postgres_engine)
    account_id = new_account(postgres_engine, who)
    bill_id = create_bill(postgres_engine, who, account_id=account_id)
    original = payload(postgres_engine, account_id)
    for changed in ({"opening_date": None}, {"opening": money("20000")}):
        result = push(
            postgres_engine,
            who,
            operation(
                who.principal.user_id,
                "account",
                {**original, **changed},
                identifier=account_id,
                action="update",
                revision="2",
            ),
        )[0]
        assert result["error"]["code"] == "account.definition_in_use"
    archived = operation(
        who.principal.user_id,
        "account",
        {**original, "archived": True},
        identifier=account_id,
        action="update",
        revision="2",
    )
    assert push(postgres_engine, who, archived)[0]["status"] == "applied"
    rejected = push(
        postgres_engine, who, operation(who.book_id, "bill", expense(who.book_id, account_id))
    )[0]
    assert rejected["error"]["code"] == "account.archived"
    body = payload(postgres_engine, bill_id)
    body["note"] = "原引用可维护"
    assert (
        push(
            postgres_engine,
            who,
            operation(who.book_id, "bill", body, identifier=bill_id, action="update", revision="1"),
        )[0]["status"]
        == "applied"
    )
    active = new_account(postgres_engine, who, opening_date="2026-10-22")
    before = push(
        postgres_engine, who, operation(who.book_id, "bill", expense(who.book_id, active))
    )[0]
    assert before["error"]["code"] == "account.before_opening"


def test_fx_frozen_omission_preserves_null_clear_and_wrong_change_rejected(
    assets_http,
    postgres_engine,
):
    who = actor(postgres_engine)
    source = new_account(postgres_engine, who)
    target = new_account(postgres_engine, who, opening=money("0", "EUR"))
    command = operation(
        who.book_id,
        "bill",
        {
            "bill_type": "transfer",
            "money": money("10000"),
            "target_money": money("1250", "EUR"),
            "book_id": str(who.book_id),
            "from_account_id": str(source),
            "to_account_id": str(target),
            "business_date": "2026-10-21",
            "business_timezone": "Asia/Shanghai",
            "transfer_fx": {"rate": "0.125", "rate_date": "2026-10-21", "rate_source": "manual"},
        },
    )
    assert push(postgres_engine, who, command)[0]["status"] == "applied"
    identifier = UUID(command["entity_id"])
    old = payload(postgres_engine, identifier)
    omitted = deepcopy(old)
    omitted.pop("transfer_fx")
    omitted["note"] = "旧客户端改备注"
    assert (
        push(
            postgres_engine,
            who,
            operation(
                who.book_id, "bill", omitted, identifier=identifier, action="update", revision="1"
            ),
        )[0]["status"]
        == "applied"
    )
    assert payload(postgres_engine, identifier)["transfer_fx"] == old["transfer_fx"]
    for changed, expected in [
        ({"transfer_fx": None}, "fx.frozen_rate_required"),
        ({"target_money": money("1251", "EUR")}, "fx.frozen_rate_mismatch"),
    ]:
        result = push(
            postgres_engine,
            who,
            operation(
                who.book_id,
                "bill",
                {**omitted, **changed},
                identifier=identifier,
                action="update",
                revision="2",
            ),
        )[0]
        assert result["error"]["code"] == expected
    with Session(postgres_engine) as session:
        entries = list(
            session.scalars(select(LedgerEntry).where(LedgerEntry.bill_id == identifier))
        )
        assert sorted(row.amount_minor for row in entries) == [-10000, 1250]
        assert session.get(SyncEntity, identifier).revision == 2
        changes = list(
            session.scalars(select(SyncChange).where(SyncChange.entity_id == identifier))
        )
        assert all(
            row.data is None
            or row.data.get("projection_kind") != "bill_public"
            or row.data["payload"]["transfer_fx"] == old["transfer_fx"]
            for row in changes
        )


def test_credit_calendar_real_postings_and_repayment_principal_not_income(
    assets_http,
    postgres_engine,
):
    who = actor(postgres_engine)
    card = new_account(
        postgres_engine,
        who,
        kind="credit_card",
        opening="-10000",
        credit={
            "limit": money("20000"),
            "statement_day": 15,
            "due_mode": "fixed_day",
            "due_day": 5,
        },
    )
    bank = new_account(postgres_engine, who, opening="100000")
    create_bill(postgres_engine, who, account_id=card, amount="6000", business_date="2026-10-10")
    create_bill(postgres_engine, who, account_id=card, amount="2000", business_date="2026-10-16")
    repayment = operation(
        who.book_id,
        "bill",
        {
            "book_id": str(who.book_id),
            "bill_type": "credit_repayment",
            "money": money("12000"),
            "from_account_id": str(bank),
            "to_account_id": str(card),
            "business_date": "2026-10-20",
            "business_timezone": "Asia/Shanghai",
        },
    )
    assert push(postgres_engine, who, repayment)[0]["status"] == "applied"
    result = assets_http.get(
        f"/api/v1/assets/accounts/{card}/credit-calendar",
        headers=headers(who),
        params={"start_date": "2026-10-01", "end_date_exclusive": "2026-11-01"},
    )
    assert result.status_code == 200, result.text
    data = result.json()
    assert data["total_debt_minor"] == "6000" and data["repayment_available"]
    assert data["cycles"][0]["statement_due_minor"] == "6000"
    assert data["cycles"][0]["remaining_due_minor"] == "4000"
    with Session(postgres_engine) as session:
        report = read_book_report(session, who.principal, who.book_id, "2026-10-01", "2026-11-01")
    assert report["report"]["totals"]["income_minor"] == "0"
    assert report["report"]["totals"]["expense_minor"] == "8000"


def test_fx_new_financial_fact_cannot_be_hidden_metadata_or_move(assets_http, postgres_engine):
    from flowtrace_server.auth.service import now
    from flowtrace_server.books.models import Book, BookMembership, SyncScope
    from flowtrace_server.sync.service import initialize_book_sync

    owner, editor = actor(postgres_engine), actor(postgres_engine)
    share(postgres_engine, owner, editor)
    first = new_account(postgres_engine, owner)
    second = new_account(postgres_engine, owner, opening=money("0", "EUR"))
    command = operation(
        owner.book_id,
        "bill",
        {
            "bill_type": "transfer",
            "book_id": str(owner.book_id),
            "money": money("10000"),
            "from_account_id": str(first),
            "to_account_id": str(second),
            "target_money": money("1250", "EUR"),
            "business_date": "2026-10-21",
            "business_timezone": "Asia/Shanghai",
            "transfer_fx": {"rate": "0.125", "rate_date": "2026-10-21", "rate_source": "manual"},
        },
    )
    assert push(postgres_engine, owner, command)[0]["status"] == "applied"
    identifier = UUID(command["entity_id"])
    public = payload(postgres_engine, identifier)
    public["from_account_id"], public["to_account_id"] = None, None
    public["preserve_hidden_financial_links"] = True
    # Same rounded money is not proof that a different frozen provenance is metadata.
    public["transfer_fx"]["rate_source"] = "tampered"
    result = push(
        postgres_engine,
        editor,
        operation(
            owner.book_id, "bill", public, identifier=identifier, action="update", revision="1"
        ),
    )[0]
    assert result["error"]["code"] == "hidden_financial_fields_changed"
    target_id = uuid4()
    with Session(postgres_engine) as session:
        book = Book(
            id=target_id,
            owner_user_id=owner.principal.user_id,
            name="迁移目标",
            currency="CNY",
            timezone="Asia/Shanghai",
            month_start_day=1,
            shared=False,
            deleted=False,
            created_at=now(),
        )
        session.add(book)
        session.flush()
        session.add_all(
            [
                BookMembership(
                    book_id=target_id, user_id=owner.principal.user_id, role="owner", active=True
                ),
                SyncScope(
                    id=target_id,
                    kind="book",
                    book_id=target_id,
                    owner_user_id=owner.principal.user_id,
                    revision=0,
                    permission_version=1,
                ),
            ]
        )
        session.flush()
        initialize_book_sync(session, book)
        session.commit()
    incoming = payload(postgres_engine, identifier)
    incoming["book_id"] = str(target_id)
    incoming["transfer_fx"]["rate_source"] = "tampered"
    move = operation(
        owner.book_id, "bill", incoming, identifier=identifier, action="update", revision="1"
    )
    move["move"] = {"target_scope_id": str(target_id), "attachment_replacements": []}
    result = push(postgres_engine, owner, move)[0]
    assert result["error"]["code"] == "move_financial_fields_changed"


def test_entries_old_rr_snapshot_retries_after_revoke_before_control_lock(
    postgres_engine,
    monkeypatch,
):
    import threading
    from concurrent.futures import ThreadPoolExecutor

    from flowtrace_server.assets import service

    owner, payer = actor(postgres_engine), actor(postgres_engine)
    share(postgres_engine, owner, payer)
    account_id = new_account(postgres_engine, payer)
    command = operation(
        owner.book_id, "bill", expense(owner.book_id, account_id, note="旧snapshot正文不可泄漏")
    )
    assert push(postgres_engine, payer, command)[0]["status"] == "applied"
    entered, release = threading.Event(), threading.Event()
    original, lock_attempts = service.lock_scopes, []

    def pause_before_scope_lock(session, identifiers):
        lock_attempts.append(1)
        if len(lock_attempts) == 1:
            # User/session authentication plus account discovery already fixed
            # the old RR snapshot. The control scope is deliberately not locked.
            entered.set()
            assert release.wait(5)
        return original(session, identifiers)

    monkeypatch.setattr(service, "lock_scopes", pause_before_scope_lock)

    def fetch():
        with Session(postgres_engine) as session:
            return service.read_entries(
                session, payer.principal, account_id, "2026-10-01", "2026-11-01", 0, 100
            )

    with ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(fetch)
        assert entered.wait(5)
        try:
            # A genuinely separate connection commits while the reader is in
            # its old snapshot; no fake grant/monkeypatched permission result.
            revoke(postgres_engine, owner, payer)
        finally:
            release.set()
        result = future.result(5)
    assert len(lock_attempts) >= 2
    assert result["entries"][0]["money"]["amount_minor"] == "-100"
    assert not result["entries"][0]["detail_available"]
    serialized = str(result)
    assert "旧snapshot正文不可泄漏" not in serialized
    assert command["entity_id"] not in serialized and str(owner.book_id) not in serialized


def test_entries_control_lock_proves_revoke_wait_then_fresh_read_redacts(
    postgres_engine,
    monkeypatch,
):
    import threading
    import time
    from concurrent.futures import ThreadPoolExecutor

    from sqlalchemy import text

    from flowtrace_server.assets import service
    from flowtrace_server.books.router import update_membership

    owner, payer = actor(postgres_engine), actor(postgres_engine)
    share(postgres_engine, owner, payer)
    account_id = new_account(postgres_engine, payer)
    command = operation(
        owner.book_id, "bill", expense(owner.book_id, account_id, note="授权内正文")
    )
    assert push(postgres_engine, payer, command)[0]["status"] == "applied"
    entered, release, revoke_entered = threading.Event(), threading.Event(), threading.Event()
    original, pids = service._records, {}

    def paused(session, *args):
        values = original(session, *args)
        if "reader" not in pids:
            pids["reader"] = session.scalar(text("SELECT pg_backend_pid()"))
            entered.set()
            assert release.wait(5)
        return values

    monkeypatch.setattr(service, "_records", paused)

    def fetch():
        with Session(postgres_engine) as session:
            return service.read_entries(
                session, payer.principal, account_id, "2026-10-01", "2026-11-01", 0, 100
            )

    def remove():
        with Session(postgres_engine) as session:
            pids["revoker"] = session.scalar(text("SELECT pg_backend_pid()"))
            revoke_entered.set()
            update_membership(
                session, owner.principal, owner.book_id, payer.principal.user_id, None
            )
            session.commit()

    with ThreadPoolExecutor(max_workers=2) as pool:
        read_future = pool.submit(fetch)
        assert entered.wait(5)
        revoke_future = pool.submit(remove)
        assert revoke_entered.wait(5)
        blocked = False
        try:
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                with postgres_engine.connect() as observer:
                    blocked = observer.scalar(
                        text(
                            "SELECT CAST(:reader AS int) = "
                            "ANY(pg_blocking_pids(CAST(:revoker AS int)))"
                        ),
                        pids,
                    )
                if blocked:
                    break
                # Only bounded polling; pg_blocking_pids, not elapsed time,
                # supplies the proof of the independent connection's lock wait.
                time.sleep(0.01)
            assert blocked and not revoke_future.done()
        finally:
            release.set()
        assert read_future.result(5)["entries"][0]["detail_available"]
        revoke_future.result(5)
    with Session(postgres_engine) as session:
        redacted = service.read_entries(
            session, payer.principal, account_id, "2026-10-01", "2026-11-01", 0, 100
        )
    assert not redacted["entries"][0]["detail_available"]
    assert redacted["entries"][0]["note"] is None
