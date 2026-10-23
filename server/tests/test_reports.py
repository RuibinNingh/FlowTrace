import json
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import delete, text
from sqlalchemy.orm import Session
from sync.helpers import account, actor, expense, money, operation, push, revoke, share

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import AdminRole, User
from flowtrace_server.auth.service import issue_session
from flowtrace_server.books.router import update_membership
from flowtrace_server.config import Settings
from flowtrace_server.main import create_app
from flowtrace_server.reports.router import router
from flowtrace_server.reports.service import read_book_report
from flowtrace_server.sync.models import SyncEntity
from flowtrace_server.sync.projections import public_bill

pytestmark = pytest.mark.postgres
GOLDEN = json.loads(
    (Path(__file__).resolve().parents[2] / "contracts/fixtures/ledger/scenarios.json").read_text(
        encoding="utf-8"
    )
)["scenarios"]


@pytest.fixture
def report_http(postgres_engine):
    app = create_app(Settings(_env_file=None, database_url=None, environment="test"))
    app.state.engine = postgres_engine
    if not any(
        getattr(route, "path", None) == "/api/v1/books/{book_id}/report" for route in app.routes
    ):
        app.include_router(router)
    with TestClient(app) as client:
        yield client


@pytest.fixture
def report_actors(postgres_engine):
    return actor(postgres_engine), actor(postgres_engine), actor(postgres_engine)


def read(client, who, book_id=None, start="2026-10-01", end="2026-11-01", **extra):
    return client.get(
        f"/api/v1/books/{book_id or who.book_id}/report",
        params={
            "start_date": start,
            "end_date_exclusive": end,
            **extra,
        },
        headers={"Authorization": f"Bearer {who.token}"},
    )


def create(engine, who, kind, payload, *, scope=None):
    command = operation(scope or who.book_id, kind, payload)
    result = push(engine, who, command)[0]
    assert result["status"] == "applied", result
    return UUID(command["entity_id"])


def update(engine, who, entity_id, kind, payload, *, scope=None, action="update"):
    with Session(engine) as session:
        entity = session.get(SyncEntity, entity_id)
        revision = str(entity.revision)
    changed = operation(
        scope or who.book_id, kind, payload, identifier=entity_id, action=action, revision=revision
    )
    result = push(engine, who, changed)[0]
    assert result["status"] == "applied", result


def category(engine, who, name="费用", parent=None, kind="expense"):
    return create(
        engine,
        who,
        "category",
        {
            "name": name,
            "kind": kind,
            "parent_id": str(parent) if parent else None,
            "icon": "food",
            "sort_order": 0,
        },
    )


def test_owner_viewer_foreign_admin_and_revocation_are_rechecked(
    report_http, report_actors, postgres_engine
):
    owner, viewer, outsider = report_actors
    private_account = account(postgres_engine, owner)
    create(postgres_engine, owner, "bill", expense(owner.book_id, private_account))
    share(postgres_engine, owner, viewer, "viewer")
    owner_response = read(report_http, owner)
    visible = read(report_http, viewer, owner.book_id)
    assert visible.status_code == 200 and visible.json() == owner_response.json()
    assert visible.json()["report"]["totals"]["expense_minor"] == "100"
    assert str(private_account) not in visible.text
    assert {"private", "no-store"}.issubset(
        {directive.strip() for directive in visible.headers["cache-control"].split(",")}
    )
    assert visible.headers["x-content-type-options"] == "nosniff"
    assert read(report_http, outsider, owner.book_id).status_code == 403
    assert read(report_http, outsider, uuid4()).status_code == 403
    with Session(postgres_engine) as session:
        session.add(AdminRole(user_id=outsider.principal.user_id, role="service_admin"))
        user = session.get(User, owner.principal.user_id)
        _, admin_tokens = issue_session(session, user, uuid4(), "合成管理读取边界", "admin")
        session.commit()
    try:
        assert read(report_http, outsider, owner.book_id).status_code == 403
    finally:
        # A synthetic system role must not affect another module's bootstrap or
        # last-administrator proof when the suite changes collection order.
        with Session(postgres_engine) as session:
            session.execute(
                delete(AdminRole).where(
                    AdminRole.user_id == outsider.principal.user_id,
                    AdminRole.role == "service_admin",
                )
            )
            session.commit()
    response = report_http.get(
        f"/api/v1/books/{owner.book_id}/report",
        params={"start_date": "2026-10-01", "end_date_exclusive": "2026-11-01"},
        headers={"Authorization": f"Bearer {admin_tokens['access_token']}"},
    )
    assert response.status_code == 403
    revoke(postgres_engine, owner, viewer)
    assert read(report_http, viewer, owner.book_id).status_code == 403


