"""Closed output projections. A private finance event is never a shared bill copy."""

from typing import Annotated, Literal

from pydantic import Field, model_validator
from pydantic.json_schema import SkipJsonSchema

from flowtrace_server.domain.money import checked_minor, parse_minor

from .schemas import (
    AccountPayload,
    Allocation,
    BillPayload,
    BookPayload,
    BudgetPayload,
    BusinessDate,
    CategoryPayload,
    ClosedModel,
    Flags,
    Identifier,
    Instant,
    Money,
    PositiveMoney,
    Reporting,
    Revision,
    SignedMinor,
    TagPayload,
    TimezoneName,
    TransferFx,
)


class PublicFee(ClosedModel):
    money: PositiveMoney
    account_id: Identifier | None
    category_id: Identifier | None
    flags: Flags
    reporting: Reporting | None


class PublicBillFields(ClosedModel):
    bill_type: str
    money: PositiveMoney
    book_id: Identifier
    account_id: Identifier | None
    from_account_id: Identifier | None
    to_account_id: Identifier | None
    target_money: PositiveMoney | None
    transfer_fx: TransferFx | None = None
    business_date: BusinessDate
    business_timezone: TimezoneName
    occurred_at: Instant | None
    category_id: Identifier | None
    tag_ids: list[Identifier]
    attachment_ids: list[Identifier]
    source: Literal["manual", "import", "recurring", "installment", "auto"]
    flags: Flags
    note: str
    reporting: Reporting | None
    allocations: list[Allocation]
    income_component_minor: Revision
    target_balance_minor: SignedMinor | None
    gross_amount_minor: Revision | None
    discount_minor: Revision | None
    fee: PublicFee | None
    reimbursement_tracking: bool = False

    @model_validator(mode="after")
    def tracking_expense_only(self):
        if "reimbursement_tracking" in self.model_fields_set and self.bill_type != "expense":
            raise ValueError("reimbursement_tracking_expense_only")
        return self


class SourceSummary(ClosedModel):
    refund_source_minor: Revision
    reimbursement_source_minor: Revision
    remaining_source_minor: Revision
    settlement_reason: Literal["open", "refunded", "reimbursed", "mixed"]

    @model_validator(mode="after")
    def amounts_and_reason(self):
        refunded = parse_minor(self.refund_source_minor)
        reimbursed = parse_minor(self.reimbursement_source_minor)
        remaining = parse_minor(self.remaining_source_minor)
        checked_minor(refunded + reimbursed + remaining)
        reason = (
            "open"
            if remaining > 0
            else "refunded"
            if reimbursed == 0
            else "reimbursed"
            if refunded == 0
            else "mixed"
        )
        if self.settlement_reason != reason:
            raise ValueError("source_summary_reason_mismatch")
        return self


class BillPublic(ClosedModel):
    projection_kind: Literal["bill_public"]
    payload: PublicBillFields
    hidden_account_fields: list[
        Literal["account_id", "from_account_id", "to_account_id", "fee.account_id"]
    ]
    hidden_allocation_count: int = Field(ge=0, le=100)
    paid_by_user_ids: list[Identifier]
    nonfinancial_editable_fields: list[
        Literal[
            "note", "category_id", "tag_ids", "attachment_ids", "flags", "reimbursement_tracking"
        ]
    ]
    remaining_allocatable_minor: Revision | None
    # None is the internal legacy-absence sentinel, never an accepted wire value.
    source_summary: SourceSummary | SkipJsonSchema[None] = None

    @model_validator(mode="after")
    def source_summary_expense_only(self):
        if "source_summary" not in self.model_fields_set:
            return self
        if self.payload.bill_type != "expense" or self.source_summary is None:
            raise ValueError("source_summary_expense_only")
        summary = self.source_summary
        if summary.remaining_source_minor != self.remaining_allocatable_minor:
            raise ValueError("source_summary_remaining_mismatch")
        if parse_minor(self.payload.money.amount_minor) != (
            parse_minor(summary.refund_source_minor)
            + parse_minor(summary.reimbursement_source_minor)
            + parse_minor(summary.remaining_source_minor)
        ):
            raise ValueError("source_summary_paid_mismatch")
        return self


