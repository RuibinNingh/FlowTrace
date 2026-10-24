"""Synthetic actual-export fixtures, with no private ledger material."""

import csv
import io
import re
import zipfile
from datetime import datetime
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest
from openpyxl import Workbook

from flowtrace_server.imports.parsers import ImportFormatError
from flowtrace_server.imports.qianji_export import EXPORT_NAMESPACE, source_identifier
from flowtrace_server.imports.qianji_template import (
    TemplateMapping,
    inspect_mapping_requirements,
    parse_qianji_csv,
    parse_qianji_xlsx,
)
from flowtrace_server.imports.schemas import ImportRequest
from flowtrace_server.imports.service import operations_for
from flowtrace_server.imports.staging_parsers import open_stage_source
from flowtrace_server.imports.staging_schemas import StageMapping

HEADERS = (
    "ID",
    "时间",
    "账本",
    "分类",
    "二级分类",
    "类型",
    "金额",
    "币种",
    "账户1",
    "账户2",
    "备注",
    "已报销",
    "手续费",
    "优惠券",
    "记账者",
    "账单标记",
    "标签",
    "账单图片",
    "关联账单",
)


def record(identifier, **changes):
    return dict.fromkeys(HEADERS, "") | {
        "ID": identifier,
        "时间": "2026-10-24 12:34:56",
        "账本": "合成来源账本",
        "类型": "支出",
        "金额": "10.00",
        "币种": "CNY",
        **changes,
    }


def content(rows, format_name="qianji_xlsx", *, false_dimension=False):
    output = io.BytesIO()
    if format_name.endswith("csv"):
        text = io.StringIO(newline="")
        writer = csv.DictWriter(text, fieldnames=HEADERS)
        writer.writeheader()
        writer.writerows(rows)
        return text.getvalue().encode("utf-8-sig")
    book = Workbook()
    book.active.append(HEADERS)
    for row in rows:
        book.active.append([row.get(key) for key in HEADERS])
    book.save(output)
    if not false_dimension:
        return output.getvalue()
    fixed = io.BytesIO()
    with zipfile.ZipFile(output) as source, zipfile.ZipFile(fixed, "w") as target:
        for name in source.namelist():
            data = source.read(name)
            if name == "xl/worksheets/sheet1.xml":
                data = re.sub(rb'<dimension ref="[^"]+"', b'<dimension ref="A1"', data)
            target.writestr(name, data)
    return fixed.getvalue()


def mapping():
    return TemplateMapping(scope_id=str(uuid4()), timezone="Asia/Shanghai")


def staged(rows, format_name="qianji_xlsx", **options):
    with open_stage_source(
        content(rows, format_name, **options),
        format_name,
        StageMapping(template_mapping=mapping().model_dump()),
        check_budget=lambda: None,
    ) as source:
        assert source.source_namespace == EXPORT_NAMESPACE
        return list(source.rows)


@pytest.mark.parametrize("format_name", ["qianji_csv", "qianji_xlsx"])
def test_actual_export_105_rows_keeps_three_forward_refunds_and_seconds(format_name):
    rows = [
        record("refund-1", 类型="退款", 金额="1.25", 关联账单="expense-0"),
        record("refund-2", 类型="退款", 金额="2.50", 关联账单="expense-0"),
        record("refund-3", 类型="退款", 金额="1.00", 关联账单="expense-1"),
        *[record(f"expense-{i}") for i in range(100)],
        record("income-1", 类型="收入"),
        record("income-2", 类型="收入"),
    ]
    parsed = staged(rows, format_name, false_dimension=True)
    assert len(parsed) == 105 and all(not item.errors for item in parsed)
    assert [item.source_line for item in parsed] == list(range(2, 107))
    assert all(item.defined_source_id == item.row.source_id for item in parsed)
    first = parsed[0].row
    assert first.payload["bill_type"] == "refund" and first.payload["account_id"] is None
    assert first.payload["occurred_at"] == "2026-10-24T12:34:56+08:00"
    assert first.payload["allocations"] == [
        {
            "source_bill_id": source_identifier("expense-0"),
            "source_amount_minor": "125",
            "receipt_amount_minor": "125",
        }
    ]
    assert first.payload["income_component_minor"] == "0"
    assert parsed[0].requirements[0].source_key == source_identifier("expense-0")


def test_same_export_id_is_stable_across_file_order_and_notes():
    original = [record("original"), record("next")]
    reordered = [record("next"), record("original", 备注="合成新备注")]
    a, b = staged(original), staged(reordered)
    assert a[0].row.source_id == b[1].row.source_id
    assert a[1].row.source_id == b[0].row.source_id
    assert a[0].raw_hash != b[1].raw_hash


@pytest.mark.parametrize("format_name", ["qianji_csv", "qianji_xlsx"])
def test_public_actual_export_under_limit_rewrites_source_and_orders_expense_first(format_name):
    rows = [record("refund", 类型="退款", 金额="1.25", 关联账单="original"), record("original")]
    parser = parse_qianji_csv if format_name.endswith("csv") else parse_qianji_xlsx
    parsed = parser(content(rows, format_name, false_dimension=True), mapping())
    assert not parsed.errors and parsed.document.source_namespace == EXPORT_NAMESPACE
    principal = SimpleNamespace(user_id=uuid4())
    request = ImportRequest(
        batch_id=str(uuid4()),
        client_id=str(uuid4()),
        sync_epoch=str(uuid4()),
        document=parsed.document,
    )
    commands = operations_for(principal, request)
    assert [x.payload.bill_type for x in commands] == ["expense", "refund"]
    assert commands[1].payload.allocations[0].source_bill_id == commands[0].entity_id
    assert UUID(parsed.document.rows[0].source_id)


