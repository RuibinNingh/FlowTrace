"""Report accepted fixture commands without executing the reference ledger."""

import json
from copy import deepcopy
from pathlib import Path

import pytest

from flowtrace_server.domain.reporting import ReportBill, ReportBudget, ReportQuery, build_report

SCENARIOS = json.loads(
    (Path(__file__).resolve().parents[3] / "contracts/fixtures/ledger/scenarios.json").read_text(
        encoding="utf-8"
    )
)["scenarios"]


@pytest.mark.parametrize(
    "scenario", [*SCENARIOS[:4], SCENARIOS[7]], ids=lambda row: row["scenario_id"]
)
def test_original_golden_periods_and_budget_modes(scenario):
    setup = scenario["setup"]
    bills = {}
    for step in scenario["steps"]:
        command = step["command"]
        if step["expected"]["result"] == "applied":
            if command["action"] == "create_bill":
                bill = deepcopy(command["bill"])
                bills[bill.pop("id")] = bill
            elif command["action"] == "update_bill":
                bills[command["bill_id"]].update(deepcopy(command["changes"]))
            elif command["action"] == "delete_bill":
                del bills[command["bill_id"]]
        for period in setup["period_queries"]:
            query = ReportQuery(
                setup["book_id"],
                setup["report_currency"],
                setup["report_scale"],
                period["start_date"],
                period["end_date_exclusive"],
            )
            rows = [
                ReportBill(key, value, allocations_complete=True) for key, value in bills.items()
            ]
            actual = build_report(rows, query)
            assert actual["available"], (step["step_id"], actual["issues"])
            expected = step["expected"]["state"]["periods"][period["period_id"]]
            for key, value in expected.items():
                found = actual["totals"].get(key) if key in actual["totals"] else actual[key]
                assert found == value, (step["step_id"], key, found, value)
            for config in setup.get("budgets", []):
                budget = ReportBudget(
                    query.start_date,
                    query.end_date_exclusive,
                    config["total_limit_minor"],
                    config["categories"],
                )
                measured = build_report(rows, query, budget=budget)
                assert measured["available"], measured["issues"]
                for key, value in step["expected"]["state"]["budgets"][config["id"]].items():
                    assert measured["budget"][key] == value, (step["step_id"], config["id"], key)


QUERY = ReportQuery("book", "CNY", 2, "2026-10-01", "2026-11-01")


def expense(identifier="source", amount="1001", **changes):
    payload = {
        "book_id": "book",
        "bill_type": "expense",
        "business_date": "2026-10-21",
        "money": {"currency": "CNY", "currency_scale": 2, "amount_minor": amount},
        "category_id": "food",
        "flags": {"exclude_from_statistics": False, "exclude_from_budget": False},
        **changes,
    }
    return ReportBill(identifier, payload, allocations_complete=True)


def receipt(identifier="refund", source="source", amount="400", kind="refund", **changes):
    payload = {
        "book_id": "book",
        "bill_type": kind,
        "business_date": "2026-11-03",
        "money": {"currency": "CNY", "currency_scale": 2, "amount_minor": amount},
        "allocations": [
            {
                "source_bill_id": source,
                "source_amount_minor": amount,
                "receipt_amount_minor": amount,
            }
        ],
        "income_component_minor": "0",
        **changes,
    }
    return ReportBill(identifier, payload, allocations_complete=True)


def test_hierarchy_calendar_and_parent_budget_include_children_once():
    rows = [expense(category_id="coffee"), receipt()]
    config = ReportBudget(QUERY.start_date, QUERY.end_date_exclusive, None, {"food": "1000"})
    data = build_report(
        rows, QUERY, category_parents={"coffee": "food", "food": None}, budget=config
    )
    assert data["totals"]["expense_minor"] == "601"
    assert data["category_expense_minor"] == {"coffee": "601"}
    assert data["category_expense_rollup_minor"] == {"coffee": "601", "food": "601"}
    assert data["calendar"]["2026-10-21"]["expense_minor"] == "601"
    assert "2026-11-03" not in data["calendar"]
    assert data["budget"]["spent_minor"] == "601"
    assert data["budget"]["remaining_minor"] == "399"


def test_public_remaining_proves_net_without_disclosing_hidden_receipt():
    source = expense()
    projected = ReportBill(source.id, source.payload, remaining_allocatable_minor="601")
    data = build_report([projected], QUERY)
    assert data["available"] is True
    assert data["totals"]["expense_minor"] == "601"
    assert data["totals"]["allocated_expense_minor"] == "400"
    assert data["totals"]["refund_minor"] is None
    assert data["totals"]["reimbursement_minor"] is None
    assert data["allocation_breakdown_available"] is False
    assert "source_bill_id" not in json.dumps(data)


