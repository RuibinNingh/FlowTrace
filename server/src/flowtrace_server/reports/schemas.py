from typing import Annotated, Literal

from pydantic import AfterValidator, Field, StringConstraints, model_validator

from flowtrace_server.domain.money import parse_minor
from flowtrace_server.sync.schemas import (
    BusinessDate,
    ClosedModel,
    Identifier,
    Revision,
    SignedMinor,
)


def _checked(value: str) -> str:
    parse_minor(value)
    return value


ReportMinor = Annotated[SignedMinor, AfterValidator(_checked)]
ReportIssue = Literal[
    "report.allocations_incomplete",
    "report.source_unavailable",
    "report.allocation_stale",
    "report.category_cycle",
    "report.invalid_data",
    "report.duplicate_or_invalid_bill",
    "report.duplicate_allocation",
    "report.invalid_source",
    "report.invalid_allocation",
    "report.allocation_detail_unavailable",
    "report.budget_ambiguous",
    "allocation.exceeds_remaining",
    "fx.report_unavailable",
    "fx.amount_mismatch",
    "fx.rate_invalid",
    "money.out_of_range",
    "money.format",
    "money.must_be_positive",
    "money.currency_mismatch",
    "money.precision",
    "date.invalid",
    "date.out_of_range",
    "budget.period_mismatch",
    "budget.currency_mismatch",
    "budget.limit_required",
    "budget.overlapping_categories",
    "budget.total_below_categories",
]


class ReportTotals(ClosedModel):
    income_minor: ReportMinor
    expense_minor: ReportMinor
    net_minor: ReportMinor
    budget_eligible_minor: ReportMinor
    gross_expense_minor: ReportMinor
    allocated_expense_minor: ReportMinor
    refund_minor: ReportMinor | None
    reimbursement_minor: ReportMinor | None


class BudgetAmount(ClosedModel):
    limit_minor: ReportMinor
    spent_minor: ReportMinor
    remaining_minor: ReportMinor


class BudgetReport(BudgetAmount):
    includes_other_categories: bool
    other_limit_minor: ReportMinor | None
    other_spent_minor: ReportMinor | None
    categories: dict[str, BudgetAmount]


class ReportResponse(ClosedModel):
    version: Literal[1]
    book_id: Identifier
    report_currency: Annotated[str, StringConstraints(pattern=r"^[A-Z]{3}$")]
    report_scale: int = Field(ge=0, le=6)
    start_date: BusinessDate
    end_date_exclusive: BusinessDate
    available: bool
    issues: list[ReportIssue]
    allocation_breakdown_available: bool
    totals: ReportTotals | None = None
    category_income_minor: dict[str, ReportMinor] | None = None
    category_expense_minor: dict[str, ReportMinor] | None = None
    budget_category_expense_minor: dict[str, ReportMinor] | None = None
    category_income_rollup_minor: dict[str, ReportMinor] | None = None
    category_expense_rollup_minor: dict[str, ReportMinor] | None = None
    budget_category_rollup_minor: dict[str, ReportMinor] | None = None
    calendar: dict[BusinessDate, ReportTotals] | None = None
    budget: BudgetReport | None = None

    @model_validator(mode="after")
    def validate_availability(self):
        values = [
            self.totals,
            self.category_income_minor,
            self.category_expense_minor,
            self.budget_category_expense_minor,
            self.category_income_rollup_minor,
            self.category_expense_rollup_minor,
            self.budget_category_rollup_minor,
            self.calendar,
        ]
        if self.available and any(value is None for value in values):
            raise ValueError("available_report_requires_projections")
        if not self.available and any(value is not None for value in [*values, self.budget]):
            raise ValueError("unavailable_report_has_no_partial_projections")
        return self


class BookReportResponse(ClosedModel):
    sync_epoch: Identifier
    scope_revision: Revision
    permission_version: Revision
    report: ReportResponse
