"""Qianji's public V10 template adapter, not its undocumented private backup.

Source: https://docs.qianjiapp.com/other/import_templete.html
Names are mapped explicitly to existing FlowTrace resources. We never fetch
image URLs or infer a receipt source relationship from an amount. The public
template's 报销 is the outgoing tracked expense; the guide distinguishes the
later 报销入账 receipt: https://docs.qianjiapp.com/ji-zhang-jie-mian/baoxiao.html
"""

import csv
import hashlib
import io
from datetime import datetime
from decimal import Decimal, InvalidOperation
from uuid import NAMESPACE_URL, uuid5
from zoneinfo import ZoneInfo

from pydantic import Field, ValidationError, model_validator

from flowtrace_server.domain.money import checked_minor
from flowtrace_server.sync.schemas import ClosedModel, Identifier

from .parsers import MAX_FILE_BYTES, ImportFormatError, ParsedTable
from .schemas import ImportDocument, ImportRow

PUBLIC_COLUMNS = {
    "时间",
    "分类",
    "二级分类",
    "类型",
    "金额",
    "账户1",
    "账户2",
    "备注",
    "账单图片",
    "账单标记",
    "手续费",
    "优惠券",
    "标签",
}


class TemplateMapping(ClosedModel):
    scope_id: Identifier
    timezone: str
    currency: str = "CNY"
    currency_scale: int = Field(default=2, ge=0, le=6)
    account_names: dict[str, Identifier] = Field(default_factory=dict, max_length=100)
    category_names: dict[str, Identifier] = Field(default_factory=dict, max_length=100)
    tag_names: dict[str, Identifier] = Field(default_factory=dict, max_length=100)
    image_urls: dict[str, Identifier] = Field(default_factory=dict, max_length=100)

    @model_validator(mode="after")
    def valid(self):
        from flowtrace_server.sync.schemas import Money, _validate_timezone

        _validate_timezone(self.timezone)
        Money(currency=self.currency, currency_scale=self.currency_scale, amount_minor="1")
        return self


def _amount(text: str, scale: int) -> int:
    try:
        if not isinstance(text, str) or len(text) > 100:
            raise ValueError
        value = Decimal(text)
        if not value.is_finite() or value < 0:
            raise ValueError
        # Decimal arithmetic uses a context that may round before validation.
        # Decode the coefficient/exponent directly so no context can turn a
        # sub-minor fraction into an apparently exact cent.
        parts = value.as_tuple()
        coefficient = int("".join(map(str, parts.digits)))
        power = parts.exponent + scale
        if coefficient == 0:
            return 0
        if power >= 0:
            if len(parts.digits) + power > 19:
                raise ValueError
            minor = coefficient * 10**power
        else:
            if -power > len(parts.digits):
                raise ValueError
            divisor = 10 ** (-power)
            minor, remainder = divmod(coefficient, divisor)
            if remainder:
                raise ValueError
        return checked_minor(minor)
    except (ValueError, InvalidOperation, OverflowError):
        raise ImportFormatError("invalid_exact_amount") from None


def _mapped(name: str, mapping: dict, field: str):
    if not name:
        return None
    if name not in mapping:
        raise ImportFormatError("mapping_required", field=field)
    return mapping[name]


def _time(text, zone):
    text = text.replace("/", "-")
    formats = ("%Y-%m-%d %H:%M", "%Y-%m-%d")
    for fmt in formats:
        try:
            stamp = datetime.strptime(text, fmt)
            if fmt == formats[1]:
                return stamp.date().isoformat(), None
            tz = ZoneInfo(zone)
            first, second = stamp.replace(tzinfo=tz, fold=0), stamp.replace(tzinfo=tz, fold=1)
            if first.utcoffset() != second.utcoffset():
                raise ImportFormatError("ambiguous_or_nonexistent_local_time", field="时间")
            return stamp.date().isoformat(), first.isoformat()
        except ValueError:
            continue
    raise ImportFormatError("invalid_time", field="时间")


def parse_qianji_csv(content: bytes, mapping: TemplateMapping) -> ParsedTable:
    if len(content) > MAX_FILE_BYTES:
        raise ImportFormatError("file_too_large")
    try:
        reader = csv.DictReader(io.StringIO(content.decode("utf-8-sig"), newline=""), strict=True)
        if (
            reader.fieldnames is None
            or not {"时间", "类型", "金额"}.issubset(reader.fieldnames)
            or len(reader.fieldnames) != len(set(reader.fieldnames))
            or not set(reader.fieldnames).issubset(PUBLIC_COLUMNS)
        ):
            raise ImportFormatError("unsupported_qianji_columns", row=1)
        return _convert(reader, hashlib.sha256(content).hexdigest(), mapping)
    except (UnicodeError, csv.Error):
        raise ImportFormatError("invalid_csv") from None


