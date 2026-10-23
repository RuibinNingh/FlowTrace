"""Large adapters preserve public formats, original lines and bounded errors."""

import csv
import hashlib
import io
import re
import zipfile
from uuid import NAMESPACE_URL, uuid4, uuid5

import pytest
from openpyxl import Workbook

from flowtrace_server.imports.parsers import ImportFormatError, canonical, parse_json
from flowtrace_server.imports.staging_parsers import open_stage_source
from flowtrace_server.imports.staging_schemas import StageMapping


def native_row():
    return {
        "source_id": str(uuid4()),
        "entity_type": "category",
        "scope_id": str(uuid4()),
        "payload": {
            "name": "原始分类",
            "kind": "expense",
            "icon": "food",
            "parent_id": None,
            "sort_order": 0,
        },
    }


def source_file(format_name, rows):
    if format_name == "flowtrace_json":
        return canonical({"format": "flowtrace-data-v1", "source_namespace": "原件", "rows": rows})
    headers = ("source_id", "entity_type", "scope_id", "payload")
    values = [headers] + [
        [row["source_id"], row["entity_type"], row["scope_id"], canonical(row["payload"]).decode()]
        for row in rows
    ]
    if format_name == "flowtrace_csv":
        out = io.StringIO(newline="")
        csv.writer(out).writerows(values)
        return out.getvalue().encode()
    book = Workbook()
    book.active.title = "records"
    for row in values:
        book.active.append(row)
    out = io.BytesIO()
    book.save(out)
    return out.getvalue()


@pytest.mark.parametrize("format_name", ["flowtrace_json", "flowtrace_csv", "flowtrace_xlsx"])
def test_native_over_public_capacity_preserves_raw_presence_and_source_ids(format_name):
    rows = [native_row() for _ in range(75)]
    content = source_file(format_name, rows)
    with open_stage_source(
        content, format_name, StageMapping(), check_budget=lambda: None
    ) as source:
        parsed = list(source.rows)
        assert source.source_namespace == (
            "原件" if format_name.endswith("json") else "file-import"
        )
    assert len(parsed) == 75
    assert [item.position for item in parsed] == list(range(1, 76))
    assert parsed[-1].source_line == (75 if format_name.endswith("json") else 76)
    assert [item.row.model_dump() for item in parsed] == rows
    assert all(not item.errors and item.raw_hash for item in parsed)
    if format_name.endswith("json"):
        from pydantic import ValidationError

        with pytest.raises(ValidationError):
            parse_json(content)  # The existing public 50-row contract stays closed.


@pytest.mark.parametrize("format_name", ["qianji_csv", "qianji_xlsx"])
def test_v10_more_than_50_uses_original_file_and_actual_line(format_name):
    headers = ["时间", "类型", "金额", "账户1", "备注"]
    values = [headers] + [["2026-10-20 12:34", "支出", "12345678901.23", "现金", "同额"]] * 61
    if format_name.endswith("csv"):
        # Multiline notes and blank physical lines must not be renumbered by chunks.
        values[1] = ["2026-10-20 12:34", "支出", "12345678901.23", "现金", "两行\n备注"]
        out = io.StringIO(newline="")
        csv.writer(out).writerows(values)
        content = out.getvalue().encode()
    else:
        book = Workbook()
        for value in values:
            book.active.append(value)
        out = io.BytesIO()
        book.save(out)
        content = out.getvalue()
    scope, account = str(uuid4()), str(uuid4())
    mapping = StageMapping(
        template_mapping={
            "scope_id": scope,
            "timezone": "Asia/Shanghai",
            "account_names": {"现金": account},
        }
    )
    with open_stage_source(content, format_name, mapping, check_budget=lambda: None) as source:
        parsed = list(source.rows)
    assert len(parsed) == 61 and all(not item.errors for item in parsed)
    last_line = 63 if format_name.endswith("csv") else 62
    assert parsed[-1].source_line == last_line
    expected = str(
        uuid5(
            NAMESPACE_URL, f"qianji-template-v10:{hashlib.sha256(content).hexdigest()}:{last_line}"
        )
    )
    assert parsed[-1].row.source_id == expected
    assert parsed[-1].row.payload["money"]["amount_minor"] == "1234567890123"
    assert len({item.row.source_id for item in parsed}) == 61


def test_invalid_and_duplicate_rows_are_closed_and_do_not_hide_later_rows():
    first = native_row()
    invalid = native_row()
    invalid["payload"]["secret-untrusted-key" * 80] = "financial text must not enter errors"
    content = source_file("flowtrace_json", [first, invalid, first, native_row()])
    with open_stage_source(
        content, "flowtrace_json", StageMapping(), check_budget=lambda: None
    ) as source:
        rows = list(source.rows)
    assert len(rows) == 4 and rows[-1].row is not None
    assert rows[1].row is None and rows[2].row is None
    assert rows[2].errors == ({"row": 3, "field": "source_id", "code": "duplicate_source_id"},)
    assert all(set(e) == {"row", "field", "code"} for item in rows for e in item.errors)
    assert "financial text" not in str(rows[1].errors)
    assert all(e["field"] is None or len(e["field"]) <= 256 for e in rows[1].errors)


def test_callback_failure_propagates_and_unknown_format_is_rejected():
    def fail():
        raise RuntimeError("trusted_budget_expired")

    with pytest.raises(RuntimeError, match="trusted_budget_expired"):
        with open_stage_source(
            source_file("flowtrace_json", [native_row()]),
            "flowtrace_json",
            StageMapping(),
            check_budget=fail,
        ) as source:
            list(source.rows)
    with pytest.raises(ImportFormatError, match="unsupported_import_format"):
        with open_stage_source(
            b"private backup", "qianji_private", StageMapping(), check_budget=lambda: None
        ):
            pass


