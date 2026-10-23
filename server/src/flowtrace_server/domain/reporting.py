"""Exact, side-effect-free reports over an explicitly authorized bill set.

This module does not load data, grant access, or infer exchange rates. Callers
must supply the complete visible dataset, including receipts outside the period.
"""

from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass, field
from typing import Iterable, Mapping

from .calendar_rules import business_date, period_bounds
from .money import DomainError, Money, checked_minor, convert_money, parse_minor, round_half_up

UNCATEGORIZED = "uncategorized"
_TYPES = {
    "income",
    "expense",
    "transfer",
    "credit_repayment",
    "loan_borrow",
    "loan_lend",
    "loan_collect",
    "loan_repay",
    "refund",
    "reimbursement",
    "balance_adjustment",
}


@dataclass(frozen=True)
class ReportBill:
    id: str
    payload: Mapping
    remaining_allocatable_minor: str | None = None
    allocations_complete: bool = False
    hidden_allocation_count: int = 0


@dataclass(frozen=True)
class ReportQuery:
    book_id: str
    report_currency: str
    report_scale: int
    start_date: str
    end_date_exclusive: str

    def __post_init__(self) -> None:
        Money(self.report_currency, self.report_scale, 0)
        if business_date(self.start_date) >= business_date(self.end_date_exclusive):
            raise DomainError("date.invalid_period")

    @classmethod
    def month_at(
        cls, book_id: str, currency: str, scale: int, day: str, month_start_day: int = 1
    ) -> "ReportQuery":
        start, end = period_bounds(day, month_start_day)
        return cls(book_id, currency, scale, start, end)


@dataclass(frozen=True)
class ReportBudget:
    start_date: str
    end_date_exclusive: str
    total_limit_minor: str | None = None
    category_limits: Mapping[str, str] = field(default_factory=dict)


def _amount(payload: Mapping, query: ReportQuery) -> int:
    source = Money.from_json(payload.get("money"), positive=True)
    if (source.currency, source.currency_scale) == (query.report_currency, query.report_scale):
        return source.minor
    reporting = payload.get("reporting")
    if not isinstance(reporting, Mapping) or (
        reporting.get("report_currency", query.report_currency),
        reporting.get("report_scale", query.report_scale),
    ) != (query.report_currency, query.report_scale):
        raise DomainError("fx.report_unavailable")
    value = parse_minor(reporting.get("report_amount_minor"))
    # Freeze the historical rate. The current valuation rate is never consulted.
    if (
        convert_money(
            source, reporting.get("rate"), query.report_currency, query.report_scale
        ).minor
        != value
    ):
        raise DomainError("fx.amount_mismatch")
    if value < 0:
        raise DomainError("money.must_be_positive")
    return value


def _flags(payload: Mapping, fallback: Mapping | None = None) -> tuple[bool, bool]:
    value = payload.get("flags", fallback or {})
    if not isinstance(value, Mapping):
        raise DomainError("report.invalid_data")
    statistics, budget = (
        value.get("exclude_from_statistics", False),
        value.get("exclude_from_budget", False),
    )
    if type(statistics) is not bool or type(budget) is not bool:
        raise DomainError("report.invalid_data")
    return statistics, budget


def _category(value: object) -> str:
    if value is None:
        return UNCATEGORIZED
    if not isinstance(value, str) or not value:
        raise DomainError("report.invalid_data")
    return value


def _ancestors(category: str, parents: Mapping[str, str | None]) -> list[str]:
    result, seen = [], set()
    current: str | None = category
    while current is not None:
        if current in seen or len(result) >= 100:
            raise DomainError("report.category_cycle")
        seen.add(current)
        result.append(current)
        parent = parents.get(current)
        if parent is not None and (not isinstance(parent, str) or not parent):
            raise DomainError("report.invalid_data")
        current = parent
    return result