def inspect_mapping_requirements(content: bytes, format_name: str) -> list[dict]:
    """Return only explicit resource names from this caller's bounded upload."""
    if len(content) > MAX_FILE_BYTES:
        raise ImportFormatError("file_too_large")
    book = None
    try:
        if format_name == "qianji_csv":
            reader = csv.DictReader(
                io.StringIO(content.decode("utf-8-sig"), newline=""), strict=True
            )
            headers, records = reader.fieldnames, reader
        else:
            from .parsers import secure_workbook

            book = secure_workbook(content)
            if len(book.sheetnames) != 1:
                raise ImportFormatError("one_template_sheet_required")
            sheet = book.active
            if sheet.max_column > len(PUBLIC_COLUMNS) or sheet.max_row > 51:
                raise ImportFormatError("workbook_dimensions_invalid")
            cells = sheet.iter_rows()
            headers = tuple(cell.value for cell in next(cells, ()))

            def rows():
                for row in cells:
                    if any(cell.data_type == "f" for cell in row):
                        raise ImportFormatError("workbook_formula_not_allowed")
                    yield dict(
                        zip(
                            headers,
                            ("" if cell.value is None else str(cell.value) for cell in row),
                            strict=True,
                        )
                    )

            records = rows()
        if (
            not headers
            or not {"时间", "类型", "金额"}.issubset(headers)
            or len(headers) != len(set(headers))
            or not set(headers).issubset(PUBLIC_COLUMNS)
        ):
            raise ImportFormatError("unsupported_qianji_columns", row=1)
        required = {}

        def add(kind, value, row):
            if not value:
                return
            if not isinstance(value, str) or len(value) > 2000:
                raise ImportFormatError("mapping_source_value_too_long", row=row)
            required.setdefault((kind, value), set()).add(row)

        for position, record in enumerate(records, 2):
            if position > 51:
                raise ImportFormatError("too_many_rows", row=position)
            if None in record or any(value is None for value in record.values()):
                raise ImportFormatError("invalid_columns", row=position)
            add("account", record.get("账户1", ""), position)
            if record.get("类型") in {"转账", "还款"}:
                add("account", record.get("账户2", ""), position)
            add("category", record.get("二级分类") or record.get("分类", ""), position)
            for value in record.get("标签", "").split("#"):
                add("tag", value, position)
            links = record.get("账单图片", "")
            if links.startswith("["):
                from .parsers import decode_json

                links = decode_json(links.encode())
                if not isinstance(links, list) or any(not isinstance(link, str) for link in links):
                    raise ImportFormatError("invalid_image_links", row=position, field="账单图片")
            else:
                links = [link.strip() for link in links.split(",") if link.strip()]
            for value in links:
                add("image", value, position)
        return [
            {"kind": kind, "source_value": value, "rows": sorted(rows)}
            for (kind, value), rows in sorted(required.items())
        ]
    except (UnicodeError, csv.Error):
        raise ImportFormatError("invalid_csv") from None
    finally:
        if book is not None:
            book.close()


def parse_qianji_xlsx(content: bytes, mapping: TemplateMapping) -> ParsedTable:
    from .parsers import secure_workbook

    book = secure_workbook(content)
    try:
        if len(book.sheetnames) != 1:
            raise ImportFormatError("one_template_sheet_required")
        sheet = book.active
        if sheet.max_column > len(PUBLIC_COLUMNS) or sheet.max_row > 51:
            raise ImportFormatError("workbook_dimensions_invalid")
        records = sheet.iter_rows()
        headers = tuple(cell.value for cell in next(records, ()))
        if (
            not {"时间", "类型", "金额"}.issubset(headers)
            or len(headers) != len(set(headers))
            or not set(headers).issubset(PUBLIC_COLUMNS)
        ):
            raise ImportFormatError("unsupported_qianji_columns", row=1)

        def rows():
            for cells in records:
                if any(cell.data_type == "f" for cell in cells):
                    yield {None: None}
                    continue
                row = {}
                for header, cell in zip(headers, cells, strict=True):
                    value = cell.value
                    if header == "时间" and isinstance(value, datetime):
                        if value.second or value.microsecond or value.tzinfo:
                            value = "unsupported_excel_timestamp"
                        else:
                            value = value.strftime("%Y-%m-%d %H:%M")
                    elif value is None:
                        value = ""
                    elif not isinstance(value, str):
                        value = str(value)
                    row[header] = value
                yield row

        return _convert(rows(), hashlib.sha256(content).hexdigest(), mapping)
    finally:
        book.close()


