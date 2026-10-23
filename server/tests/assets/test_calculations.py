import json
from copy import deepcopy
from pathlib import Path
from uuid import uuid4

import pytest
from sync.helpers import money

from flowtrace_server.assets.calculations import credit_calendar, value_accounts
from flowtrace_server.domain.money import INT64_MAX
from flowtrace_server.sync.schemas import AccountPayload, BillPayload


def record(amount="10000", *, currency="CNY", kind="cash", entries=None, **extra):
    payload = AccountPayload.model_validate(
        {
            "name": "纯投影",
            "kind": kind,
            "opening": money(amount, currency),
            "include_in_net_assets": True,
            "hidden": False,
            "opening_date": "2026-01-01",
            **extra,
        }
    ).model_dump()
    values = entries or []
    return {
        "id": str(uuid4()),
        "revision": "1",
        "payload": payload,
        "entries": values,
        "balance_minor": int(amount) + sum(r["amount_minor"] for r in values),
    }


def entry(day, amount, component="principal"):
    return {
        "business_date": day,
        "amount_minor": amount,
        "bill_id": str(uuid4()),
        "component": component,
    }


def test_signed_half_up_valuation_and_missing_zero_rate():
    positive = record("1", currency="EUR")
    negative = record("-1", currency="EUR", kind="credit_card")
    rates = [
        {
            "from_currency": "EUR",
            "to_currency": "CNY",
            "effective_date": "2026-10-21",
            "rate": "0.5",
            "rate_source": "manual",
        }
    ]
    result = value_accounts(
        [positive, negative], rates, "2026-10-21", "CNY", "exact_date", "current"
    )
    assert result["totals"]["assets_minor"] == "1"
    assert result["totals"]["liabilities_minor"] == "1" and result["totals"]["net_minor"] == "0"
    empty = value_accounts(
        [record("0", currency="EUR")], [], "2026-10-21", "CNY", "exact_date", "current"
    )
    assert empty["available"] and empty["totals"]["net_minor"] == "0"


def test_no_inverse_no_future_rate_and_overflow_unavailable():
    account = record("100", currency="EUR")
    rates = [
        {
            "from_currency": "CNY",
            "to_currency": "EUR",
            "effective_date": "2026-10-21",
            "rate": "0.125",
            "rate_source": "manual",
        },
        {
            "from_currency": "EUR",
            "to_currency": "CNY",
            "effective_date": "2026-10-22",
            "rate": "8",
            "rate_source": "manual",
        },
    ]
    missing = value_accounts(
        [account], rates, "2026-10-21", "CNY", "latest_on_or_before", "current"
    )
    assert not missing["available"] and missing["totals"] is None
    overflow = value_accounts(
        [record(str(INT64_MAX)), record("1")], [], "2026-10-21", "CNY", "exact_date", "current"
    )
    assert not overflow["available"] and "money.out_of_range" in overflow["issues"]


def test_current_integrity_and_future_opening_date_are_not_fake_history():
    account = record(opening_date="2026-10-22")
    previous = value_accounts([account], [], "2026-10-21", "CNY", "exact_date", "as_of")
    assert previous["available"] and previous["totals"]["net_minor"] == "0"
    assert previous["accounts"][0]["active_on_date"] is False
    account["balance_minor"] += 1
    broken = value_accounts([account], [], "2026-10-21", "CNY", "exact_date", "current")
    assert not broken["available"] and "asset.balance_unavailable" in broken["issues"]


def test_fifo_separates_opening_carry_statement_due_remaining_and_total_debt():
    account = record(
        "-10000",
        kind="credit_card",
        entries=[
            entry("2026-10-10", -6000),
            entry("2026-10-16", -2000),
            entry("2026-10-20", 12000),
        ],
        credit={
            "limit": money("20000"),
            "statement_day": 15,
            "due_mode": "fixed_day",
            "due_day": 5,
        },
    )
    result = credit_calendar(
        account["payload"], account["balance_minor"], account["entries"], "2026-10-01", "2026-11-01"
    )
    cycle = result["cycles"][0]
    assert cycle["statement_date"] == "2026-10-15" and cycle["due_date"] == "2026-11-05"
    assert cycle["charges_minor"] == "6000" and cycle["statement_due_minor"] == "6000"
    assert cycle["remaining_due_minor"] == "4000"
    assert result["total_debt_minor"] == "6000" and result["opening_carry_minor"] == "0"
    assert result["available_credit_minor"] == "14000"