def test_archived_child_categories_and_matching_budget_stay_in_history(
    report_http, report_actors, postgres_engine
):
    owner, _, _ = report_actors
    parent = category(postgres_engine, owner, "餐饮")
    child = category(postgres_engine, owner, "咖啡", parent)
    create(
        postgres_engine, owner, "bill", expense(owner.book_id, category_id=str(child), amount="125")
    )
    with Session(postgres_engine) as session:
        old = deepcopy(session.get(SyncEntity, child).payload)
    update(postgres_engine, owner, child, "category", {**old, "archived": True})
    budget_id = create(
        postgres_engine,
        owner,
        "budget",
        {
            "period_start": "2026-10-01",
            "period_end_exclusive": "2026-11-01",
            "total": None,
            "categories": [{"category_id": str(parent), "limit": money("200")}],
            "carry_forward": False,
        },
    )
    response = read(report_http, owner)
    assert response.status_code == 200
    report = response.json()["report"]
    assert report["available"]
    assert report["category_expense_minor"] == {str(child): "125"}
    assert report["category_expense_rollup_minor"] == {str(parent): "125", str(child): "125"}
    assert report["budget"]["spent_minor"] == "125"
    assert report["budget"]["remaining_minor"] == "75"
    assert read(report_http, owner, budget_id=str(budget_id)).json()["report"] == report


def test_private_cross_book_receipt_only_discloses_provable_shared_source_net(
    report_http, report_actors, postgres_engine
):
    owner, viewer, _ = report_actors
    source = create(postgres_engine, owner, "bill", expense(owner.book_id, amount="1001"))
    secret_book = create(
        postgres_engine,
        owner,
        "book",
        {
            "name": "私人报销去向",
            "currency": "CNY",
            "timezone": "Asia/Shanghai",
            "month_start_day": 1,
        },
        scope=owner.principal.user_id,
    )
    hidden_receipt = create(
        postgres_engine,
        owner,
        "bill",
        {
            "bill_type": "refund",
            "money": money("400"),
            "book_id": str(secret_book),
            "business_date": "2026-11-03",
            "business_timezone": "Asia/Shanghai",
            "note": "不得泄漏的合成正文",
            "allocations": [
                {
                    "source_bill_id": str(source),
                    "source_amount_minor": "400",
                    "receipt_amount_minor": "400",
                }
            ],
        },
        scope=secret_book,
    )
    share(postgres_engine, owner, viewer, "viewer")
    response = read(report_http, viewer, owner.book_id)
    assert response.status_code == 200
    report = response.json()["report"]
    assert report["available"] and not report["allocation_breakdown_available"]
    assert report["totals"]["expense_minor"] == "601"
    assert report["totals"]["refund_minor"] is None
    with Session(postgres_engine) as session:
        canonical = public_bill(session, session.get(SyncEntity, source))
    assert canonical["remaining_allocatable_minor"] == "601"
    assert not any(
        value in response.text
        for value in [str(secret_book), str(hidden_receipt), "不得泄漏的合成正文", "source_bill_id"]
    )
    assert read(report_http, viewer, secret_book).status_code == 403


def test_stale_principal_disabled_after_early_authentication_cannot_read(
    report_actors, postgres_engine
):
    owner, _, _ = report_actors
    with Session(postgres_engine) as session:
        session.get(User, owner.principal.user_id).enabled = False
        session.commit()
    with Session(postgres_engine) as session, pytest.raises(ApiError) as caught:
        read_book_report(session, owner.principal, owner.book_id, "2026-10-01", "2026-11-01")
    assert caught.value.code == "session_invalid"


def test_invalid_dates_foreign_budget_ambiguity_and_period_mismatch(
    report_http, report_actors, postgres_engine
):
    owner, _, _ = report_actors
    assert read(report_http, owner, start="2026-02-30").status_code == 422
    assert read(report_http, owner, start="2026-11-01").status_code == 422
    assert read(report_http, owner, budget_id=str(uuid4())).status_code == 404
    payload = {
        "period_start": "2026-10-01",
        "period_end_exclusive": "2026-11-01",
        "total": money("1000"),
        "categories": [],
        "carry_forward": False,
    }
    first = create(postgres_engine, owner, "budget", payload)
    create(postgres_engine, owner, "budget", payload)
    ambiguous = read(report_http, owner).json()["report"]
    assert not ambiguous["available"] and ambiguous["issues"] == ["report.budget_ambiguous"]
    assert ambiguous["totals"] is None
    assert read(report_http, owner, budget_id=str(first)).json()["report"]["available"]
    mismatch = read(report_http, owner, start="2026-09-01", budget_id=str(first)).json()["report"]
    assert mismatch["issues"] == ["budget.period_mismatch"]