class PrivateLinks(ClosedModel):
    account_id: Identifier | None
    from_account_id: Identifier | None
    to_account_id: Identifier | None
    fee_account_id: Identifier | None


class PrivatePosting(ClosedModel):
    account_id: Identifier
    component: Literal["principal", "fee"]
    money: Money


class BillPrivateFinance(ClosedModel):
    projection_kind: Literal["bill_private_finance"]
    book_id: Identifier
    bill_type: str
    business_date: BusinessDate
    business_timezone: TimezoneName
    occurred_at: Instant | None
    account_links: PrivateLinks
    entries: list[PrivatePosting]


class BookData(ClosedModel):
    projection_kind: Literal["book"]
    payload: BookPayload


class AccountData(ClosedModel):
    projection_kind: Literal["account"]
    payload: AccountPayload
    balance: Money


class CategoryData(ClosedModel):
    projection_kind: Literal["category"]
    payload: CategoryPayload


class TagData(ClosedModel):
    projection_kind: Literal["tag"]
    payload: TagPayload


class BudgetData(ClosedModel):
    projection_kind: Literal["budget"]
    payload: BudgetPayload


Projection = Annotated[
    BookData | AccountData | CategoryData | TagData | BudgetData | BillPublic | BillPrivateFinance,
    Field(discriminator="projection_kind"),
]


class ChangeEvent(ClosedModel):
    scope_id: Identifier
    scope_revision: Revision
    event_index: int = Field(ge=0, le=199)
    entity_type: Literal["book", "account", "category", "tag", "bill", "budget"]
    entity_id: Identifier
    revision: Revision
    deleted: bool
    data: Projection | None


class Commit(ClosedModel):
    commit_id: Identifier
    events: list[ChangeEvent] = Field(min_length=1, max_length=200)


class PullResponse(ClosedModel):
    sync_epoch: Identifier
    commits: list[Commit]
    next_page_token: str | None
    checkpoint: dict[Identifier, Revision] | None


class Applied(ClosedModel):
    operation_id: Identifier
    status: Literal["applied"]
    entity_id: Identifier
    revision: Revision
    commit_id: Identifier
    scope_revisions: dict[Identifier, Revision]
    replayed: bool = False


class RejectedError(ClosedModel):
    code: str
    http_status: int
    current: ChangeEvent | None = None


class Rejected(ClosedModel):
    operation_id: Identifier
    status: Literal["rejected"]
    error: RejectedError


class PushResponse(ClosedModel):
    results: list[Applied | Rejected]


class ScopeItem(ClosedModel):
    scope_id: Identifier
    kind: Literal["user", "book"]
    role: Literal["owner", "editor", "viewer"]
    revision: Revision
    permission_version: Revision


class ScopeResponse(ClosedModel):
    sync_epoch: Identifier
    control_version: Revision
    scopes: list[ScopeItem]
    revoked_scope_ids: list[Identifier]
    requires_rebuild: bool


class PageManifest(ClosedModel):
    page_index: int = Field(ge=0, le=999)
    item_count: int = Field(ge=0, le=200)
    sha256: str = Field(pattern="^[a-f0-9]{64}$")


class SnapshotManifest(ClosedModel):
    snapshot_id: Identifier
    instance_id: Identifier
    sync_epoch: Identifier
    checkpoint: dict[Identifier, Revision]
    permission_versions: dict[Identifier, Revision]
    pages: list[PageManifest]


class SnapshotStatus(ClosedModel):
    snapshot_id: Identifier
    status: Literal["pending", "ready", "failed", "expired"]
    expires_at: str
    sync_epoch: Identifier
    checkpoint: dict[Identifier, Revision] | None
    permission_versions: dict[Identifier, Revision]
    first_page_token: str | None
    manifest_sha256: str | None
    manifest: SnapshotManifest | None


class SnapshotPageResponse(ClosedModel):
    snapshot_id: Identifier
    items: list[ChangeEvent]
    next_page_token: str | None
    page_sha256: str
    page_index: int = Field(ge=0, le=999)


class EntityReadResponse(ClosedModel):
    event: ChangeEvent
    editable_payload: (
        BookPayload
        | AccountPayload
        | CategoryPayload
        | TagPayload
        | BillPayload
        | BudgetPayload
        | None
    )