def test_unknown_source_and_unknown_remaining_return_no_partial_zero():
    unknown = ReportBill("source", expense().payload)
    data = build_report([unknown], QUERY)
    assert not data["available"]
    assert data["issues"] == ["report.allocations_incomplete"]
    assert data["totals"] is None
    data = build_report([receipt(source="private-secret-identifier")], QUERY)
    assert data["issues"] == ["report.source_unavailable"]
    assert "private-secret-identifier" not in json.dumps(data)


def test_stale_remaining_rejected_instead_of_ignoring_new_local_refund():
    row = ReportBill("source", expense().payload, remaining_allocatable_minor="1001")
    data = build_report([row, receipt()], QUERY)
    assert not data["available"]
    assert data["issues"] == ["report.allocation_stale"]


@pytest.mark.parametrize(
    "limits,total,error",
    [
        ({"food": "1000", "coffee": "100"}, None, "budget.overlapping_categories"),
        ({"food": "1000"}, "999", "budget.total_below_categories"),
    ],
)
def test_invalid_budget_returns_unavailable_without_changing_inputs(limits, total, error):
    rows = [expense()]
    before = deepcopy(rows)
    data = build_report(
        rows,
        QUERY,
        category_parents={"coffee": "food"},
        budget=ReportBudget(QUERY.start_date, QUERY.end_date_exclusive, total, limits),
    )
    assert data["issues"] == [error]
    assert data["totals"] is None
    assert rows == before


def test_cycle_is_rejected_and_aggregate_overflow_is_not_partial():
    data = build_report([expense()], QUERY, category_parents={"food": "coffee", "coffee": "food"})
    assert data["issues"] == ["report.category_cycle"]
    data = build_report([expense(amount="9223372036854775807"), expense("other", "1")], QUERY)
    assert data["issues"] == ["money.out_of_range"]
    assert data["totals"] is None


def test_missing_fx_only_blocks_a_contributing_component():
    foreign = expense(money={"currency": "USD", "currency_scale": 2, "amount_minor": "100"})
    assert build_report([foreign], QUERY)["issues"] == ["fx.report_unavailable"]
    excluded = expense(
        money=foreign.payload["money"],
        flags={"exclude_from_statistics": True, "exclude_from_budget": True},
    )
    assert build_report([excluded], QUERY)["available"] is True


def test_period_boundary_is_clamped_from_original_month_anchor():
    query = ReportQuery.month_at("book", "CNY", 2, "2026-02-10", 31)
    assert (query.start_date, query.end_date_exclusive) == ("2026-01-31", "2026-02-28")
    following = ReportQuery.month_at("book", "CNY", 2, "2026-02-28", 31)
    assert (following.start_date, following.end_date_exclusive) == ("2026-02-28", "2026-03-31")


def test_cumulative_rounding_by_stable_receipt_order_closes_to_original():
    row = expense(
        amount="3",
        money={"currency": "USD", "currency_scale": 2, "amount_minor": "3"},
        reporting={
            "rate": "0.5",
            "report_currency": "CNY",
            "report_scale": 2,
            "report_amount_minor": "2",
        },
    )
    r = receipt("a", amount="1")
    e = receipt("b", amount="2", kind="reimbursement")
    one = build_report([e, row, r], QUERY)
    two = build_report([row, r, e], QUERY)
    assert one == two
    assert one["totals"]["gross_expense_minor"] == "2"
    assert one["totals"]["refund_minor"] == "1"
    assert one["totals"]["reimbursement_minor"] == "1"
    assert one["totals"]["expense_minor"] == "0"


def test_large_report_amounts_are_decimal_strings_beyond_javascript_exact_integer_range():
    data = build_report([expense(amount="9007199254740993")], QUERY)
    assert data["totals"]["expense_minor"] == "9007199254740993"
    assert json.loads(json.dumps(data))["totals"]["expense_minor"] == "9007199254740993"


def test_invalid_receipt_conservation_never_reduces_a_source_expense():
    broken = receipt(income_component_minor="1", kind="reimbursement")
    data = build_report([expense(), broken], QUERY)
    assert not data["available"]
    assert data["issues"] == ["report.invalid_allocation"]
    assert data["totals"] is None