@pytest.mark.parametrize("format_name", ["qianji_csv", "qianji_xlsx"])
def test_actual_export_does_not_expand_public_50_row_contract(format_name):
    data = content([record(f"source-{i}") for i in range(105)], format_name, false_dimension=True)
    parser = parse_qianji_csv if format_name.endswith("csv") else parse_qianji_xlsx
    with pytest.raises(ImportFormatError, match="too_many_rows"):
        parser(data, mapping())
    with pytest.raises(ImportFormatError, match="too_many_rows"):
        inspect_mapping_requirements(data, format_name)


@pytest.mark.parametrize(
    "rows,code",
    [
        ([record("a"), record("a")], "qianji_duplicate_id"),
        ([record("r", 类型="退款", 关联账单="missing")], "qianji_reference_missing"),
        ([record("r", 类型="退款")], "qianji_reference_missing"),
        ([record("a", 关联账单="other")], "qianji_reference_invalid"),
        (
            [record("a", 类型="收入"), record("r", 类型="退款", 关联账单="a")],
            "qianji_source_type_invalid",
        ),
        (
            [record("a"), record("r", 类型="退款", 关联账单="a", 账本="另一来源")],
            "qianji_source_book_mismatch",
        ),
        (
            [record("a", 币种="USD"), record("r", 类型="退款", 关联账单="a")],
            "qianji_source_currency_mismatch",
        ),
        (
            [record("a"), record("r", 类型="退款", 关联账单="a", 金额="10.01")],
            "qianji_refund_exceeds_source",
        ),
        (
            [
                record("a"),
                record("r1", 类型="退款", 关联账单="a", 金额="6.00"),
                record("r2", 类型="退款", 关联账单="a", 金额="5.00"),
            ],
            "qianji_refund_exceeds_source",
        ),
        (
            [record("r1", 类型="退款", 关联账单="r2"), record("r2", 类型="退款", 关联账单="r1")],
            "qianji_reference_cycle",
        ),
        ([record("a", 金额="1.255")], "invalid_exact_amount"),
        ([record("a", 币种="XXX")], "qianji_currency_unsupported"),
        ([record("a", 已报销="是")], "qianji_reimbursement_details_required"),
        ([record("not valid id")], "qianji_id_invalid"),
        ([record(1234567890123456789)], "qianji_id_invalid"),
    ],
)
def test_export_relation_and_exactness_fail_closed_with_safe_errors(rows, code):
    parsed = staged(rows)
    errors = [error for item in parsed for error in item.errors]
    assert code in {error["code"] for error in errors}
    assert all(set(error) == {"row", "field", "code"} for error in errors)
    assert all(type(error["row"]) is int for error in errors)
    assert not any(str(row["ID"]) in str(errors) for row in rows if len(str(row["ID"])) > 10)


def test_export_datetime_cell_seconds_and_mapping_names_are_preserved():
    row = record(
        "original", 时间=datetime(2026, 10, 24, 12, 34, 56), 账户1="合成现金", 分类="合成分类"
    )
    raw = content([row], false_dimension=True)
    requirements = inspect_mapping_requirements(raw, "qianji_xlsx")
    assert {r["source_value"] for r in requirements} == {"合成现金", "支出 · 合成分类"}
    target = mapping().model_copy(
        update={
            "account_names": {"合成现金": str(uuid4())},
            "category_names": {"支出 · 合成分类": str(uuid4())},
        }
    )
    parsed = parse_qianji_xlsx(raw, target)
    assert not parsed.errors
    assert parsed.document.rows[0].payload["occurred_at"].endswith("12:34:56+08:00")


@pytest.mark.parametrize("format_name", ["qianji_csv", "qianji_xlsx"])
def test_actual_export_same_name_income_expense_categories_have_distinct_mapping_keys(format_name):
    rows = [
        record("source", 分类="其他"),
        record("income", 类型="收入", 分类="其他"),
        record("refund", 类型="退款", 金额="1.00", 分类="其他", 关联账单="source"),
    ]
    raw = content(rows, format_name, false_dimension=True)
    requirements = inspect_mapping_requirements(raw, format_name)
    assert {r["source_value"] for r in requirements} == {"收入 · 其他", "支出 · 其他"}
    expense, income = str(uuid4()), str(uuid4())
    target = mapping().model_copy(
        update={
            "category_names": {"支出 · 其他": expense, "收入 · 其他": income},
        }
    )
    with open_stage_source(
        raw,
        format_name,
        StageMapping(template_mapping=target.model_dump()),
        check_budget=lambda: None,
    ) as source:
        parsed = list(source.rows)
    assert all(not item.errors for item in parsed)
    assert [p.row.payload["category_id"] for p in parsed] == [expense, income, expense]
    assert [p.requirements[-1].source_key for p in parsed] == [
        "支出 · 其他",
        "收入 · 其他",
        "支出 · 其他",
    ]
    assert parsed[2].row.payload["bill_type"] == "refund"


def test_export_formula_does_not_become_private_error_text():
    parsed = staged([record("original", 金额='=HYPERLINK("https://invalid.example/secret")')])
    assert parsed[0].row is None
    assert "secret" not in str(parsed[0].errors)
