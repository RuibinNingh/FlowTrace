"""Exact read projections. No database, current clock, network or balance mutation."""

from bisect import bisect_right
from calendar import monthrange
from collections import deque
from datetime import date, timedelta

from flowtrace_server.currencies.catalog import CURRENCY_SCALES
from flowtrace_server.domain.money import (
    DomainError,
    Money,
    checked_minor,
    convert_money,
    parse_minor,
)


def _totals():
    return dict.fromkeys(
        ["assets_minor", "liabilities_minor", "net_minor", "borrowed_minor", "lent_minor"], 0
    )


def _sum(totals, amount, kind):
    key = "assets_minor" if amount >= 0 else "liabilities_minor"
    totals[key] = checked_minor(totals[key] + abs(amount))
    totals["net_minor"] = checked_minor(totals["assets_minor"] - totals["liabilities_minor"])
    if kind == "loan_payable" and amount < 0:
        totals["borrowed_minor"] = checked_minor(totals["borrowed_minor"] - amount)
    if kind == "loan_receivable" and amount > 0:
        totals["lent_minor"] = checked_minor(totals["lent_minor"] + amount)


def string_totals(totals):
    return {key: str(value) for key, value in totals.items()}


def balance_on(payload, entries, day):
    anchor = payload.get("opening_date")
    if anchor is None:
        raise DomainError("asset.opening_date_required")
    if any(row["business_date"] < anchor for row in entries):
        raise DomainError("asset.before_opening")
    if day < anchor:
        return None
    return checked_minor(
        parse_minor(payload["opening"]["amount_minor"])
        + sum(row["amount_minor"] for row in entries if row["business_date"] <= day)
    )


class RateIndex:
    def __init__(self, rows):
        self.rows, self.days = {}, {}
        for row in rows:
            pair = (row["from_currency"], row["to_currency"])
            self.rows[(pair, row["effective_date"])] = row
            self.days.setdefault(pair, []).append(row["effective_date"])
        for values in self.days.values():
            values.sort()

    def find(self, source, target, day, policy):
        pair = (source, target)
        if policy == "exact_date":
            return self.rows.get((pair, day))
        days = self.days.get(pair, [])
        index = bisect_right(days, day) - 1
        return self.rows[(pair, days[index])] if index >= 0 else None


def value_accounts(accounts, rates, day, base, policy, mode):
    scale = CURRENCY_SCALES[base]
    rates = rates if isinstance(rates, RateIndex) else RateIndex(rates)
    # One rate lookup per currency/date, not per account. A history request may
    # include many accounts sharing a currency and thousands of stored rates.
    selected = {
        code: rates.find(code, base, day, policy)
        for code in {row["payload"]["opening"]["currency"] for row in accounts}
        if code != base
    }
    total, by_currency, rows, issues, bad_currencies = _totals(), {}, [], set(), set()
    for account in accounts:
        payload, entries = account["payload"], account["entries"]
        opening = Money.from_json(payload["opening"])
        row_issues, historic, active, converted, rate = [], None, None, None, None
        try:
            expected = checked_minor(opening.minor + sum(item["amount_minor"] for item in entries))
            if expected != account["balance_minor"]:
                raise DomainError("asset.balance_unavailable")
            amount = expected if mode == "current" else balance_on(payload, entries, day)
            active = amount is not None
            if mode == "as_of" and active:
                historic = Money(opening.currency, opening.currency_scale, amount).to_json()
            if not payload["include_in_net_assets"] or not active:
                pass
            else:
                currency_total = by_currency.setdefault(opening.currency, _totals())
                _sum(currency_total, amount, payload["kind"])
                if amount == 0 or opening.currency == base:
                    converted = amount
                else:
                    rate = selected[opening.currency]
                    if rate is None:
                        raise DomainError("asset.valuation_rate_required")
                    converted = convert_money(
                        Money(opening.currency, opening.currency_scale, amount),
                        rate["rate"],
                        base,
                        scale,
                    ).minor
                _sum(total, converted, payload["kind"])
        except DomainError as error:
            row_issues.append(error.code)
            if payload["include_in_net_assets"]:
                issues.add(error.code)
                if error.code != "asset.valuation_rate_required":
                    bad_currencies.add(opening.currency)
            converted = None
        rows.append(
            {
                "id": account["id"],
                "revision": account["revision"],
                "payload": payload,
                "balance": Money(
                    opening.currency, opening.currency_scale, account["balance_minor"]
                ).to_json(),
                "historical_balance": historic,
                "active_on_date": active,
                "valuation_minor": str(converted) if converted is not None else None,
                "rate": rate["rate"] if rate else ("1" if converted is not None else None),
                "rate_date": rate["effective_date"] if rate else None,
                "rate_source": rate["rate_source"] if rate else None,
                "issues": row_issues,
            }
        )
    return {
        "available": not issues,
        "issues": sorted(issues),
        "totals": string_totals(total) if not issues else None,
        "totals_by_currency": {
            code: string_totals(value)
            for code, value in by_currency.items()
            if code not in bad_currencies
        },
        "accounts": rows,
    }


