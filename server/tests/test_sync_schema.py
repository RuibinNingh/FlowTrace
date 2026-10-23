import json
from copy import deepcopy
from pathlib import Path

import pytest
from pydantic import ValidationError

from flowtrace_server.sync.schemas import (
    BillPayload,
    BookPayload,
    BudgetPayload,
    Money,
    Operation,
    PushRequest,
)

FIRST_ID = "00000000-0000-4000-8000-000000000010"
SECOND_ID = "00000000-0000-4000-8000-000000000011"


def request_body(operation):
    return {
        "protocol_version": 1,
        "client_id": "00000000-0000-4000-8000-000000000001",
        "sync_epoch": "00000000-0000-4000-8000-000000000002",
        "operations": [deepcopy(operation)],
    }


def money(amount="1230", currency="CNY", scale=2):
    return {"currency": currency, "currency_scale": scale, "amount_minor": amount}


def allocation(receipt="1230", source_id=FIRST_ID):
    return {
        "source_bill_id": source_id,
        "source_amount_minor": receipt,
        "receipt_amount_minor": receipt,
    }


def budget():
    return {
        "period_start": "2026-10-01",
        "period_end_exclusive": "2026-11-01",
        "total": money("300"),
        "categories": [{"category_id": FIRST_ID, "limit": money("200")}],
        "carry_forward": False,
    }


@pytest.fixture
def operation():
    path = Path(__file__).resolve().parents[2] / "contracts/fixtures/api/canonical-operation.json"
    return json.loads(path.read_text(encoding="utf-8"))["hash_input"]["operation"]


def test_operation_has_typed_payload_and_does_not_mutate_raw(operation):
    raw = deepcopy(operation)
    parsed = Operation.model_validate(raw)
    assert parsed.payload.money.amount_minor == "1230"
    assert raw == operation
    assert "flags" not in raw["payload"]  # Hashing precedes default interpretation.


@pytest.mark.parametrize(
    "field,value",
    [
        ("unexpected", "ignored?"),
        ("money", {"currency": "CNY", "currency_scale": 2, "amount_minor": 1230}),
        ("business_date", "2026-02-30"),
        ("business_timezone", "No/SuchZone"),
        ("occurred_at", "2026-10-20T12:00:00+08:00"),
    ],
)
def test_invalid_bill_fields_rejected(operation, field, value):
    operation["payload"][field] = value
    with pytest.raises(ValidationError):
        Operation.model_validate(operation)


def test_signed_account_money_and_positive_bill_money(operation):
    negative = {"currency": "CNY", "currency_scale": 2, "amount_minor": "-1"}
    assert Money.model_validate(negative).amount_minor == "-1"
    operation["payload"]["money"] = negative
    with pytest.raises(ValidationError):
        Operation.model_validate(operation)


def test_out_of_range_and_bool_scale_rejected():
    for value in [
        {"currency": "CNY", "currency_scale": True, "amount_minor": "1"},
        {"currency": "CNY", "currency_scale": 2, "amount_minor": "9223372036854775808"},
    ]:
        with pytest.raises(ValidationError):
            Money.model_validate(value)


def test_delete_and_dependency_shape(operation):
    operation["action"] = "delete"
    with pytest.raises(ValidationError):
        Operation.model_validate(operation)
    operation["payload"] = {}
    Operation.model_validate(operation)
    operation["depends_on"] = []
    with pytest.raises(ValidationError):
        Operation.model_validate(operation)


def test_entity_mismatch_and_duplicate_operations(operation):
    operation["entity_type"] = "tag"
    with pytest.raises(ValidationError):
        Operation.model_validate(operation)
    operation["entity_type"] = "bill"
    request = {
        "protocol_version": 1,
        "client_id": "00000000-0000-4000-8000-000000000001",
        "sync_epoch": "00000000-0000-4000-8000-000000000002",
        "operations": [operation, operation],
    }
    with pytest.raises(ValidationError):
        PushRequest.model_validate(request)


@pytest.mark.parametrize("value", [True, False, 1.0, "1", 0, 2])
def test_protocol_version_requires_exact_integer_one(operation, value):
    body = request_body(operation)
    body["protocol_version"] = value
    with pytest.raises(ValidationError):
        PushRequest.model_validate(body)


@pytest.mark.parametrize(
    "field,value",
    [
        ("base_revision", "9223372036854775808"),
        ("operation_id", "00000000-0000-4000-8000-00000000000A"),
        ("scope_id", FIRST_ID + "\n"),
        ("entity_id", "00000000000040008000000000000010"),
        ("depends_on", "00000000-0000-4000-8000-00000000000A"),
    ],
)
def test_revisions_and_identifiers_do_not_normalize(operation, field, value):
    operation[field] = value
    with pytest.raises(ValidationError):
        Operation.model_validate(operation)


