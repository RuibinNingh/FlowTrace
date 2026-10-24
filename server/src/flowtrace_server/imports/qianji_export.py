"""Explicit Qianji export profile; original identifiers, never guessed links.

The bounded first pass keeps only reference/amount metadata. Notes and other
private cells remain in the existing caller-owned stream on the second pass.
"""

import re
from dataclasses import dataclass
from datetime import datetime
from uuid import NAMESPACE_URL, uuid5

from flowtrace_server.currencies.catalog import CURRENCY_SCALES

from .parsers import ImportFormatError
from .qianji_template import PUBLIC_COLUMNS, _amount, convert_public_record
from .schemas import ImportRow

EXPORT_COLUMNS = PUBLIC_COLUMNS | {"ID", "账本", "币种", "已报销", "记账者", "关联账单"}
EXPORT_REQUIRED = {"ID", "时间", "账本", "类型", "金额", "币种", "关联账单"}
EXPORT_NAMESPACE = "qianji-export-v1"
_IDENTIFIER = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
_NON_TEXT_ID = "\x00qianji_identifier_requires_text"


def export_profile(headers):
    """Keep the public template profile closed; recognize actual export columns."""
    values = set(headers)
    if len(headers) != len(values) or not {"时间", "类型", "金额"}.issubset(values):
        raise ImportFormatError("unsupported_qianji_columns", row=1)
    if "ID" in values:
        if not EXPORT_REQUIRED.issubset(values) or not values.issubset(EXPORT_COLUMNS):
            raise ImportFormatError("unsupported_qianji_columns", row=1)
        return True
    if not values.issubset(PUBLIC_COLUMNS):
        raise ImportFormatError("unsupported_qianji_columns", row=1)
    return False


def xlsx_text(header, cell, *, export=False):
    value = cell.value
    if export and header in {"ID", "关联账单"} and value not in (None, ""):
        # Numeric identifiers may already have lost precision in Excel. Do not
        # silently turn a rounded 19/21-digit identifier into another bill.
        return value if isinstance(value, str) else _NON_TEXT_ID
    if header == "时间" and isinstance(value, datetime):
        if value.microsecond or value.tzinfo or (value.second and not export):
            return "unsupported_excel_timestamp"
        return value.strftime("%Y-%m-%d %H:%M:%S" if export else "%Y-%m-%d %H:%M")
    return "" if value is None else value if isinstance(value, str) else str(value)


def source_identifier(value):
    if not isinstance(value, str) or not _IDENTIFIER.fullmatch(value):
        raise ImportFormatError("qianji_id_invalid", field="ID")
    return str(uuid5(NAMESPACE_URL, EXPORT_NAMESPACE + ":" + value))


def export_category_name(raw):
    """Export names are scoped by financial kind, unlike legacy V10 names.

    Ordinary income/expense commands require their category kind to match.
    Refund/reimbursement commands accept an expense category and retain the
    source-expense classification; they never become an ordinary income.
    """
    category = raw.get("二级分类") or raw.get("分类", "")
    if not category:
        return ""
    if not isinstance(category, str) or "\x00" in category:
        raise ImportFormatError("mapping_source_value_invalid", field="分类")
    key = ("收入" if raw.get("类型") == "收入" else "支出") + " · " + category
    if len(key) > 2000:
        raise ImportFormatError("mapping_source_value_invalid", field="分类")
    return key


@dataclass(frozen=True)
class _Source:
    line: int
    kind: str
    book: str
    currency: str
    amount: int
    reference: str | None


@dataclass
class ExportContext:
    sources: dict[str, _Source]
    errors: dict[int, tuple[str, str]]

    def definition(self, raw):
        try:
            return source_identifier(raw.get("ID"))
        except (ImportFormatError, AttributeError):
            return None

    def reference(self, raw):
        value = raw.get("关联账单") if isinstance(raw, dict) else None
        return source_identifier(value) if value and _IDENTIFIER.fullmatch(value) else None

    def convert(self, raw, mapping, line):
        if line in self.errors:
            code, field = self.errors[line]
            raise ImportFormatError(code, row=line, field=field)
        identifier = source_identifier(raw.get("ID"))
        source = self.sources[raw["ID"]]
        receipt = source.kind in {"退款", "报销入账"}
        public = {key: raw.get(key, "") for key in PUBLIC_COLUMNS}
        public["分类"], public["二级分类"] = export_category_name(raw), ""
        if receipt:
            public["类型"] = "收入"
        result = convert_public_record(public, "", mapping, line, allow_seconds=True)
        payload = result.payload
        if receipt:
            payload["bill_type"] = "refund" if source.kind == "退款" else "reimbursement"
            payload["allocations"] = [
                {
                    "source_bill_id": source_identifier(source.reference),
                    "source_amount_minor": str(source.amount),
                    "receipt_amount_minor": str(source.amount),
                }
            ]
            payload["income_component_minor"] = "0"
        return ImportRow(
            source_id=identifier, entity_type="bill", scope_id=mapping.scope_id, payload=payload
        )


