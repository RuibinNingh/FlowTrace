"""Validate fixed golden data, not the production ledger implementation."""
from __future__ import annotations

import json
import re
from copy import deepcopy
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path

ROOT = Path(__file__).resolve().parent
INTEGER = re.compile(r"(?:0|-?[1-9][0-9]*)\Z")
LOW, HIGH = -(2**63), 2**63 - 1


def integer(value: object) -> int:
    assert isinstance(value, str) and INTEGER.fullmatch(value), repr(value)
    number = int(value)
    assert LOW <= number <= HIGH, value
    return number


def load(name: str) -> dict:
    data = json.loads((ROOT / name).read_text(encoding="utf-8"))
    assert data["contract_version"] == "1.0"
    return data


def check() -> dict:
    ledger = load("scenarios.json")
    assert ledger["scenario_count"] == len(ledger["scenarios"])
    scenarios = set()
    step_count = 0
    for scenario in ledger["scenarios"]:
        assert scenario["scenario_id"] not in scenarios
        scenarios.add(scenario["scenario_id"])
        accounts = {a["id"]: a for a in scenario["setup"]["accounts"]}
        rates = {"CNY": "1", **scenario["setup"].get("valuation_rates", {})}
        prior = None
        steps = set()
        for step in scenario["steps"]:
            assert step["step_id"] not in steps
            steps.add(step["step_id"])
            step_count += 1
            result = step["expected"]["result"]
            assert result in {"applied", "replayed", "rejected"}
            state = step["expected"]["state"]
            if result in {"replayed", "rejected"}:
                assert state == prior, (scenario["scenario_id"], step["step_id"], "state changed")
            if result == "rejected":
                assert step["expected"]["error_code"]
            if step["command"]["action"] == "set_valuation_rate" and result == "applied":
                rates[step["command"]["currency"]] = step["command"]["rate"]
            positives = negatives = 0
            assert set(state["account_balances_minor"]) == set(accounts)
            for account_id, value in state["account_balances_minor"].items():
                amount = integer(value)
                account = accounts[account_id]
                if account["include_in_net_assets"]:
                    source_scale = account["currency_scale"]
                    rate = Decimal(rates[account["currency"]])
                    converted = int((Decimal(amount) * rate * Decimal(10 ** (2 - source_scale))).quantize(Decimal(1), rounding=ROUND_HALF_UP))
                    positives += max(converted, 0)
                    negatives += max(-converted, 0)
            asset = state["assets"]
            assert integer(asset["assets_minor"]) == positives
            assert integer(asset["liabilities_minor"]) == negatives
            assert integer(asset["net_minor"]) == positives - negatives
            for period in state["periods"].values():
                assert integer(period["net_minor"]) == integer(period["income_minor"]) - integer(period["expense_minor"])
                assert integer(period["expense_minor"]) == sum(integer(v) for v in period["category_expense_minor"].values())
                assert integer(period["budget_eligible_minor"]) == sum(integer(v) for v in period["budget_category_expense_minor"].values())
            for budget in state.get("budgets", {}).values():
                assert integer(budget["remaining_minor"]) == integer(budget["limit_minor"]) - integer(budget["spent_minor"])
            prior = deepcopy(state)
    vectors = load("money-time-vectors.json")
    for vector in vectors["money_vectors"]:
        try:
            integer(vector["input"]["amount_minor"])
            actual = True
        except AssertionError:
            actual = False
        assert actual == vector["accepted"]
    for vector in vectors["allocation_vectors"]:
        result = list(map(integer, vector["expected_minor"]))
        assert len(result) == vector["count"]
        assert sum(result) == integer(vector["total_minor"])
        assert result[:-1] == [integer(vector["total_minor"]) // vector["count"]] * (vector["count"] - 1)
    for vector in vectors["fx_vectors"]:
        source = vector["source"]
        value = Decimal(integer(source["amount_minor"])) * Decimal(vector["rate"]) * (Decimal(10) ** (vector["report_scale"] - source["currency_scale"]))
        assert int(value.quantize(Decimal(1), rounding=ROUND_HALF_UP)) == integer(vector["expected_minor"])
    permission = load("permissions.json")
    assert len({c["case_id"] for c in permission["cases"]}) == len(permission["cases"])
    assert all(c["principal"] in permission["subjects"] and isinstance(c["expected_allowed"], bool) for c in permission["cases"])
    return {"scenarios": len(scenarios), "steps": step_count, "permission_cases": len(permission["cases"]), "status": "fixture_consistency_passed"}


if __name__ == "__main__":
    print(json.dumps(check(), ensure_ascii=True))