def _add(values: dict[str, int], key: str, amount: int) -> None:
    if amount:
        values[key] = values.get(key, 0) + amount


def _strings(values: Mapping[str, int]) -> dict[str, str]:
    return {key: str(checked_minor(value)) for key, value in sorted(values.items()) if value}


def _totals(income=0, expense=0, budget=0, gross=0, allocated=0, refund=0, reimbursement=0):
    return {
        "income_minor": income,
        "expense_minor": expense,
        "net_minor": income - expense,
        "budget_eligible_minor": budget,
        "gross_expense_minor": gross,
        "allocated_expense_minor": allocated,
        "refund_minor": refund,
        "reimbursement_minor": reimbursement,
    }


def _serialize_totals(values: Mapping[str, int | None]) -> dict[str, str | None]:
    return {
        key: None if value is None else str(checked_minor(value)) for key, value in values.items()
    }


def _budget_result(
    config: ReportBudget,
    query: ReportQuery,
    categories: Mapping[str, int],
    parents: Mapping[str, str | None],
) -> dict:
    if (config.start_date, config.end_date_exclusive) != (
        query.start_date,
        query.end_date_exclusive,
    ):
        raise DomainError("budget.period_mismatch")
    limits = {key: parse_minor(value) for key, value in config.category_limits.items()}
    total = None if config.total_limit_minor is None else parse_minor(config.total_limit_minor)
    if any(value < 0 for value in limits.values()) or (total is not None and total < 0):
        raise DomainError("money.must_be_positive")
    if total is None and not limits:
        raise DomainError("budget.limit_required")
    for category in limits:
        if any(parent in limits for parent in _ancestors(category, parents)[1:]):
            raise DomainError("budget.overlapping_categories")
    subtotal = checked_minor(sum(limits.values()))
    if total is not None and total < subtotal:
        raise DomainError("budget.total_below_categories")
    ceiling = subtotal if total is None else total
    all_categories = not limits or (total is not None and total > subtotal)
    grouped = {category: 0 for category in limits}
    other = 0
    for category, amount in categories.items():
        group = next((parent for parent in _ancestors(category, parents) if parent in limits), None)
        if group is None:
            other += amount
        else:
            grouped[group] += amount
    spent = checked_minor(sum(categories.values()) if all_categories else sum(grouped.values()))
    return {
        "limit_minor": str(ceiling),
        "spent_minor": str(spent),
        "remaining_minor": str(checked_minor(ceiling - spent)),
        "includes_other_categories": all_categories,
        "other_limit_minor": str(ceiling - subtotal)
        if total is not None and limits and total > subtotal
        else None,
        "other_spent_minor": str(checked_minor(other)) if all_categories else None,
        "categories": {
            category: {
                "limit_minor": str(limit),
                "spent_minor": str(checked_minor(grouped[category])),
                "remaining_minor": str(checked_minor(limit - grouped[category])),
            }
            for category, limit in sorted(limits.items())
        },
    }


def build_report(
    bills: Iterable[ReportBill],
    query: ReportQuery,
    *,
    category_parents: Mapping[str, str | None] | None = None,
    budget: ReportBudget | None = None,
) -> dict:
    """Return exact aggregates or a closed unavailable result, never partial zeros.

    ``remaining_allocatable_minor`` is an explicit caller assertion that the
    authorized projection covers the current input state. Do not reuse an old
    server value after a local allocation edit/deletion.
    """
    result = {
        "version": 1,
        "book_id": query.book_id,
        "report_currency": query.report_currency,
        "report_scale": query.report_scale,
        "start_date": query.start_date,
        "end_date_exclusive": query.end_date_exclusive,
        "available": False,
        "issues": [],
        "allocation_breakdown_available": False,
        "totals": None,
        "category_income_minor": None,
        "category_expense_minor": None,
        "budget_category_expense_minor": None,
        "category_income_rollup_minor": None,
        "category_expense_rollup_minor": None,
        "budget_category_rollup_minor": None,
        "calendar": None,
        "budget": None,
    }
    try:
        return _build(list(bills), query, dict(category_parents or {}), budget, result)
    except DomainError as error:
        result["issues"] = [error.code]
        return result
    except (KeyError, TypeError, AttributeError):
        result["issues"] = ["report.invalid_data"]
        return result


