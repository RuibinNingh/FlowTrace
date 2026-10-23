from copy import deepcopy

import pytest

from flowtrace_server.domain.ledger import ReferenceLedger


@pytest.mark.parametrize(
    "changes",
    [
        {"note": "只改合成备注"},
        {"business_date": "2026-10-22"},
        {"flags": {"exclude_from_statistics": True, "exclude_from_budget": False}},
    ],
)
def test_reference_adjustment_retains_signed_entry_after_later_income(changes):
    ledger = ReferenceLedger(
        {
            "principal": "alice",
            "book_id": "test",
            "report_currency": "CNY",
            "report_scale": 2,
            "accounts": [
                {
                    "id": "cash",
                    "currency": "CNY",
                    "currency_scale": 2,
                    "kind": "cash",
                    "owner_user_id": "alice",
                    "opening_minor": "10000",
                    "include_in_net_assets": True,
                }
            ],
            "period_queries": [],
            "budgets": [],
        }
    )
    base = {
        "book_id": "test",
        "account_id": "cash",
        "business_date": "2026-10-21",
        "business_timezone": "Asia/Shanghai",
        "money": {"currency": "CNY", "currency_scale": 2, "amount_minor": "1000"},
    }
    for identifier, kind, amount, extra in (
        ("expense", "expense", "1000", {}),
        ("adjust", "balance_adjustment", "500", {"target_balance_minor": "9500"}),
        ("income", "income", "1000", {}),
    ):
        bill = {
            **deepcopy(base),
            "id": identifier,
            "bill_type": kind,
            "money": {**base["money"], "amount_minor": amount},
            **extra,
        }
        assert ledger.execute({"action": "create_bill", "bill": bill})["result"] == "applied"
    result = ledger.execute({"action": "update_bill", "bill_id": "adjust", "changes": changes})
    assert result["result"] == "applied"
    assert result["state"]["account_balances_minor"]["cash"] == "10500"
    assert (
        ledger.execute({"action": "delete_bill", "bill_id": "adjust"})["state"][
            "account_balances_minor"
        ]["cash"]
        == "10000"
    )
