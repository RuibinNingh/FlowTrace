"""Closed commands and local invariants; current resource authorization is separate.

These models cannot prove referenced resources' existence, ownership, revision,
currency catalog or remaining allocation. The write transaction checks those
facts under its authorization and scope/account locks.
"""

from typing import Annotated, Literal

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    StringConstraints,
    field_validator,
    model_validator,
)

from flowtrace_server.domain.calendar_rules import business_date
from flowtrace_server.domain.money import Money as DomainMoney
from flowtrace_server.domain.money import checked_minor, convert_money, parse_minor, parse_rate
from flowtrace_server.domain.timezone_rules import instant_business_date

Identifier = Annotated[
    str,
    StringConstraints(
        pattern=r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
        min_length=36,
        max_length=36,
    ),
]
Revision = Annotated[str, StringConstraints(pattern=r"^(0|[1-9][0-9]*)$", max_length=19)]
SignedMinor = Annotated[str, StringConstraints(pattern=r"^(0|-?[1-9][0-9]*)$", max_length=20)]
Name = Annotated[str, StringConstraints(min_length=1, max_length=80)]
BusinessDate = Annotated[
    str, StringConstraints(pattern=r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$", max_length=10)
]
TimezoneName = Annotated[str, StringConstraints(min_length=1, max_length=128)]
Rate = Annotated[str, StringConstraints(min_length=1, max_length=39)]
Instant = Annotated[
    str,
    StringConstraints(
        pattern=(
            r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
            r"(?:\.[0-9]{1,6})?(?:Z|[+-][0-9]{2}:[0-9]{2})$"
        ),
        max_length=32,
    ),
]
_TWO_ACCOUNTS = {
    "transfer",
    "credit_repayment",
    "loan_borrow",
    "loan_lend",
    "loan_collect",
    "loan_repay",
}
_RECEIPTS = {"refund", "reimbursement"}


def _validate_timezone(name: str) -> None:
    # Use the pinned domain tzdata even for date-only records and books.
    instant_business_date("2000-01-01T12:00:00Z", name)


class ClosedModel(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, hide_input_in_errors=True)


class Money(ClosedModel):
    currency: Annotated[str, StringConstraints(pattern=r"^[A-Z]{3}$")]
    currency_scale: int = Field(ge=0, le=6)
    amount_minor: SignedMinor

    @model_validator(mode="after")
    def validate_money(self):
        DomainMoney.from_json(self.model_dump())
        return self


class PositiveMoney(Money):
    @model_validator(mode="after")
    def validate_positive(self):
        parse_minor(self.amount_minor, positive=True)
        return self


class NonNegativeMoney(Money):
    @model_validator(mode="after")
    def validate_non_negative(self):
        if parse_minor(self.amount_minor) < 0:
            raise ValueError("negative_budget_limit")
        return self


class Flags(ClosedModel):
    exclude_from_statistics: bool
    exclude_from_budget: bool


class Reporting(ClosedModel):
    rate: Rate
    rate_date: BusinessDate
    rate_source: Name
    report_currency: Annotated[str, StringConstraints(pattern=r"^[A-Z]{3}$")]
    report_scale: int = Field(ge=0, le=6)
    report_amount_minor: Revision

    @model_validator(mode="after")
    def validate_reporting(self):
        parse_rate(self.rate)
        business_date(self.rate_date)
        parse_minor(self.report_amount_minor)
        return self

    def validate_source(self, money: Money) -> None:
        source = DomainMoney.from_json(money.model_dump())
        if source.currency == self.report_currency and parse_rate(self.rate) != 1:
            raise ValueError("same_currency_rate_must_be_one")
        converted = convert_money(source, self.rate, self.report_currency, self.report_scale)
        if converted.minor != parse_minor(self.report_amount_minor):
            raise ValueError("reporting_amount_mismatch")


class Allocation(ClosedModel):
    source_bill_id: Identifier
    source_amount_minor: Revision
    receipt_amount_minor: Revision
    rate: Rate | None = None

    @model_validator(mode="after")
    def validate_allocation(self):
        parse_minor(self.source_amount_minor, positive=True)
        parse_minor(self.receipt_amount_minor, positive=True)
        if self.rate is not None:
            parse_rate(self.rate)
        return self


class Fee(ClosedModel):
    money: PositiveMoney
    account_id: Identifier | None = None
    category_id: Identifier | None = None
    flags: Flags
    reporting: Reporting | None = None

    @model_validator(mode="after")
    def validate_reporting(self):
        if self.reporting is not None:
            self.reporting.validate_source(self.money)
        return self


class TransferFx(ClosedModel):
    rate: Rate
    rate_date: BusinessDate
    rate_source: Name

    @model_validator(mode="after")
    def valid(self):
        parse_rate(self.rate)
        business_date(self.rate_date)
        if "\x00" in self.rate_source or not self.rate_source.strip():
            raise ValueError("invalid_rate_source")
        return self


class BillPayload(ClosedModel):
    bill_type: Literal[
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
    ]
    money: PositiveMoney
    book_id: Identifier | None = None
    account_id: Identifier | None = None
    from_account_id: Identifier | None = None
    to_account_id: Identifier | None = None
    target_money: PositiveMoney | None = None
    transfer_fx: TransferFx | None = None
    business_date: BusinessDate
    business_timezone: TimezoneName
    occurred_at: Instant | None = None
    category_id: Identifier | None = None
    tag_ids: list[Identifier] = Field(default_factory=list, max_length=100)
    attachment_ids: list[Identifier] = Field(default_factory=list, max_length=20)
    source: Literal["manual", "import", "recurring", "installment", "auto"] = "manual"
    flags: Flags = Field(
        default_factory=lambda: Flags(exclude_from_statistics=False, exclude_from_budget=False)
    )
    note: str = Field(default="", max_length=2000)
    reporting: Reporting | None = None
    allocations: list[Allocation] = Field(default_factory=list, max_length=100)
    income_component_minor: Revision = "0"
    target_balance_minor: SignedMinor | None = None
    gross_amount_minor: Revision | None = None
    discount_minor: Revision | None = None
    fee: Fee | None = None
    reimbursement_tracking: bool = False
    preserve_hidden_financial_links: bool = False

    @model_validator(mode="after")
    def validate_business_fields(self):
        if "reimbursement_tracking" in self.model_fields_set and self.bill_type != "expense":
            raise ValueError("reimbursement_tracking_expense_only")
        business_date(self.business_date)
        _validate_timezone(self.business_timezone)
        if self.occurred_at is not None:
            if (
                instant_business_date(self.occurred_at, self.business_timezone)
                != self.business_date
            ):
                raise ValueError("business_date_mismatch") from None
        if len(set(self.tag_ids)) != len(self.tag_ids):
            raise ValueError("duplicate_tag")
        if len(set(self.attachment_ids)) != len(self.attachment_ids):
            raise ValueError("duplicate_attachment")
        for amount in [
            self.income_component_minor,
            self.target_balance_minor,
            self.gross_amount_minor,
            self.discount_minor,
        ]:
            if amount is not None:
                parse_minor(amount)
        self._validate_kind_fields()
        if self.reporting is not None:
            self.reporting.validate_source(self.money)
        if self.transfer_fx is not None:
            if (
                self.bill_type not in _TWO_ACCOUNTS
                or self.target_money is None
                or self.money.currency == self.target_money.currency
            ):
                raise ValueError("transfer_fx_not_allowed")
            converted = convert_money(
                DomainMoney.from_json(self.money.model_dump()),
                self.transfer_fx.rate,
                self.target_money.currency,
                self.target_money.currency_scale,
            )
            if converted.minor != parse_minor(self.target_money.amount_minor):
                raise ValueError("transfer_fx_amount_mismatch")
        return self

    def _validate_kind_fields(self) -> None:
        if self.bill_type in _TWO_ACCOUNTS:
            if self.account_id is not None:
                raise ValueError("single_account_not_allowed")
            if (
                self.from_account_id is None or self.to_account_id is None
            ) and not self.preserve_hidden_financial_links:
                raise ValueError("two_accounts_required")
            if self.from_account_id is not None and self.from_account_id == self.to_account_id:
                raise ValueError("transfer_same_account")
            if self.fee is not None and self.fee.account_id is None:
                if not self.preserve_hidden_financial_links:
                    raise ValueError("fee_account_required")
        elif any(
            value is not None
            for value in (self.from_account_id, self.to_account_id, self.target_money, self.fee)
        ):
            raise ValueError("transfer_fields_not_allowed")

        if self.bill_type == "balance_adjustment":
            if self.account_id is None or self.target_balance_minor is None:
                raise ValueError("adjustment_target_required")
        elif self.target_balance_minor is not None:
            raise ValueError("adjustment_target_not_allowed")

        if self.bill_type in _RECEIPTS:
            sources = [allocation.source_bill_id for allocation in self.allocations]
            if len(sources) != len(set(sources)):
                raise ValueError("duplicate_allocation_source")
            income = parse_minor(self.income_component_minor)
            if self.bill_type == "reimbursement" and income != 0:
                raise ValueError("reimbursement_income_not_allowed")
            receipt_total = checked_minor(
                income + sum(parse_minor(item.receipt_amount_minor) for item in self.allocations)
            )
            if (
                receipt_total != parse_minor(self.money.amount_minor)
                and not self.preserve_hidden_financial_links
            ):
                raise ValueError("allocation_amount_mismatch")
        elif self.allocations or self.income_component_minor != "0":
            raise ValueError("receipt_fields_not_allowed")

        gross, discount = self.gross_amount_minor, self.discount_minor
        if gross is not None or discount is not None:
            if self.bill_type != "expense" or gross is None or discount is None:
                raise ValueError("discount_fields_not_allowed")
            if parse_minor(gross) - parse_minor(discount) != parse_minor(self.money.amount_minor):
                raise ValueError("discount_amount_mismatch")


class BookPayload(ClosedModel):
    name: Name
    currency: Annotated[str, StringConstraints(pattern=r"^[A-Z]{3}$")]
    timezone: TimezoneName
    month_start_day: int = Field(ge=1, le=31)
    template: Annotated[str, StringConstraints(pattern=r"^[a-z][a-z0-9_-]{0,63}$")] = "blank"
    icon: str = Field(default="book", max_length=64)
    cover_color: Annotated[str, StringConstraints(pattern=r"^#[0-9A-Fa-f]{6}$")] = "#2279D7"
    show_assets: bool = False
    display_mode: Literal["month", "year", "all"] = "month"

    @model_validator(mode="after")
    def validate_timezone(self):
        _validate_timezone(self.timezone)
        return self


CatalogId = Annotated[str, StringConstraints(pattern=r"^[a-z][a-z0-9_-]{0,63}$")]


class AccountCredit(ClosedModel):
    limit: NonNegativeMoney | None = None
    statement_day: int | None = Field(default=None, ge=1, le=31)
    statement_day_inclusive: bool = True
    due_mode: Literal["fixed_day", "days_after"] | None = None
    due_day: int | None = Field(default=None, ge=1, le=31)
    due_days: int | None = Field(default=None, ge=1, le=120)

    @model_validator(mode="after")
    def valid(self):
        if self.due_mode == "fixed_day":
            valid = self.due_day is not None and self.due_days is None
        elif self.due_mode == "days_after":
            valid = self.due_days is not None and self.due_day is None
        else:
            valid = self.due_day is None and self.due_days is None
        if not valid:
            raise ValueError("credit_invalid_due_rule")
        return self


def bill_storage_payload(model: BillPayload, *, previous: dict | None = None) -> dict:
    """Interpret old defaults but preserve the new optional field's wire presence.

    The model's false default serves display/validation only. It must not be
    written into legacy payloads, immutable events or frozen request hashes.
    Omission inherits tracking only when both old and new types are expense.
    """
    payload = model.model_dump(
        exclude={"preserve_hidden_financial_links", "reimbursement_tracking"}
    )
    if model.bill_type == "expense":
        if "reimbursement_tracking" in model.model_fields_set:
            payload["reimbursement_tracking"] = model.reimbursement_tracking
        elif previous is not None and previous.get("bill_type") == "expense":
            if "reimbursement_tracking" in previous:
                payload["reimbursement_tracking"] = previous["reimbursement_tracking"]
    return payload


class AccountPayload(ClosedModel):
    name: Name
    kind: Literal[
        "cash", "bank", "credit_card", "loan_receivable", "loan_payable", "prepaid", "investment"
    ]
    opening: Money
    include_in_net_assets: bool
    hidden: bool
    group_id: Identifier | None = None
    sort_order: int = Field(default=0, ge=0, le=2**31 - 1)
    archived: bool = False
    icon: str = Field(default="account", max_length=64)
    note: str = Field(default="", max_length=2000)
    provider_id: CatalogId | None = None
    bank_id: CatalogId | None = None
    card_last_four: Annotated[str, StringConstraints(pattern=r"^[0-9]{4}$")] | None = None
    opening_date: BusinessDate | None = None
    credit: AccountCredit | None = None

    @model_validator(mode="after")
    def valid(self):
        for value in (self.name, self.icon, self.note):
            if "\x00" in value:
                raise ValueError("account_invalid_text")
        if not self.name.strip():
            raise ValueError("account_invalid_name")
        if self.opening_date is not None:
            business_date(self.opening_date)
        if self.credit is not None:
            if self.kind != "credit_card":
                raise ValueError("credit_card_required")
            if self.credit.limit is not None and (
                self.credit.limit.currency,
                self.credit.limit.currency_scale,
            ) != (self.opening.currency, self.opening.currency_scale):
                raise ValueError("credit_currency_mismatch")
        return self


class CategoryPayload(ClosedModel):
    name: Name
    kind: Literal["income", "expense"]
    parent_id: Identifier | None
    icon: str = Field(max_length=64)
    sort_order: int = Field(ge=0, le=2**31 - 1)
    archived: bool = False


class TagPayload(ClosedModel):
    name: Name
    color: Annotated[str, StringConstraints(pattern=r"^#[0-9A-Fa-f]{6}$")]
    kind: Literal["tag", "group"] = "tag"
    group_id: Identifier | None = None
    archived: bool = False
    sort_order: int = Field(default=0, ge=0, le=2**31 - 1)

    @model_validator(mode="after")
    def validate_group(self):
        if self.kind == "group" and self.group_id is not None:
            raise ValueError("tag.group_must_be_root")
        return self


class CategoryBudget(ClosedModel):
    category_id: Identifier
    limit: NonNegativeMoney


class BudgetPayload(ClosedModel):
    period_start: BusinessDate
    period_end_exclusive: BusinessDate
    total: NonNegativeMoney | None
    categories: list[CategoryBudget] = Field(max_length=100)
    carry_forward: bool

    @model_validator(mode="after")
    def validate_budget(self):
        start = business_date(self.period_start)
        end = business_date(self.period_end_exclusive)
        if start >= end:
            raise ValueError("invalid_budget_period")
        if self.total is None and not self.categories:
            raise ValueError("budget_limit_required")
        identifiers = [item.category_id for item in self.categories]
        if len(identifiers) != len(set(identifiers)):
            raise ValueError("duplicate_budget_category")
        limits = [item.limit for item in self.categories]
        if self.total is not None:
            limits.append(self.total)
        if len({(value.currency, value.currency_scale) for value in limits}) != 1:
            raise ValueError("budget_currency_mismatch")
        category_total = checked_minor(
            sum(parse_minor(item.limit.amount_minor) for item in self.categories)
        )
        if self.total is not None and parse_minor(self.total.amount_minor) < category_total:
            raise ValueError("budget_total_below_categories")
        return self


class EmptyPayload(ClosedModel):
    pass


class AttachmentReplacement(ClosedModel):
    source_id: Identifier
    target_id: Identifier

    @model_validator(mode="after")
    def distinct_objects(self):
        if self.source_id == self.target_id:
            raise ValueError("move_attachment_requires_new_id")
        return self


class BillMove(ClosedModel):
    target_scope_id: Identifier
    attachment_replacements: list[AttachmentReplacement] = Field(max_length=20)

    @model_validator(mode="after")
    def unique_replacements(self):
        sources = [item.source_id for item in self.attachment_replacements]
        targets = [item.target_id for item in self.attachment_replacements]
        if len(set(sources)) != len(sources) or len(set(targets)) != len(targets):
            raise ValueError("duplicate_move_attachment")
        if set(sources) & set(targets):
            raise ValueError("move_attachment_requires_new_id")
        return self


class Operation(ClosedModel):
    operation_id: Identifier
    scope_id: Identifier
    entity_type: Literal["book", "account", "category", "tag", "bill", "budget"]
    entity_id: Identifier
    action: Literal["create", "update", "delete"]
    base_revision: Revision
    depends_on: Identifier | None
    move: BillMove | None = None
    payload: (
        BookPayload
        | AccountPayload
        | CategoryPayload
        | TagPayload
        | BillPayload
        | BudgetPayload
        | EmptyPayload
    )

    @model_validator(mode="after")
    def validate_payload(self):
        parse_minor(self.base_revision)
        if self.action == "create" and self.base_revision != "0":
            raise ValueError("create_revision_must_be_zero")
        if self.depends_on == self.operation_id:
            raise ValueError("self_dependency_not_allowed")
        if self.action == "delete":
            if not isinstance(self.payload, EmptyPayload):
                raise ValueError("delete_payload_must_be_empty")
        else:
            if not isinstance(self.payload, PAYLOAD_TYPES[self.entity_type]):
                raise ValueError("entity_payload_mismatch")
        if isinstance(self.payload, CategoryPayload) and self.payload.parent_id == self.entity_id:
            raise ValueError("self_parent_not_allowed")
        if isinstance(self.payload, TagPayload) and self.payload.group_id == self.entity_id:
            raise ValueError("self_group_not_allowed")
        if isinstance(self.payload, BillPayload):
            if self.payload.preserve_hidden_financial_links and self.action != "update":
                raise ValueError("preserve_links_update_only")
            if any(item.source_bill_id == self.entity_id for item in self.payload.allocations):
                raise ValueError("self_allocation_not_allowed")
        if self.move is not None:
            if self.entity_type != "bill" or self.action != "update" or self.base_revision == "0":
                raise ValueError("move_bill_update_only")
            if (
                not isinstance(self.payload, BillPayload)
                or self.payload.preserve_hidden_financial_links
            ):
                raise ValueError("move_requires_full_finance")
            if (
                self.move.target_scope_id == self.scope_id
                or self.payload.book_id != self.move.target_scope_id
            ):
                raise ValueError("move_target_mismatch")
            if self.payload.attachment_ids != [
                item.target_id for item in self.move.attachment_replacements
            ]:
                raise ValueError("move_attachment_mapping")
        return self


PAYLOAD_TYPES = {
    "book": BookPayload,
    "account": AccountPayload,
    "category": CategoryPayload,
    "tag": TagPayload,
    "bill": BillPayload,
    "budget": BudgetPayload,
}

BOOK_CORE_FIELDS = ("name", "currency", "timezone", "month_start_day")
MANAGEMENT_NEW_FIELDS = {
    "account": frozenset(
        {
            "group_id",
            "sort_order",
            "archived",
            "icon",
            "note",
            "provider_id",
            "bank_id",
            "card_last_four",
            "opening_date",
            "credit",
        }
    ),
    "book": frozenset({"template", "icon", "cover_color", "show_assets", "display_mode"}),
    "category": frozenset({"archived"}),
    "tag": frozenset({"kind", "group_id", "archived", "sort_order"}),
}


def management_payload(entity_type: str, payload: dict) -> dict:
    """Interpret legacy current JSON without rewriting immutable change/page data."""
    return PAYLOAD_TYPES[entity_type].model_validate(payload).model_dump()


class PushRequest(ClosedModel):
    protocol_version: Literal[1]
    client_id: Identifier
    sync_epoch: Identifier
    operations: list[Operation] = Field(min_length=1, max_length=100)

    @field_validator("protocol_version", mode="before")
    @classmethod
    def strict_protocol_integer(cls, value):
        # Literal equality alone accepts True and 1.0 even in strict models.
        if type(value) is not int:
            raise ValueError("invalid_protocol_version")
        return value

    @model_validator(mode="after")
    def unique_operations(self):
        identifiers = [operation.operation_id for operation in self.operations]
        if len(identifiers) != len(set(identifiers)):
            raise ValueError("duplicate_operation_id")
        return self


class ReceiptLookupRequest(PushRequest):
    """One exact frozen push intent; lookup never executes its operation."""

    operations: list[Operation] = Field(min_length=1, max_length=1)


class PullRequest(ClosedModel):
    sync_epoch: Identifier
    cursors: dict[Identifier, Revision]
    limit: int = Field(ge=1, le=200)
    page_token: Annotated[str, StringConstraints(min_length=20, max_length=128)] | None

    @model_validator(mode="after")
    def validate_cursors(self):
        for value in self.cursors.values():
            parse_minor(value)
        if len(self.cursors) > 1000:
            raise ValueError("too_many_scopes")
        return self


class SnapshotRequest(ClosedModel):
    protocol_version: Literal[1]
    client_id: Identifier
    sync_epoch: Identifier
    scope_ids: list[Identifier] = Field(min_length=1, max_length=1000)

    @field_validator("protocol_version", mode="before")
    @classmethod
    def strict_protocol_integer(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_protocol_version")
        return value

    @model_validator(mode="after")
    def validate_scopes(self):
        if len(self.scope_ids) != len(set(self.scope_ids)):
            raise ValueError("duplicate_scope")
        return self


class SnapshotPageRequest(ClosedModel):
    client_id: Identifier
    page_token: Annotated[str, StringConstraints(min_length=20, max_length=128)]