def _month(year, month, shift):
    ordinal = year * 12 + month - 1 + shift
    y, m = divmod(ordinal, 12)
    if not 1 <= y <= 9999:
        raise DomainError("date.out_of_range")
    return y, m + 1


def _clamped(year, month, day):
    return date(year, month, min(day, monthrange(year, month)[1]))


def _due(closing, config):
    if config["due_mode"] == "days_after":
        try:
            return closing + timedelta(days=config["due_days"])
        except OverflowError:
            raise DomainError("date.out_of_range") from None
    candidate = _clamped(closing.year, closing.month, config["due_day"])
    if candidate <= closing:
        y, m = _month(closing.year, closing.month, 1)
        candidate = _clamped(y, m, config["due_day"])
    return candidate


def _lots(opening, entries, through=None):
    # Entry IDs are random and are not chronology. Same-day deterministic order
    # is date,bill UUID,component; both platforms can derive it from canonical data.
    queue, credit = deque(), max(opening, 0)
    if opening < 0:
        queue.append([None, -opening])
    for row in sorted(entries, key=lambda r: (r["business_date"], r["bill_id"], r["component"])):
        if through is not None and row["business_date"] >= through:
            continue
        movement = row["amount_minor"]
        if movement < 0:
            charge = -movement
            used = min(credit, charge)
            credit -= used
            if charge > used:
                queue.append([row["business_date"], charge - used])
        else:
            left = movement
            while queue and left:
                used = min(queue[0][1], left)
                queue[0][1] -= used
                left -= used
                if queue[0][1] == 0:
                    queue.popleft()
            credit += left
    return list(queue)


def credit_calendar(payload, balance, entries, start, end):
    if payload["kind"] != "credit_card":
        raise DomainError("asset.credit_card_required")
    config = payload.get("credit")
    debt, overpay = max(-balance, 0), max(balance, 0)
    limit = (
        None
        if config is None or config["limit"] is None
        else parse_minor(config["limit"]["amount_minor"])
    )
    result = {
        "total_debt_minor": str(checked_minor(debt)),
        "overpayment_minor": str(overpay),
        "available_credit_minor": None
        if limit is None
        else str(checked_minor(max(limit - debt + overpay, 0))),
        "over_limit_minor": None if limit is None else str(checked_minor(max(debt - limit, 0))),
        "opening_carry_minor": None,
        "repayment_available": False,
        "issues": [],
        "cycles": [],
    }
    if config is None or config["statement_day"] is None or config["due_mode"] is None:
        result["issues"] = ["asset.credit_calendar_incomplete"]
        return result
    complete = payload.get("opening_date") is not None
    if complete:
        # Also rejects invalid pre-anchor facts, rather than charting a guessed curve.
        balance_on(payload, entries, "9999-12-31")
    else:
        result["issues"] = ["asset.opening_date_required"]
    opening = parse_minor(payload["opening"]["amount_minor"])
    current_lots = _lots(opening, entries)
    if complete:
        result["opening_carry_minor"] = str(
            sum(amount for day, amount in current_lots if day is None)
        )
        result["repayment_available"] = True
    first, stop = date.fromisoformat(start), date.fromisoformat(end)
    y, m = first.year, first.month
    while (y, m) <= (stop.year, stop.month):
        closing = _clamped(y, m, config["statement_day"])
        if first <= closing < stop:
            py, pm = _month(y, m, -1)
            previous = _clamped(py, pm, config["statement_day"])
            shift = timedelta(days=int(config["statement_day_inclusive"]))
            try:
                begin, finish = previous + shift, closing + shift
            except OverflowError:
                raise DomainError("date.out_of_range") from None
            due = _due(closing, config)
            begin_s, finish_s = begin.isoformat(), finish.isoformat()
            cycle_complete = complete and payload["opening_date"] <= begin_s
            if complete and not cycle_complete:
                result["repayment_available"] = False
                if "asset.credit_period_incomplete" not in result["issues"]:
                    result["issues"].append("asset.credit_period_incomplete")
            at_close = _lots(opening, entries, finish_s)

            def for_cycle(lots):
                return str(
                    checked_minor(
                        sum(
                            amount
                            for day, amount in lots
                            if day is not None and begin_s <= day < finish_s
                        )
                    )
                )

            result["cycles"].append(
                {
                    "start_date": begin_s,
                    "end_date_exclusive": finish_s,
                    "statement_date": closing.isoformat(),
                    "due_date": due.isoformat(),
                    "charges_minor": str(
                        checked_minor(
                            sum(
                                -row["amount_minor"]
                                for row in entries
                                if begin_s <= row["business_date"] < finish_s
                                and row["amount_minor"] < 0
                            )
                        )
                    ),
                    "statement_due_minor": for_cycle(at_close) if cycle_complete else None,
                    "remaining_due_minor": for_cycle(current_lots) if cycle_complete else None,
                    "max_interest_free_days": (due - begin).days,
                    "min_interest_free_days": (due - (finish - timedelta(days=1))).days,
                }
            )
        if (y, m) == (stop.year, stop.month):
            break
        y, m = _month(y, m, 1)
    return result