@pytest.mark.parametrize(
    "inclusive,charges,end", [(True, "125", "2024-03-01"), (False, "0", "2024-02-29")]
)
def test_closing_31_leap_year_boundary_and_strictly_later_due(inclusive, charges, end):
    account = record(
        "0",
        kind="credit_card",
        opening_date="2024-01-01",
        entries=[entry("2024-02-29", -125)],
        credit={
            "statement_day": 31,
            "statement_day_inclusive": inclusive,
            "due_mode": "fixed_day",
            "due_day": 29,
        },
    )
    result = credit_calendar(
        account["payload"], account["balance_minor"], account["entries"], "2024-02-01", "2024-03-01"
    )
    assert result["cycles"][0]["charges_minor"] == charges
    assert result["cycles"][0]["end_date_exclusive"] == end
    assert result["cycles"][0]["due_date"] == "2024-03-29"


def test_partial_credit_limit_works_without_invented_calendar_and_overpay_not_debt():
    account = record("500", kind="credit_card", credit={"limit": money("10000")})
    result = credit_calendar(
        account["payload"], account["balance_minor"], [], "2026-10-01", "2026-11-01"
    )
    assert result["total_debt_minor"] == "0" and result["overpayment_minor"] == "500"
    assert result["available_credit_minor"] == "10500"
    assert not result["repayment_available"] and result["cycles"] == []
    assert result["issues"] == ["asset.credit_calendar_incomplete"]


def test_unknown_opening_date_never_turns_current_debt_into_statement_due():
    account = record(
        "-10000",
        kind="credit_card",
        opening_date=None,
        credit={"statement_day": 15, "due_mode": "days_after", "due_days": 20},
    )
    result = credit_calendar(
        account["payload"], account["balance_minor"], [], "2026-10-01", "2026-11-01"
    )
    assert result["total_debt_minor"] == "10000"
    assert result["cycles"][0]["due_date"] == "2026-11-04"
    assert result["cycles"][0]["statement_due_minor"] is None
    assert result["cycles"][0]["remaining_due_minor"] is None
    assert result["opening_carry_minor"] is None and not result["repayment_available"]


def test_schema_account_credit_currency_and_fx_closed_validation():
    from pydantic import ValidationError

    with pytest.raises(ValidationError):
        record(kind="bank", credit={"limit": money("100")})
    with pytest.raises(ValidationError):
        record(kind="credit_card", credit={"limit": money("100", "EUR")})
    with pytest.raises(ValidationError):
        record(kind="credit_card", credit={"due_mode": "days_after", "due_day": 5})
    bill = {
        "bill_type": "transfer",
        "from_account_id": str(uuid4()),
        "to_account_id": str(uuid4()),
        "money": money("10000"),
        "target_money": money("1250", "EUR"),
        "business_date": "2026-10-21",
        "business_timezone": "Asia/Shanghai",
        "transfer_fx": {"rate": "0.125", "rate_date": "2026-10-21", "rate_source": "manual"},
    }
    assert BillPayload.model_validate(bill).target_money.amount_minor == "1250"
    wrong = deepcopy(bill)
    wrong["target_money"]["amount_minor"] = "1251"
    with pytest.raises(ValidationError):
        BillPayload.model_validate(wrong)


CREDIT_CASES = json.loads(
    (Path(__file__).resolve().parents[3] / "contracts/fixtures/assets/credit-cases.json").read_text(
        encoding="utf-8"
    )
)["cases"]


def _contains(actual, expected):
    if isinstance(expected, dict):
        for key, value in expected.items():
            _contains(actual[key], value)
    elif isinstance(expected, list):
        assert len(actual) == len(expected)
        for found, wanted in zip(actual, expected, strict=True):
            _contains(found, wanted)
    else:
        assert actual == expected


@pytest.mark.parametrize("case", CREDIT_CASES, ids=lambda case: case["id"])
def test_shared_machine_readable_credit_goldens(case):
    payload = AccountPayload.model_validate(case["payload"]).model_dump()
    entries = [{**row, "amount_minor": int(row["amount_minor"])} for row in case["entries"]]
    actual = credit_calendar(
        payload, int(case["balance_minor"]), entries, case["start_date"], case["end_date_exclusive"]
    )
    _contains(actual, case["expected"])
