import csv
import io
import json
from uuid import uuid4

import pytest
from pydantic import ValidationError

from flowtrace_server.imports.parsers import HEADERS, ImportFormatError, parse_csv, parse_json
from flowtrace_server.imports.qianji_template import TemplateMapping, parse_qianji_csv
from flowtrace_server.imports.schemas import ImportDocument


def row(**changes):
    return {
        "source_id": str(uuid4()),
        "entity_type": "bill",
        "scope_id": str(uuid4()),
        "payload": {
            "bill_type": "expense",
            "money": {"currency": "CNY", "currency_scale": 2, "amount_minor": "125"},
            "business_date": "2026-10-21",
            "business_timezone": "Asia/Shanghai",
        },
        **changes,
    }


def table(records, headers=HEADERS):
    output = io.StringIO(newline="")
    writer = csv.DictWriter(output, fieldnames=headers)
    writer.writeheader()
    writer.writerows(records)
    return output.getvalue().encode("utf-8-sig")


def test_raw_money_and_field_absence_survive_json():
    original = row()
    body = {"format": "flowtrace-data-v1", "source_namespace": "synthetic", "rows": [original]}
    parsed = parse_json(json.dumps(body).encode())
    assert parsed.rows[0].payload == original["payload"]
    assert "reimbursement_tracking" not in parsed.rows[0].payload


@pytest.mark.parametrize(
    "bad", [b'{"format":"x","format":"flowtrace-data-v1"}', b'{"x":NaN}', b"\xff", b"[]"]
)
def test_bad_json_rejected(bad):
    with pytest.raises((ImportFormatError, ValidationError)):
        parse_json(bad)


def test_csv_row_error_has_location_and_no_partial_document():
    first, second = row(), row()
    first["payload"] = json.dumps(first["payload"])
    second["payload"] = '{"bill_type":"expense","unexpected":"private_secret_value"}'
    parsed = parse_csv(table([first, second]), "synthetic")
    assert parsed.document is None
    assert any(e["row"] == 3 for e in parsed.errors)
    assert "private_secret_value" not in json.dumps(parsed.errors)


def test_two_equal_rows_keep_distinct_stable_ids():
    first = row()
    second = {**first, "source_id": str(uuid4())}
    for item in (first, second):
        item["payload"] = json.dumps(item["payload"])
    body = table([first, second])
    parsed = parse_csv(body, "synthetic").document
    assert parsed is not None and len(parsed.rows) == 2
    assert parsed.rows[0].source_id != parsed.rows[1].source_id
    assert parsed == parse_csv(body, "synthetic").document


def test_same_source_repeated_is_rejected():
    first = row()
    with pytest.raises(ValidationError, match="duplicate_source_id"):
        ImportDocument(
            format="flowtrace-data-v1", source_namespace="synthetic", rows=[first, first]
        )


@pytest.mark.parametrize("signed", ["0", "124", "-126", "9223372036854775808"])
def test_historical_posting_must_match_exact_adjustment_magnitude(signed):
    original = row()
    original["payload"].update(
        bill_type="balance_adjustment", account_id=str(uuid4()), target_balance_minor="10000"
    )
    with pytest.raises((ValidationError, ValueError)):
        ImportDocument(
            format="flowtrace-data-v1",
            source_namespace="synthetic",
            rows=[original],
            posting_hints={original["source_id"]: {"signed_principal_minor": signed}},
        )


def test_historical_posting_cannot_be_applied_to_ordinary_expense_or_unknown_source():
    original = row()
    for identifier in (original["source_id"], str(uuid4())):
        with pytest.raises(ValidationError, match="historical_posting_requires_adjustment"):
            ImportDocument(
                format="flowtrace-data-v1",
                source_namespace="synthetic",
                rows=[original],
                posting_hints={identifier: {"signed_principal_minor": "125"}},
            )


def test_json_export_envelope_retains_signed_historical_posting():
    original = row()
    original["payload"].update(
        bill_type="balance_adjustment", account_id=str(uuid4()), target_balance_minor="10000"
    )
    document = {
        "format": "flowtrace-data-v1",
        "source_namespace": "synthetic",
        "rows": [original],
        "posting_hints": {original["source_id"]: {"signed_principal_minor": "-125"}},
    }
    exported = {"format": "flowtrace-export-v1", "document": document, "attachments": []}
    parsed = parse_json(json.dumps(exported).encode())
    assert parsed.model_dump() == document


