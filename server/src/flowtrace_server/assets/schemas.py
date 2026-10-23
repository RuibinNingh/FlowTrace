from typing import Annotated, Literal

from pydantic import Field, StringConstraints, field_validator, model_validator

from flowtrace_server.currencies.catalog import supported
from flowtrace_server.domain.calendar_rules import business_date
from flowtrace_server.domain.money import parse_minor, parse_rate
from flowtrace_server.sync.schemas import (
    AccountPayload,
    BusinessDate,
    ClosedModel,
    Identifier,
    Money,
    Name,
    Rate,
    Revision,
    SignedMinor,
)

Policy = Literal["exact_date", "latest_on_or_before"]
Code = Annotated[str, StringConstraints(pattern=r"^[A-Z]{3}$")]


class ConfigCommand(ClosedModel):
    operation_id: Identifier
    client_id: Identifier
    instance_id: Identifier
    sync_epoch: Identifier
    base_revision: Revision

    @field_validator("base_revision")
    @classmethod
    def checked_revision(cls, value):
        parse_minor(value)
        return value


class GroupFields(ClosedModel):
    name: Name
    sort_order: int = Field(ge=0, le=2**31 - 1)

    @field_validator("name")
    @classmethod
    def text_no_nul(cls, value):
        if "\x00" in value or not value.strip():
            raise ValueError("invalid_name")
        return value


class NewGroup(GroupFields):
    id: Identifier


class GroupCreate(ConfigCommand):
    group: NewGroup


class GroupUpdate(ConfigCommand):
    group: GroupFields


class GroupItem(NewGroup):
    revision: Revision


class ConfigEnvelope(ClosedModel):
    instance_id: Identifier
    sync_epoch: Identifier
    revision: Revision


class GroupList(ConfigEnvelope):
    groups: list[GroupItem]


class GroupMutation(GroupList):
    operation_id: Identifier


class PreferenceFields(ClosedModel):
    base_currency: Code
    enabled_codes: list[Code] = Field(min_length=1, max_length=200)
    valuation_policy: Policy

    @model_validator(mode="after")
    def valid(self):
        supported(self.base_currency)
        for code in self.enabled_codes:
            supported(code)
        if len(set(self.enabled_codes)) != len(self.enabled_codes):
            raise ValueError("duplicate_currency")
        if self.base_currency not in self.enabled_codes:
            raise ValueError("base_currency_disabled")
        return self


class PreferenceCommand(ConfigCommand):
    preferences: PreferenceFields


class PreferenceResponse(ConfigEnvelope):
    preferences: PreferenceFields


class PreferenceMutation(PreferenceResponse):
    operation_id: Identifier


class RateFields(ClosedModel):
    id: Identifier
    from_currency: Code
    to_currency: Code
    effective_date: BusinessDate
    rate: Rate
    rate_source: Name

    @model_validator(mode="after")
    def valid(self):
        supported(self.from_currency)
        supported(self.to_currency)
        if self.from_currency == self.to_currency:
            raise ValueError("same_currency_rate")
        business_date(self.effective_date)
        parse_rate(self.rate)
        if "\x00" in self.rate_source or not self.rate_source.strip():
            raise ValueError("invalid_source")
        return self


class RateCommand(ConfigCommand):
    rate: RateFields


class RateItem(RateFields):
    revision: Revision


class RateList(ConfigEnvelope):
    rates: list[RateItem]


class RateMutation(RateList):
    operation_id: Identifier


class Bank(ClosedModel):
    id: str
    name: str


class BankList(ClosedModel):
    version: Literal[1]
    banks: list[Bank]


class Provider(Bank):
    kind: Literal["cash", "credit_card", "prepaid", "investment"]


class ProviderList(ClosedModel):
    version: Literal[1]
    providers: list[Provider]


class Currency(ClosedModel):
    code: Code
    name: str
    scale: int = Field(ge=0, le=6)


class CurrencyCatalog(ClosedModel):
    version: Literal[1]
    catalog_date: BusinessDate
    source: str
    currencies: list[Currency]


class ReadEnvelope(ClosedModel):
    instance_id: Identifier
    sync_epoch: Identifier
    scope_id: Identifier
    scope_revision: Revision
    config_revision: Revision


class AssetTotals(ClosedModel):
    assets_minor: SignedMinor
    liabilities_minor: SignedMinor
    net_minor: SignedMinor
    borrowed_minor: SignedMinor
    lent_minor: SignedMinor


class AccountValuation(ClosedModel):
    id: Identifier
    revision: Revision
    payload: AccountPayload
    balance: Money
    historical_balance: Money | None
    active_on_date: bool | None
    valuation_minor: SignedMinor | None
    rate: Rate | None
    rate_date: BusinessDate | None
    rate_source: Name | None
    issues: list[str]


class AssetOverview(ReadEnvelope):
    as_of: BusinessDate
    balance_mode: Literal["current", "as_of"]
    base_currency: Code
    base_scale: int
    valuation_policy: Policy
    available: bool
    issues: list[str]
    totals: AssetTotals | None
    totals_by_currency: dict[str, AssetTotals]
    accounts: list[AccountValuation]


class HistoryPoint(ClosedModel):
    date: BusinessDate
    available: bool
    issues: list[str]
    totals: AssetTotals | None


class AssetHistory(ReadEnvelope):
    base_currency: Code
    base_scale: int
    valuation_policy: Policy
    start_date: BusinessDate
    end_date_exclusive: BusinessDate
    points: list[HistoryPoint]


class EntryItem(ClosedModel):
    entry_id: Identifier
    business_date: BusinessDate
    component: Literal["principal", "fee"]
    money: Money
    detail_available: bool
    bill_id: Identifier | None
    book_id: Identifier | None
    bill_type: str | None
    note: str | None
    category_id: Identifier | None
    tag_ids: list[Identifier]
    attachment_ids: list[Identifier]


class AccountEntries(ReadEnvelope):
    account_id: Identifier
    currency: Code
    currency_scale: int
    start_date: BusinessDate
    end_date_exclusive: BusinessDate
    total_count: int
    offset: int
    limit: int
    entries: list[EntryItem]
    opening_balance: Money | None
    closing_balance: Money | None
    issues: list[str]


class CreditCycle(ClosedModel):
    start_date: BusinessDate
    end_date_exclusive: BusinessDate
    statement_date: BusinessDate
    due_date: BusinessDate
    charges_minor: SignedMinor
    statement_due_minor: SignedMinor | None
    remaining_due_minor: SignedMinor | None
    max_interest_free_days: int
    min_interest_free_days: int


class CreditCalendar(ReadEnvelope):
    account_id: Identifier
    currency: Code
    currency_scale: int
    total_debt_minor: SignedMinor
    overpayment_minor: SignedMinor
    available_credit_minor: SignedMinor | None
    over_limit_minor: SignedMinor | None
    opening_carry_minor: SignedMinor | None
    repayment_available: bool
    issues: list[str]
    cycles: list[CreditCycle]