def prepare_export(records, mapping, *, max_rows, check_budget):
    sources, errors, totals = {}, {}, {}

    def error(line, code, field):
        errors.setdefault(line, (code, field))

    for position, (line, raw) in enumerate(records, 1):
        check_budget()
        if position > max_rows:
            raise ImportFormatError("too_many_rows", row=line)
        try:
            if None in raw or any(value is None for value in raw.values()):
                raise ImportFormatError("invalid_columns")
            identifier = raw.get("ID")
            source_identifier(identifier)
            if identifier in sources:
                error(sources[identifier].line, "qianji_duplicate_id", "ID")
                raise ImportFormatError("qianji_duplicate_id", field="ID")
            currency = raw.get("币种")
            if currency not in CURRENCY_SCALES:
                raise ImportFormatError("qianji_currency_unsupported", field="币种")
            if currency != mapping.currency or CURRENCY_SCALES[currency] != mapping.currency_scale:
                error(line, "qianji_currency_mismatch", "币种")
            book = raw.get("账本")
            if not isinstance(book, str) or not 1 <= len(book) <= 2000 or "\x00" in book:
                raise ImportFormatError("qianji_reference_invalid", field="账本")
            reference = raw.get("关联账单", "") or None
            kind = raw.get("类型")
            if reference is not None and (
                not isinstance(reference, str) or not _IDENTIFIER.fullmatch(reference)
            ):
                raise ImportFormatError("qianji_reference_invalid", field="关联账单")
            receipt = kind in {"退款", "报销入账"}
            if receipt and reference is None:
                raise ImportFormatError("qianji_reference_missing", field="关联账单")
            if not receipt and reference is not None:
                raise ImportFormatError("qianji_reference_invalid", field="关联账单")
            if raw.get("已报销", "") not in ("", "0", "false", "False", "否", "未报销"):
                raise ImportFormatError("qianji_reimbursement_details_required", field="已报销")
            scale = CURRENCY_SCALES[currency]
            amount = _amount(raw.get("金额", ""), scale)
            fee = _amount(raw.get("手续费") or "0", scale)
            discount = _amount(raw.get("优惠券") or "0", scale)
            principal = amount - fee - discount
            if principal <= 0:
                raise ImportFormatError("nonpositive_net_amount", field="金额")
            sources[identifier] = _Source(line, kind, book, currency, principal, reference)
        except ImportFormatError as exception:
            error(line, exception.code, exception.field or "payload")

    # A linear graph walk detects cycles without unbounded Python recursion.
    completed = set()
    for identifier in sources:
        check_budget()
        current, positions, path = identifier, {}, []
        while current in sources and current not in completed:
            check_budget()
            if current in positions:
                for key in path[positions[current] :]:
                    error(sources[key].line, "qianji_reference_cycle", "关联账单")
                break
            positions[current] = len(path)
            path.append(current)
            current = sources[current].reference
        completed.update(path)

    for identifier, row in sources.items():
        check_budget()
        if row.reference is None:
            continue
        source = sources.get(row.reference)
        if source is None:
            error(row.line, "qianji_reference_missing", "关联账单")
        elif source.kind not in {"支出", "报销"}:
            error(row.line, "qianji_source_type_invalid", "关联账单")
        elif source.book != row.book:
            error(row.line, "qianji_source_book_mismatch", "关联账单")
        elif source.currency != row.currency:
            error(row.line, "qianji_source_currency_mismatch", "币种")
        else:
            totals[row.reference] = totals.get(row.reference, 0) + row.amount
    for row in sources.values():
        check_budget()
        if row.reference in totals and totals[row.reference] > sources[row.reference].amount:
            error(row.line, "qianji_refund_exceeds_source", "金额")
    return ExportContext(sources, errors)