def test_public_qianji_template_precision_ids_and_mapping():
    account, category, scope = map(str, (uuid4(), uuid4(), uuid4()))
    mapping = TemplateMapping(
        scope_id=scope,
        timezone="Asia/Shanghai",
        account_names={"合成现金": account},
        category_names={"三餐": category},
    )
    record = {
        "时间": "2026/10/21 12:15",
        "类型": "支出",
        "金额": "10.25",
        "优惠券": "1.25",
        "账户1": "合成现金",
        "分类": "三餐",
    }
    content = table([record, record], tuple(record))
    parsed = parse_qianji_csv(content, mapping)
    assert not parsed.errors and len(parsed.document.rows) == 2
    first, second = parsed.document.rows
    assert first.source_id != second.source_id
    assert first.payload["money"]["amount_minor"] == "900"
    assert first.payload["gross_amount_minor"] == "1025"
    assert first.payload["account_id"] == account
    assert first.payload["occurred_at"] == "2026-10-21T12:15:00+08:00"
    assert parsed == parse_qianji_csv(content, mapping)


def test_public_qianji_transfer_included_fee_is_split_once():
    mapping = TemplateMapping(
        scope_id=str(uuid4()),
        timezone="Asia/Shanghai",
        account_names={"现金": str(uuid4()), "银行": str(uuid4())},
    )
    record = {
        "时间": "2026-10-21",
        "类型": "转账",
        "金额": "10.25",
        "手续费": "0.25",
        "账户1": "现金",
        "账户2": "银行",
    }
    parsed = parse_qianji_csv(table([record], tuple(record)), mapping)
    assert not parsed.errors
    payload = parsed.document.rows[0].payload
    assert payload["money"]["amount_minor"] == "1000"
    assert payload["fee"]["money"]["amount_minor"] == "25"
    assert "occurred_at" not in payload


def test_public_qianji_reimbursement_is_tracked_outgoing_expense_not_receipt():
    mapping = TemplateMapping(
        scope_id=str(uuid4()),
        timezone="Asia/Shanghai",
        account_names={"合成现金": str(uuid4())},
    )
    record = {
        "时间": "2026-10-21",
        "类型": "报销",
        "金额": "10.25",
        "优惠券": "1.25",
        "账户1": "合成现金",
    }
    parsed = parse_qianji_csv(table([record], tuple(record)), mapping)
    assert not parsed.errors
    payload = parsed.document.rows[0].payload
    assert payload["bill_type"] == "expense"
    assert payload["reimbursement_tracking"] is True
    assert payload["money"]["amount_minor"] == "900"
    assert payload["gross_amount_minor"] == "1025" and payload["discount_minor"] == "125"
    assert "allocations" not in payload


@pytest.mark.parametrize("kind", ["报销入账", "借入", "未知"])
def test_template_does_not_guess_unavailable_relationships(kind):
    mapping = TemplateMapping(scope_id=str(uuid4()), timezone="Asia/Shanghai")
    record = {"时间": "2026-10-21", "类型": kind, "金额": "1"}
    result = parse_qianji_csv(table([record], tuple(record)), mapping)
    assert result.document is None and result.errors[0]["row"] == 2


def test_template_does_not_fetch_unmapped_private_image_urls():
    mapping = TemplateMapping(scope_id=str(uuid4()), timezone="Asia/Shanghai")
    record = {
        "时间": "2026-10-21",
        "类型": "支出",
        "金额": "1",
        "账单图片": "http://127.0.0.1:55432/private",
    }
    result = parse_qianji_csv(table([record], tuple(record)), mapping)
    assert result.document is None
    assert result.errors == ({"row": 2, "field": "账单图片", "code": "mapping_required"},)


@pytest.mark.parametrize(
    "value",
    [
        "0.001",
        "NaN",
        "Infinity",
        "-1",
        "1e100",
        "1.000000000000000000000000000000000001",
        "92233720368547758.07000000000001",
        "1e100000000",
    ],
)
def test_template_never_rounds_or_overflows_money(value):
    mapping = TemplateMapping(scope_id=str(uuid4()), timezone="Asia/Shanghai")
    record = {"时间": "2026-10-21", "类型": "收入", "金额": value}
    assert parse_qianji_csv(table([record], tuple(record)), mapping).document is None