@pytest.mark.parametrize(
    "occurred_at",
    [
        "20261021 120000+0800",
        "2026-10-21 12:00:00+08:00",
        "2026-10-21T12:00:00+07:60",
        "2026-10-21T12:00:00+24:00",
        "2026-10-21T12:00:00+08:00:30",
        "2026-10-21T12:00:00.1234567+08:00",
        "2026-10-21T12:00:00",
        "2026-10-21T24:00:00+08:00",
        "2026-10-21T12:00:60+08:00",
    ],
)
def test_timestamp_has_exact_offset_format_and_valid_components(operation, occurred_at):
    operation["payload"]["occurred_at"] = occurred_at
    with pytest.raises(ValidationError):
        Operation.model_validate(operation)


@pytest.mark.parametrize("instant", [None, "2026-10-21T04:00:00Z", "2026-10-21T12:00:00.1+08:00"])
def test_date_only_and_precise_timestamps(operation, instant):
    operation["payload"]["occurred_at"] = instant
    Operation.model_validate(operation)


@pytest.mark.parametrize("timezone", ["No/SuchZone", "../UTC", "/etc/localtime", ""])
def test_books_and_date_only_bills_use_pinned_iana_timezone(operation, timezone):
    book = {"name": "合成账本", "currency": "CNY", "timezone": timezone, "month_start_day": 31}
    with pytest.raises(ValidationError):
        BookPayload.model_validate(book)
    operation["payload"]["occurred_at"] = None
    operation["payload"]["business_timezone"] = timezone
    with pytest.raises(ValidationError):
        Operation.model_validate(operation)


@pytest.mark.parametrize(
    "kind",
    ["transfer", "credit_repayment", "loan_borrow", "loan_lend", "loan_collect", "loan_repay"],
)
def test_two_account_types_require_two_distinct_references(operation, kind):
    payload = operation["payload"]
    payload["bill_type"] = kind
    for references in [
        {},
        {"from_account_id": FIRST_ID},
        {"from_account_id": FIRST_ID, "to_account_id": FIRST_ID},
        {"from_account_id": FIRST_ID, "to_account_id": SECOND_ID, "account_id": FIRST_ID},
    ]:
        with pytest.raises(ValidationError):
            BillPayload.model_validate({**payload, **references})
    valid = {**payload, "from_account_id": FIRST_ID, "to_account_id": SECOND_ID}
    assert BillPayload.model_validate(valid).to_account_id == SECOND_ID


@pytest.mark.parametrize(
    "fields",
    [
        {"from_account_id": FIRST_ID},
        {"to_account_id": SECOND_ID},
        {"target_money": money()},
        {"target_balance_minor": "-100"},
        {"allocations": [allocation()]},
        {"income_component_minor": "1"},
        {"gross_amount_minor": "1230"},
        {"discount_minor": "0"},
    ],
)
def test_expense_rejects_fields_for_other_kinds(operation, fields):
    with pytest.raises(ValidationError):
        BillPayload.model_validate({**operation["payload"], **fields})


def test_discount_and_balance_adjustment_are_complete_commands(operation):
    payload = operation["payload"]
    BillPayload.model_validate({**payload, "gross_amount_minor": "1250", "discount_minor": "20"})
    with pytest.raises(ValidationError):
        BillPayload.model_validate(
            {**payload, "gross_amount_minor": "1250", "discount_minor": "21"}
        )
    with pytest.raises(ValidationError):
        BillPayload.model_validate(
            {**payload, "bill_type": "income", "gross_amount_minor": "1250", "discount_minor": "20"}
        )
    adjustment = {**payload, "bill_type": "balance_adjustment"}
    with pytest.raises(ValidationError):
        BillPayload.model_validate(adjustment)
    with pytest.raises(ValidationError):
        BillPayload.model_validate({**adjustment, "target_balance_minor": "-100"})
    BillPayload.model_validate(
        {**adjustment, "account_id": FIRST_ID, "target_balance_minor": "-100"}
    )


def test_receipt_total_and_income_component_conserve_actual_money(operation):
    payload = {**operation["payload"], "bill_type": "refund"}
    BillPayload.model_validate(
        {**payload, "allocations": [allocation("1200")], "income_component_minor": "30"}
    )
    BillPayload.model_validate({**payload, "income_component_minor": "1230"})
    for patch in [
        {"allocations": [allocation("1200")]},
        {"allocations": [allocation()], "income_component_minor": "1"},
        {"allocations": [allocation("600"), allocation("630")]},
        {"allocations": [allocation("9223372036854775807"), allocation("1", SECOND_ID)]},
        {
            "bill_type": "reimbursement",
            "allocations": [allocation("1200")],
            "income_component_minor": "30",
        },
    ]:
        with pytest.raises(ValidationError):
            BillPayload.model_validate({**payload, **patch})
    BillPayload.model_validate(
        {**payload, "bill_type": "reimbursement", "allocations": [allocation()]}
    )