def _build(
    bills: list[ReportBill],
    query: ReportQuery,
    parents: dict,
    budget: ReportBudget | None,
    result: dict,
) -> dict:
    rows: dict[str, ReportBill] = {}
    for bill in bills:
        if not bill.id or bill.id in rows or not isinstance(bill.payload, Mapping):
            raise DomainError("report.duplicate_or_invalid_bill")
        if type(bill.hidden_allocation_count) is not int or bill.hidden_allocation_count < 0:
            raise DomainError("report.invalid_data")
        rows[bill.id] = ReportBill(
            bill.id,
            deepcopy(dict(bill.payload)),
            bill.remaining_allocatable_minor,
            bill.allocations_complete,
            bill.hidden_allocation_count,
        )
    for category in parents:
        _ancestors(category, parents)
    allocations: dict[str, list[tuple[str, str, str, int]]] = {}
    breakdown = True
    for identifier, row in rows.items():
        payload = row.payload
        if payload.get("bill_type") not in _TYPES:
            raise DomainError("report.invalid_data")
        business_date(payload.get("business_date"))
        Money.from_json(payload.get("money"), positive=True)
        if payload["bill_type"] not in {"refund", "reimbursement"}:
            continue
        if row.hidden_allocation_count:
            breakdown = False
        seen = set()
        received = 0
        for allocation in payload.get("allocations", []):
            source_id = allocation["source_bill_id"]
            if source_id in seen:
                raise DomainError("report.duplicate_allocation")
            seen.add(source_id)
            source = rows.get(source_id)
            if source is None:
                # Public visible allocations are in the same book. Hidden
                # cross-book sources must be redacted, never exposed as IDs.
                raise DomainError("report.source_unavailable")
            if source.payload.get("bill_type") != "expense":
                raise DomainError("report.invalid_source")
            amount = parse_minor(allocation["source_amount_minor"], positive=True)
            received += parse_minor(allocation["receipt_amount_minor"], positive=True)
            allocations.setdefault(source_id, []).append(
                (payload["business_date"], identifier, payload["bill_type"], amount)
            )
        component = parse_minor(payload.get("income_component_minor", "0"))
        receipt_amount = Money.from_json(payload["money"], positive=True).minor
        if (
            component < 0
            or (payload["bill_type"] == "reimbursement" and component != 0)
            or received + component > receipt_amount
            or (not row.hidden_allocation_count and received + component != receipt_amount)
        ):
            raise DomainError("report.invalid_allocation")

    totals = _totals()
    days: dict[str, dict] = {}
    income_categories: dict[str, int] = {}
    expense_categories: dict[str, int] = {}
    budget_categories: dict[str, int] = {}
    for identifier, row in rows.items():
        payload = row.payload
        day = payload["business_date"]
        if (
            payload.get("book_id") != query.book_id
            or not query.start_date <= day < query.end_date_exclusive
        ):
            continue
        kind = payload["bill_type"]
        statistics_excluded, budget_excluded = _flags(payload)
        contributions = _totals()
        category = _category(payload.get("category_id"))
        if kind == "income" and not statistics_excluded:
            contributions["income_minor"] = _amount(payload, query)
        elif kind == "refund" and not statistics_excluded:
            component = parse_minor(payload.get("income_component_minor", "0"))
            source_amount = Money.from_json(payload["money"], positive=True).minor
            if not 0 <= component <= source_amount:
                raise DomainError("allocation.exceeds_remaining")
            if component:
                contributions["income_minor"] = round_half_up(
                    _amount(payload, query) * component, source_amount
                )
        elif kind == "expense" and not (statistics_excluded and budget_excluded):
            original = Money.from_json(payload["money"], positive=True).minor
            report = _amount(payload, query)
            linked = sorted(allocations.get(identifier, []))
            visible = sum(amount for _, _, _, amount in linked)
            if row.remaining_allocatable_minor is not None:
                remaining = parse_minor(row.remaining_allocatable_minor)
                if not 0 <= remaining <= original:
                    raise DomainError("allocation.exceeds_remaining")
                allocated = original - remaining
                if visible > allocated or (row.allocations_complete and visible != allocated):
                    raise DomainError("report.allocation_stale")
            elif row.allocations_complete:
                allocated = visible
            else:
                raise DomainError("report.allocations_incomplete")
            if not 0 <= allocated <= original:
                raise DomainError("allocation.exceeds_remaining")
            reduction = round_half_up(report * allocated, original)
            net = report - reduction
            refund = reimbursement = prefix = 0
            for _, _, receipt_kind, amount in linked:
                delta = round_half_up(report * (prefix + amount), original) - round_half_up(
                    report * prefix, original
                )
                if receipt_kind == "refund":
                    refund += delta
                else:
                    reimbursement += delta
                prefix += amount
            if visible != allocated:
                breakdown = False
            if not statistics_excluded:
                contributions.update(
                    expense_minor=net,
                    gross_expense_minor=report,
                    allocated_expense_minor=reduction,
                    refund_minor=refund,
                    reimbursement_minor=reimbursement,
                )
                _add(expense_categories, category, net)
            if not budget_excluded:
                contributions["budget_eligible_minor"] = net
                _add(budget_categories, category, net)
        if contributions["income_minor"]:
            _add(income_categories, category, contributions["income_minor"])
        fee = payload.get("fee")
        if fee is not None:
            fee_statistics, fee_budget = _flags(fee, payload.get("flags"))
            if not (fee_statistics and fee_budget):
                amount = _amount(fee, query)
                fee_category = _category(fee.get("category_id"))
                if not fee_statistics:
                    contributions["expense_minor"] += amount
                    contributions["gross_expense_minor"] += amount
                    _add(expense_categories, fee_category, amount)
                if not fee_budget:
                    contributions["budget_eligible_minor"] += amount
                    _add(budget_categories, fee_category, amount)
        contributions["net_minor"] = contributions["income_minor"] - contributions["expense_minor"]
        if any(contributions.values()):
            daily = days.setdefault(day, _totals())
            for key, value in contributions.items():
                totals[key] += value
                daily[key] += value
    if not breakdown:
        totals["refund_minor"] = totals["reimbursement_minor"] = None
        for daily in days.values():
            daily["refund_minor"] = daily["reimbursement_minor"] = None

    def rollup(values):
        rolled = {}
        for category, amount in values.items():
            for parent in _ancestors(category, parents):
                _add(rolled, parent, amount)
        return _strings(rolled)

    # Prepare everything before publishing availability; an overflow never
    # returns a mixture of valid totals and silently truncated categories.
    prepared = {
        "totals": _serialize_totals(totals),
        "category_income_minor": _strings(income_categories),
        "category_expense_minor": _strings(expense_categories),
        "budget_category_expense_minor": _strings(budget_categories),
        "category_income_rollup_minor": rollup(income_categories),
        "category_expense_rollup_minor": rollup(expense_categories),
        "budget_category_rollup_minor": rollup(budget_categories),
        "calendar": {day: _serialize_totals(values) for day, values in sorted(days.items())},
        "budget": None
        if budget is None
        else _budget_result(budget, query, budget_categories, parents),
    }
    result.update(
        prepared,
        available=True,
        allocation_breakdown_available=breakdown,
        issues=[] if breakdown else ["report.allocation_detail_unavailable"],
    )
    return result