def convert_public_record(row, file_digest, mapping, position):
    """Convert one public V10 record at its actual original source line."""
    if None in row or any(value is None for value in row.values()):
        raise ImportFormatError("invalid_columns")
    kind = {
        "收入": "income",
        "支出": "expense",
        "报销": "expense",
        "转账": "transfer",
        "还款": "credit_repayment",
    }.get(row["类型"])
    if kind is None:
        raise ImportFormatError("unsupported_qianji_type", field="类型")
    value = _amount(row["金额"], mapping.currency_scale)
    fee = _amount(row.get("手续费") or "0", mapping.currency_scale)
    discount = _amount(row.get("优惠券") or "0", mapping.currency_scale)
    if fee and kind not in {"transfer", "credit_repayment"}:
        raise ImportFormatError("fee_type_invalid", field="手续费")
    if discount and kind != "expense":
        raise ImportFormatError("discount_semantics_unsupported", field="优惠券")
    principal = value - fee - discount
    if principal <= 0:
        raise ImportFormatError("nonpositive_net_amount", field="金额")
    money = {
        "currency": mapping.currency,
        "currency_scale": mapping.currency_scale,
        "amount_minor": str(principal),
    }
    day, instant = _time(row["时间"], mapping.timezone)
    flags = row.get("账单标记", "")
    payload = {
        "bill_type": kind,
        "book_id": mapping.scope_id,
        "money": money,
        "business_date": day,
        "business_timezone": mapping.timezone,
        "source": "import",
        "note": row.get("备注", ""),
        "flags": {
            "exclude_from_statistics": flags in {"不计收支", "nc", "不计收支&预算", "nc&nb"},
            "exclude_from_budget": flags in {"不计预算", "nb", "不计收支&预算", "nc&nb"},
        },
    }
    if instant:
        payload["occurred_at"] = instant
    if row["类型"] == "报销":
        payload["reimbursement_tracking"] = True
    first = _mapped(row.get("账户1", ""), mapping.account_names, "账户1")
    if kind in {"transfer", "credit_repayment"}:
        second = _mapped(row.get("账户2", ""), mapping.account_names, "账户2")
        if not first or not second:
            raise ImportFormatError("two_account_mapping_required", field="账户1/账户2")
        payload.update(from_account_id=first, to_account_id=second)
    else:
        payload["account_id"] = first
    category = row.get("二级分类") or row.get("分类", "")
    payload["category_id"] = _mapped(category, mapping.category_names, "分类")
    payload["tag_ids"] = [
        _mapped(name, mapping.tag_names, "标签") for name in row.get("标签", "").split("#") if name
    ]
    urls = row.get("账单图片", "")
    if urls.startswith("["):
        from .parsers import decode_json

        urls = decode_json(urls.encode())
        if not isinstance(urls, list) or any(not isinstance(u, str) for u in urls):
            raise ImportFormatError("invalid_image_links", field="账单图片")
    else:
        urls = [u.strip() for u in urls.split(",") if u.strip()]
    payload["attachment_ids"] = [_mapped(url, mapping.image_urls, "账单图片") for url in urls]
    if fee:
        payload["fee"] = {
            "money": {**money, "amount_minor": str(fee)},
            "account_id": first,
            "flags": {"exclude_from_statistics": False, "exclude_from_budget": False},
        }
    if discount:
        payload.update(gross_amount_minor=str(value), discount_minor=str(discount))
    source = str(uuid5(NAMESPACE_URL, f"qianji-template-v10:{file_digest}:{position}"))
    return ImportRow(
        source_id=source, entity_type="bill", scope_id=mapping.scope_id, payload=payload
    )


def _convert(records, file_digest, mapping):
    rows, errors = [], []
    for position, row in enumerate(records, 2):
        if position > 51:
            errors.append({"row": position, "field": None, "code": "too_many_rows"})
            break
        try:
            rows.append(convert_public_record(row, file_digest, mapping, position))
        except ImportFormatError as error:
            errors.append({"row": position, "field": error.field, "code": error.code})
        except (ValidationError, ValueError):
            errors.append({"row": position, "field": "payload", "code": "invalid_bill"})
    if errors:
        return ParsedTable(None, tuple(errors))
    if not rows:
        return ParsedTable(None, ({"row": None, "field": None, "code": "empty_import"},))
    return ParsedTable(
        ImportDocument(
            format="flowtrace-data-v1", source_namespace="qianji-public-template-v10", rows=rows
        ),
        (),
    )