@pytest.mark.parametrize("scenario", GOLDEN[:4], ids=lambda row: row["scenario_id"])
def test_real_sync_commands_and_pg_report_match_original_golden_periods(
    scenario, report_http, report_actors, postgres_engine
):
    owner, _, _ = report_actors
    setup = scenario["setup"]
    accounts = {
        row["id"]: account(
            postgres_engine,
            owner,
            opening=row["opening_minor"],
            kind=row["kind"],
            currency=row["currency"],
            scale=row["currency_scale"],
        )
        for row in setup["accounts"]
    }
    category_ids, bills, ids = {}, {}, {}

    def cat(alias, kind="expense"):
        key = (kind, alias)
        if key not in category_ids:
            category_ids[key] = category(postgres_engine, owner, alias, kind=kind)
        return str(category_ids[key])

    def normalize(raw):
        bill = deepcopy(raw)
        bill.pop("id", None)
        bill["book_id"] = str(owner.book_id)
        for field in ["account_id", "from_account_id", "to_account_id"]:
            if bill.get(field) is not None:
                bill[field] = str(accounts[bill[field]])
        if bill.get("category_id"):
            bill["category_id"] = cat(
                bill["category_id"], "income" if bill["bill_type"] == "income" else "expense"
            )
        for allocation in bill.get("allocations", []):
            allocation["source_bill_id"] = str(ids[allocation["source_bill_id"]])
        for component in [bill] + ([bill["fee"]] if bill.get("fee") else []):
            if component is not bill:
                component["account_id"] = str(accounts[component["account_id"]])
                component["category_id"] = cat(component["category_id"])
                component.setdefault("flags", bill["flags"])
            if component.get("reporting"):
                component["reporting"].update(
                    report_currency=setup["report_currency"], report_scale=setup["report_scale"]
                )
        return bill

    for step in scenario["steps"]:
        command = step["command"]
        if step["expected"]["result"] == "applied":
            action = command["action"]
            if action == "create_bill":
                raw = deepcopy(command["bill"])
                alias = raw["id"]
                ids[alias] = create(postgres_engine, owner, "bill", normalize(raw))
                bills[alias] = raw
            elif action == "update_bill":
                alias = command["bill_id"]
                bills[alias].update(deepcopy(command["changes"]))
                update(postgres_engine, owner, ids[alias], "bill", normalize(bills[alias]))
            elif action == "delete_bill":
                alias = command["bill_id"]
                update(postgres_engine, owner, ids[alias], "bill", {}, action="delete")
                del bills[alias]
        for period in setup["period_queries"]:
            response = read(
                report_http, owner, start=period["start_date"], end=period["end_date_exclusive"]
            )
            assert response.status_code == 200, (step["step_id"], response.text)
            actual = response.json()["report"]
            assert actual["available"], (step["step_id"], actual["issues"])
            expected = step["expected"]["state"]["periods"][period["period_id"]]
            inverse = {str(value): alias for (_, alias), value in category_ids.items()}
            for key, value in expected.items():
                found = (
                    actual["totals"].get(key)
                    if key in actual["totals"]
                    else {
                        inverse[category_id]: amount for category_id, amount in actual[key].items()
                    }
                )
                assert found == value, (step["step_id"], key, found, value)


def test_permission_revoke_waits_for_consistent_materialization_then_blocks_next_read(
    report_actors, postgres_engine, monkeypatch
):
    import flowtrace_server.reports.service as service

    owner, viewer, _ = report_actors
    create(postgres_engine, owner, "bill", expense(owner.book_id))
    share(postgres_engine, owner, viewer, "viewer")
    entered, release, revoke_entered = threading.Event(), threading.Event(), threading.Event()
    original = service.build_report

    def paused(*args, **kwargs):
        entered.set()
        assert release.wait(5)
        return original(*args, **kwargs)

    monkeypatch.setattr(service, "build_report", paused)

    def fetch():
        with Session(postgres_engine) as session:
            return read_book_report(
                session, viewer.principal, owner.book_id, "2026-10-01", "2026-11-01"
            )

    def remove():
        with Session(postgres_engine) as session:
            session.execute(text("SET LOCAL application_name = 'flowtrace-report-revoke-proof'"))
            revoke_entered.set()
            update_membership(
                session, owner.principal, owner.book_id, viewer.principal.user_id, None
            )
            session.commit()

    with ThreadPoolExecutor(max_workers=2) as pool:
        report_future = pool.submit(fetch)
        assert entered.wait(5)
        revoke_future = pool.submit(remove)
        assert revoke_entered.wait(5)
        observed_lock = False
        try:
            for _ in range(40):
                with postgres_engine.connect() as connection:
                    observed_lock = connection.scalar(
                        text(
                            "SELECT EXISTS(SELECT 1 FROM pg_stat_activity "
                            "WHERE application_name='flowtrace-report-revoke-proof' "
                            "AND wait_event_type='Lock')"
                        )
                    )
                if observed_lock:
                    break
                time.sleep(0.025)
            assert observed_lock and not revoke_future.done()
        finally:
            release.set()
        assert report_future.result(5)["report"]["totals"]["expense_minor"] == "100"
        revoke_future.result(5)
    with Session(postgres_engine) as session, pytest.raises(ApiError):
        read_book_report(session, viewer.principal, owner.book_id, "2026-10-01", "2026-11-01")


