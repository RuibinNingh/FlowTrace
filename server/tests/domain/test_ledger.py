"""Compute fixture expectations from commands; never import the fixture checker.

The golden file declares the complete projections requested by each scenario.
ReferenceLedger may return additional available projections; each requested
projection is compared in full, including all balances and category keys.
"""

import json
from copy import deepcopy
from pathlib import Path

import pytest

from flowtrace_server.domain.ledger import ReferenceLedger

ROOT = Path(__file__).resolve().parents[3]
SCENARIOS = json.loads(
    (ROOT / "contracts/fixtures/ledger/scenarios.json").read_text(encoding="utf-8")
)["scenarios"]


@pytest.mark.parametrize("scenario", SCENARIOS, ids=lambda scenario: scenario["scenario_id"])
def test_shared_golden_scenarios(scenario):
    ledger = ReferenceLedger(scenario["setup"])
    for step in scenario["steps"]:
        before = ledger.project()
        actual = ledger.execute(step["command"])
        expected = step["expected"]
        assert actual["result"] == expected["result"], step["step_id"]
        assert actual.get("error_code") == expected.get("error_code"), step["step_id"]
        for field, value in expected["state"].items():
            assert actual["state"].get(field) == value, (step["step_id"], field)
        if actual["result"] in {"rejected", "replayed"}:
            assert actual["state"] == before, step["step_id"]


def _base():
    scenario = deepcopy(SCENARIOS[0])
    ledger = ReferenceLedger(scenario["setup"])
    ledger.execute(scenario["steps"][0]["command"])
    ledger.execute(scenario["steps"][1]["command"])
    return ledger


def test_invalid_edit_rolls_back_the_removed_original():
    ledger = _base()
    before = ledger.project()
    result = ledger.execute(
        {
            "action": "update_bill",
            "bill_id": "food_1",
            "changes": {"money": {"currency": "CNY", "currency_scale": 2, "amount_minor": "01"}},
        }
    )
    assert result["result"] == "rejected"
    assert result["error_code"] == "money.format"
    assert result["state"] == before


def test_shape_error_after_mutation_is_rolled_back_and_reraised():
    ledger = _base()
    before = ledger.project()
    with pytest.raises(AttributeError):
        ledger.execute({"action": "update_bill", "bill_id": "food_1", "changes": {"flags": []}})
    assert ledger.project() == before


def test_cumulative_balance_overflow_has_no_partial_entry():
    setup = deepcopy(SCENARIOS[0]["setup"])
    setup["accounts"] = [setup["accounts"][0]]
    setup["accounts"][0]["opening_minor"] = "9223372036854775807"
    ledger = ReferenceLedger(setup)
    before = ledger.project()
    bill = deepcopy(SCENARIOS[0]["steps"][0]["command"])
    bill["bill"]["money"]["amount_minor"] = "1"
    result = ledger.execute(bill)
    assert result["error_code"] == "money.out_of_range"
    assert result["state"] == before


def test_transfer_target_overflow_does_not_debit_source():
    setup = deepcopy(SCENARIOS[0]["setup"])
    setup["accounts"] = setup["accounts"][:2]
    setup["accounts"][1]["opening_minor"] = "9223372036854775807"
    setup["accounts"][1]["include_in_net_assets"] = False
    ledger = ReferenceLedger(setup)
    before = ledger.project()
    command = deepcopy(SCENARIOS[0]["steps"][5]["command"])
    command["bill"].pop("fee")
    command["bill"]["money"]["amount_minor"] = "1"
    result = ledger.execute(command)
    assert result["error_code"] == "money.out_of_range"
    assert result["state"] == before


def test_statistics_aggregate_overflow_rejects_without_an_account():
    setup = deepcopy(SCENARIOS[7]["setup"])
    setup["budgets"] = []
    ledger = ReferenceLedger(setup)
    first = deepcopy(SCENARIOS[7]["steps"][0]["command"])
    first["bill"]["money"]["amount_minor"] = "9223372036854775807"
    assert ledger.execute(first)["result"] == "applied"
    before = ledger.project()
    second = deepcopy(first)
    second["bill"]["id"] = "overflow"
    second["bill"]["money"]["amount_minor"] = "1"
    result = ledger.execute(second)
    assert result["error_code"] == "money.out_of_range"
    assert result["state"] == before