@pytest.mark.parametrize(
    "content,code",
    [
        (b'{"format":"flowtrace-data-v1","rows":[],"rows":[]}', "duplicate_json_key"),
        (b'{"format":"flowtrace-data-v1","source_namespace":"x","rows":[]}', "empty_import"),
        (
            b'{"format":"flowtrace-data-v1","source_namespace":"x","rows":[],"other":1}',
            "invalid_document_header",
        ),
    ],
)
def test_file_errors_are_explicit(content, code):
    with pytest.raises(ImportFormatError, match=code):
        with open_stage_source(
            content, "flowtrace_json", StageMapping(), check_budget=lambda: None
        ) as source:
            list(source.rows)


def bill_row():
    row = native_row()
    row.update(
        entity_type="bill",
        payload={
            "bill_type": "balance_adjustment",
            "account_id": str(uuid4()),
            "target_balance_minor": "9000",
            "money": {"currency": "CNY", "currency_scale": 2, "amount_minor": "125"},
            "business_date": "2026-10-20",
            "business_timezone": "Asia/Shanghai",
        },
    )
    return row


def test_native_manifest_and_signed_posting_are_validated_without_payload_rewrite():
    row, image = bill_row(), str(uuid4())
    row["payload"]["attachment_ids"] = [image]
    hint = {row["source_id"]: {"signed_principal_minor": "-125"}}
    body = {
        "format": "flowtrace-export-v1",
        "document": {
            "format": "flowtrace-data-v1",
            "source_namespace": "原始导出",
            "rows": [row],
            "posting_hints": hint,
        },
        "attachments": [
            {
                "attachment_id": image,
                "sha256": "a" * 64,
                "size_bytes": 77,
                "media_type": "image/png",
                "href": f"/api/v1/attachments/{image}/content",
                "authorization": "current_session_and_scope_required",
            }
        ],
    }
    with open_stage_source(
        canonical(body), "flowtrace_json", StageMapping(), check_budget=lambda: None
    ) as source:
        parsed = list(source.rows)
        assert source.posting_hints[row["source_id"]].signed_principal_minor == "-125"
        assert source.attachment_sources[0]["sha256"] == "a" * 64
    assert parsed[0].row.model_dump() == row and not parsed[0].errors
    body["attachments"][0]["href"] = "http://127.0.0.1/private-never-fetch"
    with pytest.raises(ImportFormatError, match="invalid_attachment_manifest"):
        with open_stage_source(
            canonical(body), "flowtrace_json", StageMapping(), check_budget=lambda: None
        ):
            pass


@pytest.mark.parametrize("signed", ["0", "126", "-126"])
def test_mismatched_signed_posting_is_a_positioned_row_error(signed):
    row = bill_row()
    body = {
        "format": "flowtrace-data-v1",
        "source_namespace": "signed",
        "rows": [row],
        "posting_hints": {row["source_id"]: {"signed_principal_minor": signed}},
    }
    with open_stage_source(
        canonical(body), "flowtrace_json", StageMapping(), check_budget=lambda: None
    ) as source:
        parsed = list(source.rows)
    assert parsed[0].row is None
    assert parsed[0].errors[0] == {
        "row": 1,
        "field": "posting_hints",
        "code": "historical_posting_amount_mismatch",
    }


def replace_sheet(content, convert):
    output = io.BytesIO()
    with (
        zipfile.ZipFile(io.BytesIO(content)) as source,
        zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as target,
    ):
        for name in source.namelist():
            value = source.read(name)
            target.writestr(name, convert(value) if name == "xl/worksheets/sheet1.xml" else value)
    return output.getvalue()


def test_xlsx_dishonest_dimensions_do_not_silently_truncate_records():
    content = source_file("flowtrace_xlsx", [native_row() for _ in range(75)])
    content = replace_sheet(
        content, lambda value: re.sub(rb'<dimension ref="[^"]+"', b'<dimension ref="A1:A1"', value)
    )
    with open_stage_source(
        content, "flowtrace_xlsx", StageMapping(), check_budget=lambda: None
    ) as source:
        assert len(list(source.rows)) == 75


def test_xlsx_formula_and_malformed_trailing_xml_are_rejected_explicitly():
    content = source_file("flowtrace_xlsx", [native_row() for _ in range(3)])
    formula = replace_sheet(
        content,
        lambda value: value.replace(b'<c r="D3"', b'<c r="D3"', 1).replace(
            b'</row><row r="4">', b'<c r="E3"><f>1+1</f><v>2</v></c></row><row r="4">', 1
        ),
    )
    with open_stage_source(
        formula, "flowtrace_xlsx", StageMapping(), check_budget=lambda: None
    ) as source:
        rows = list(source.rows)
    assert rows[1].row is None and rows[1].errors
    malformed = replace_sheet(content, lambda value: value.replace(b"</sheetData>", b"</wrong>"))
    with pytest.raises(ImportFormatError, match="invalid_xlsx"):
        with open_stage_source(
            malformed, "flowtrace_xlsx", StageMapping(), check_budget=lambda: None
        ) as source:
            list(source.rows)


def test_csv_blank_lines_and_multiline_notes_keep_original_physical_lines():
    scope = str(uuid4())
    content = (
        '时间,类型,金额,备注\r\n\r\n2026-10-20,支出,1.00,"第一行\n第二行"\r\n'
        "\r\n2026-10-20,支出,1.00,后续\r\n"
    ).encode()
    mapping = StageMapping(template_mapping={"scope_id": scope, "timezone": "Asia/Shanghai"})
    with open_stage_source(content, "qianji_csv", mapping, check_budget=lambda: None) as source:
        rows = list(source.rows)
    assert [row.source_line for row in rows] == [3, 6]
    assert all(row.row is not None for row in rows)