def test_four_budget_modes_match_original_golden_at_every_step(
    report_http, report_actors, postgres_engine
):
    owner, _, _ = report_actors
    scenario = GOLDEN[7]
    aliases = {
        alias: category(postgres_engine, owner, alias) for alias in ["food", "travel", "gift"]
    }
    budgets = {}
    for config in scenario["setup"]["budgets"]:
        budgets[config["id"]] = create(
            postgres_engine,
            owner,
            "budget",
            {
                "period_start": "2026-01-01",
                "period_end_exclusive": "2027-01-01",
                "total": None
                if config["total_limit_minor"] is None
                else money(config["total_limit_minor"]),
                "categories": [
                    {"category_id": str(aliases[key]), "limit": money(amount)}
                    for key, amount in config["categories"].items()
                ],
                "carry_forward": False,
            },
        )
    for step in scenario["steps"]:
        if step["expected"]["result"] == "applied":
            bill = deepcopy(step["command"]["bill"])
            bill.pop("id")
            bill["book_id"] = str(owner.book_id)
            bill["category_id"] = str(aliases[bill["category_id"]])
            create(postgres_engine, owner, "bill", bill)
        for alias, identifier in budgets.items():
            response = read(
                report_http, owner, start="2026-01-01", end="2027-01-01", budget_id=str(identifier)
            )
            assert response.status_code == 200
            data = response.json()["report"]
            assert data["available"], data["issues"]
            for key, value in step["expected"]["state"]["budgets"][alias].items():
                assert data["budget"][key] == value, (step["step_id"], alias, key)


@pytest.mark.parametrize(
    "bound", ["MAX_REPORT_ENTITIES", "MAX_REPORT_INPUT_BYTES", "MAX_REPORT_OUTPUT_BYTES"]
)
def test_report_limits_fail_closed_without_partial_numbers(
    bound, report_http, report_actors, postgres_engine, monkeypatch
):
    import flowtrace_server.reports.service as service

    owner, _, _ = report_actors
    create(postgres_engine, owner, "bill", expense(owner.book_id))
    monkeypatch.setattr(service, bound, 0)
    response = read(report_http, owner)
    assert response.status_code == 413
    assert response.json()["error"]["code"] == "report_limit"
    assert "totals" not in response.text


def test_revoke_committed_after_rr_snapshot_before_scope_locks_retries_then_denies(
    report_actors, postgres_engine, monkeypatch
):
    import flowtrace_server.reports.service as service

    owner, viewer, _ = report_actors
    create(postgres_engine, owner, "bill", expense(owner.book_id))
    share(postgres_engine, owner, viewer, "viewer")
    entered, release = threading.Event(), threading.Event()
    original = service.lock_scopes
    paused = False

    def pause_before_first_scope_lock(session, identifiers):
        nonlocal paused
        if not paused:
            paused = True
            entered.set()
            assert release.wait(5)
        return original(session, identifiers)

    monkeypatch.setattr(service, "lock_scopes", pause_before_first_scope_lock)

    def fetch():
        with Session(postgres_engine) as session:
            return read_book_report(
                session, viewer.principal, owner.book_id, "2026-10-01", "2026-11-01"
            )

    with ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(fetch)
        assert entered.wait(5)
        try:
            # Owner revocation does not reverse-lock the target User row. It
            # commits its control/book version before this reader locks scopes.
            revoke(postgres_engine, owner, viewer)
        finally:
            release.set()
        with pytest.raises(ApiError) as caught:
            future.result(5)
    assert caught.value.code == "scope_forbidden"
