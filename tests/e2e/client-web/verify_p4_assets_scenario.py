"""Independently check fixed UI expectations before any browser business write.

Uses only integer arithmetic and standard library, never production ledger,
HTTP, database, browser, credentials, or the UI's computed result.
"""

import json
import re
from pathlib import Path


def minor(value):
    assert isinstance(value, str) and re.fullmatch(r"-?(0|[1-9][0-9]*)(\.[0-9]{1,2})?", value)
    sign = -1 if value.startswith("-") else 1
    whole, _, fraction = value.lstrip("-").partition(".")
    return sign * (int(whole) * 100 + int(fraction.ljust(2, "0") or "0"))


def display(code, amount):
    sign = "-" if amount < 0 else ""
    return f"{code} {sign}{abs(amount) // 100}.{abs(amount) % 100:02d}"


def main():
    scenario = json.loads(Path(__file__).with_name("p4_assets_scenario.json").read_text("utf-8"))
    order = scenario["scenario_order"]
    assert len(set(order)) == 24 and len(order) == 25 and order.count("sync") == 2
    accounts = scenario["seed"]["accounts"]
    assert set(accounts) == {"cash", "eur", "fee_account", "credit", "receivable", "payable", "unknown_opening"}
    assert scenario["seed"]["book_payload"] == {
        "currency": "CNY", "timezone": "Asia/Shanghai", "month_start_day": 1, "show_assets": True,
    }
    allowed = {"marker", "today", "year_start"}

    def templates(value):
        if isinstance(value, str):
            assert set(re.findall(r"\{([^{}]+)\}", value)) <= allowed
        elif isinstance(value, dict):
            for child in value.values():
                templates(child)
        elif isinstance(value, list):
            for child in value:
                templates(child)

    templates(scenario)
    balances, currencies, kinds = {}, {}, {}
    for key, account in accounts.items():
        payload = account["payload"]
        assert account["name"] == payload["name"] == scenario["names"][key]
        assert "{marker}" in account["name"]
        assert payload["include_in_net_assets"] is True and payload["hidden"] is False
        assert payload["opening"]["currency_scale"] == 2
        balances[key] = int(payload["opening"]["amount_minor"])
        currencies[key], kinds[key] = payload["opening"]["currency"], payload["kind"]
    assert accounts["unknown_opening"]["payload"]["opening_date"] is None
    assert balances["unknown_opening"] == 0
    originals = dict(balances)
    states = {}
    checked = 0

    def totals(rate=None):
        if rate is None and any(value != 0 and currencies[key] != "CNY" for key, value in balances.items()):
            return None
        valued = {key: value if currencies[key] == "CNY" else value * (rate or 0) for key, value in balances.items()}
        positive = sum(max(value, 0) for value in valued.values())
        negative = sum(max(-value, 0) for value in valued.values())
        return {"assets": positive, "liabilities": negative, "net": positive - negative,
            "borrowed": sum(max(-value, 0) for key, value in valued.items() if kinds[key] == "loan_payable"),
            "lent": sum(max(value, 0) for key, value in valued.items() if kinds[key] == "loan_receivable")}

    def check(key, rate=None):
        nonlocal checked
        fixed = scenario["calculated"][key]
        for account, expected in fixed.get("balances_minor", {}).items():
            assert str(balances[account]) == expected, (key, account)
        computed = totals(rate)
        assert (None if computed is None else {name: str(value) for name, value in computed.items()}) == fixed["totals_minor"], key
        states[key] = (dict(balances), computed)
        checked += 1

    check("initial")
    new_card = minor(scenario["inputs"]["account-create"]["opening"])
    balances["ui_credit"], currencies["ui_credit"], kinds["ui_credit"] = new_card, "CNY", "credit_card"
    check("account-create")
    assert scenario["inputs"]["account-metadata"]["account_name_key"] == "ui_credit"
    movements = []
    cash_entry_count = 0
    for phase in ["fund-repayment", "fund-borrow", "fund-lend", "fund-collect", "fund-repay", "fund-fx"]:
        data = scenario["inputs"][phase]
        source, target = data["from_name_key"], data["to_name_key"]
        amount = minor(data["amount"])
        assert amount > 0
        target_amount = minor(data["target_money"]) if phase == "fund-fx" else amount
        if phase == "fund-fx":
            assert amount == 10000 and target_amount == 1250 and data["transfer_rate"] == "0.125"
            assert amount * 125 // 1000 == target_amount
            assert (source, target, currencies[source], currencies[target]) == ("cash", "eur", "CNY", "EUR")
        else:
            assert currencies[source] == currencies[target] == "CNY"
        delta = {source: -amount, target: target_amount}
        if phase == "fund-fx":
            fee = minor(data["fee"])
            assert fee == 25
            delta["fee_account"] = -fee
        for key, movement in delta.items():
            balances[key] += movement
        cash_entry_count += int("cash" in delta)
        movements.append(delta)
        check(phase)
    for rate in [8, 9]:
        check(f"valuation_at_{rate}", rate)

    # Check the UI strings against independently derived exact monetary values.
    phase_states = {"overview": "initial", "overview-narrow": "initial", "account-metadata": "account-create",
        "money-privacy": "account-create", "verify-reopen": "valuation_at_9"}
    for phase, values in scenario["expected"].items():
        key = phase_states.get(phase, phase)
        if key not in states:
            continue
        raw, aggregate = states[key]
        allowed_money = {display(currencies[account], value) for account, value in raw.items()}
        if aggregate is not None:
            allowed_money.update(display("CNY", value) for value in aggregate.values())
        for text in values:
            for code, amount in re.findall(r"\b(CNY|EUR) (-?[0-9]+\.[0-9]{2})", text):
                assert f"{code} {amount}" in allowed_money, (phase, code, amount)
        for account, expected in scenario["expected_rows"].get(phase, {}).items():
            assert expected == display(currencies[account], raw[account]), (phase, account)
    assert "合计暂不可用" in scenario["expected"]["fund-fx"]
    assert any("缺少账户启用日期" in value for value in scenario["expected"]["read-history"])
    assert scenario["absent"]["verify-reopen"] == [scenario["names"]["ui_credit"]]

    detail = scenario["calculated"]["read-details"]
    assert detail == {"opening_minor": str(originals["cash"]), "closing_minor": str(balances["cash"]), "entry_count": cash_entry_count}
    # The seed card has no consumption; the sole +50 repayment offsets oldest
    # opening debt. This is not the selected period's 0.00 statement due.
    card = scenario["calculated"]["read-credit"]
    limit = int(accounts["credit"]["payload"]["credit"]["limit"]["amount_minor"])
    debt = max(-balances["credit"], 0)
    assert card == {"total_debt_minor": str(debt), "overpayment_minor": "0",
        "available_credit_minor": str(limit - debt), "over_limit_minor": "0", "opening_carry_minor": str(debt),
        "charges_minor": "0", "statement_due_minor": "0", "remaining_due_minor": "0"}
    assert debt == 15000 and debt != int(card["statement_due_minor"])
    for delta in reversed(movements):
        for key, movement in delta.items():
            balances[key] -= movement
    assert balances == {**originals, "ui_credit": new_card}
    assert {key: str(value) for key, value in balances.items()} == scenario["calculated"]["cleanup_balances_minor"]
    print(json.dumps({"passed": True, "unique_phases": 24, "scheduled_runs": 25,
        "seed_accounts": 7, "ui_accounts": 1, "fund_bills": 6, "checked_monetary_states": checked,
        "net_minor_initial": "80000", "net_minor_after_new_card": "72000",
        "net_minor_rate8": "71975", "net_minor_rate9": "73225",
        "credit_debt_minor": "15000", "credit_period_due_minor": "0",
        "cash_entries": cash_entry_count, "normal_delete_restores_all_openings": True,
        "production_imports": False, "network_or_database_access": False}, ensure_ascii=False))


if __name__ == "__main__":
    main()