@pytest.mark.parametrize("component", ["bill", "fee"])
def test_reporting_checks_exact_final_conversion_for_bill_and_fee(operation, component):
    value = money("101", "USD")
    reporting = {
        "rate": "0.5",
        "rate_date": "2026-10-21",
        "rate_source": "synthetic",
        "report_currency": "CNY",
        "report_scale": 2,
        "report_amount_minor": "51",
    }
    payload = {**operation["payload"], "money": value, "reporting": reporting}
    if component == "fee":
        payload = {
            **operation["payload"],
            "bill_type": "transfer",
            "from_account_id": FIRST_ID,
            "to_account_id": SECOND_ID,
            "fee": {
                "money": value,
                "account_id": FIRST_ID,
                "flags": {"exclude_from_statistics": False, "exclude_from_budget": False},
                "reporting": reporting,
            },
        }
    BillPayload.model_validate(payload)
    reporting["report_amount_minor"] = "50"
    with pytest.raises(ValidationError):
        BillPayload.model_validate(payload)


def test_same_currency_rate_cannot_forge_reporting_amount(operation):
    reporting = {
        "rate": "2",
        "rate_date": "2026-10-21",
        "rate_source": "synthetic",
        "report_currency": "CNY",
        "report_scale": 2,
        "report_amount_minor": "2460",
    }
    with pytest.raises(ValidationError):
        BillPayload.model_validate({**operation["payload"], "reporting": reporting})


@pytest.mark.parametrize(
    "patch",
    [
        {"period_start": "2026-02-30"},
        {"period_start": "2026-11-01"},
        {"period_end_exclusive": "2026-09-30"},
        {"total": money("-1")},
        {"total": money("100")},
        {"total": money("300", "USD")},
        {"total": money("300", scale=3)},
        {"total": None, "categories": []},
        {"categories": [{"category_id": FIRST_ID, "limit": money("-1")}]},
        {"categories": [{"category_id": FIRST_ID, "limit": money("100")}] * 2},
        {
            "total": None,
            "categories": [
                {"category_id": FIRST_ID, "limit": money("9223372036854775807")},
                {"category_id": SECOND_ID, "limit": money("1")},
            ],
        },
    ],
)
def test_budget_rejects_invalid_dates_negative_or_ambiguous_limits(patch):
    with pytest.raises(ValidationError):
        BudgetPayload.model_validate({**budget(), **patch})


def test_three_budget_modes_and_zero_limit():
    BudgetPayload.model_validate(budget())
    BudgetPayload.model_validate({**budget(), "total": None})
    BudgetPayload.model_validate({**budget(), "categories": []})
    BudgetPayload.model_validate({**budget(), "total": money("0"), "categories": []})


def test_self_references_rejected_before_database_queries(operation):
    operation["depends_on"] = operation["operation_id"]
    with pytest.raises(ValidationError):
        Operation.model_validate(operation)
    operation["depends_on"] = None
    operation["payload"].update(
        {"bill_type": "refund", "allocations": [allocation(source_id=operation["entity_id"])]}
    )
    with pytest.raises(ValidationError):
        Operation.model_validate(operation)
    operation["entity_type"] = "category"
    operation["payload"] = {
        "name": "合成分类",
        "kind": "expense",
        "parent_id": operation["entity_id"],
        "icon": "food",
        "sort_order": 0,
    }
    with pytest.raises(ValidationError):
        Operation.model_validate(operation)


def test_nested_payloads_remain_closed(operation):
    operation["payload"]["money"]["owner_user_id"] = FIRST_ID
    with pytest.raises(ValidationError):
        Operation.model_validate(operation)


def test_preserve_hidden_links_is_update_only_and_never_bypasses_exact_money(operation):
    operation["payload"]["preserve_hidden_financial_links"] = True
    with pytest.raises(ValidationError):
        Operation.model_validate(operation)
    operation["action"] = "update"
    operation["base_revision"] = "1"
    operation["payload"].update(
        {"bill_type": "transfer", "from_account_id": None, "to_account_id": SECOND_ID}
    )
    Operation.model_validate(operation)  # The transaction must restore and check the private link.
    operation["payload"]["money"]["amount_minor"] = "-1"
    with pytest.raises(ValidationError):
        Operation.model_validate(operation)


def test_snapshot_and_pull_control_fields_are_strict_and_closed():
    from flowtrace_server.sync.schemas import PullRequest, SnapshotRequest

    for value in [True, 1.0]:
        with pytest.raises(ValidationError):
            SnapshotRequest.model_validate(
                {
                    "protocol_version": value,
                    "client_id": FIRST_ID,
                    "sync_epoch": SECOND_ID,
                    "scope_ids": [FIRST_ID],
                }
            )
        with pytest.raises(ValidationError):
            PullRequest.model_validate(
                {"sync_epoch": FIRST_ID, "cursors": {}, "limit": value, "page_token": None}
            )
    for cursors in [
        {FIRST_ID: "9223372036854775808"},
        {FIRST_ID.upper() + "A": "0"},
        {FIRST_ID: 1},
    ]:
        with pytest.raises(ValidationError):
            PullRequest.model_validate(
                {"sync_epoch": FIRST_ID, "cursors": cursors, "limit": 100, "page_token": None}
            )
