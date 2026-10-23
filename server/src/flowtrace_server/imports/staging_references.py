"""Explicit source references collected before financial row conversion.

Only known public V10 cells and native reference fields are inspected. A key
is an uploaded name/identifier, never proof that an existing resource exists
or is authorized. URL-like image names remain strings and are never fetched.
"""

import re
from dataclasses import dataclass

from .parsers import ImportFormatError, _decode_json, decode_json
from .staging_schemas import STAGE_MAX_SOURCE_BYTES

IDENTIFIER = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
ENTITY_TYPES = {"book", "account", "category", "tag", "bill", "budget"}


@dataclass(frozen=True)
class SourceReference:
    kind: str
    source_kind: str
    source_key: str
    resource_type: str | None
    first_line: int

    @property
    def identity(self):
        return self.kind, self.source_kind, self.resource_type, self.source_key


def qianji_references(raw, line, *, check_budget):
    """Yield names even when a later amount/date/mapping check rejects a row."""
    if not isinstance(raw, dict) or None in raw:
        return

    def add(kind, value):
        check_budget()
        if value in (None, ""):
            return
        if not isinstance(value, str) or not 1 <= len(value) <= 2000 or "\x00" in value:
            raise ImportFormatError("mapping_source_value_invalid", row=line)
        yield SourceReference(kind, "name", value, None, line)

    yield from add("account", raw.get("账户1"))
    if raw.get("类型") in {"转账", "还款"}:
        yield from add("account", raw.get("账户2"))
    yield from add("category", raw.get("二级分类") or raw.get("分类"))
    tags = raw.get("标签", "")
    if isinstance(tags, str):
        for value in tags.split("#"):
            yield from add("tag", value)
    links = raw.get("账单图片", "")
    if not isinstance(links, str):
        return
    if links.startswith("["):
        links = decode_json(links.encode())
        if not isinstance(links, list) or any(not isinstance(link, str) for link in links):
            raise ImportFormatError("invalid_image_links", row=line, field="账单图片")
    else:
        links = [link.strip() for link in links.split(",") if link.strip()]
    for value in links:
        yield from add("image", value)


def native_shape(raw, *, table=False):
    if (
        not isinstance(raw, dict)
        or not isinstance(raw.get("entity_type"), str)
        or raw["entity_type"] not in ENTITY_TYPES
    ):
        return None
    if table and isinstance(raw.get("payload"), str):
        return {**raw, "payload": _decode_json(raw["payload"].encode(), STAGE_MAX_SOURCE_BYTES)}
    return raw


def native_definition(raw):
    value = raw.get("source_id") if isinstance(raw, dict) else None
    return value if isinstance(value, str) and IDENTIFIER.fullmatch(value) else None


def native_references(raw, line, *, check_budget):
    """Known reference paths only; names/notes/money/catalog fields are ignored."""
    if raw is None:
        return

    def add(kind, value, resource_type=None):
        check_budget()
        if isinstance(value, str) and IDENTIFIER.fullmatch(value):
            yield SourceReference(kind, "identifier", value, resource_type, line)

    entity = raw["entity_type"]
    if entity != "book":
        yield from add("scope", raw.get("scope_id"), "user" if entity == "account" else "book")
    payload = raw.get("payload")
    if not isinstance(payload, dict):
        return
    if entity == "bill":
        yield from add("scope", payload.get("book_id"), "book")
        for field in ("account_id", "from_account_id", "to_account_id"):
            yield from add("resource", payload.get(field), "account")
        yield from add("resource", payload.get("category_id"), "category")
        for field, kind, resource_type in (
            ("tag_ids", "resource", "tag"),
            ("attachment_ids", "image", None),
        ):
            values = payload.get(field)
            if isinstance(values, list):
                for value in values:
                    yield from add(kind, value, resource_type)
        fee = payload.get("fee")
        if isinstance(fee, dict):
            yield from add("resource", fee.get("account_id"), "account")
            yield from add("resource", fee.get("category_id"), "category")
        allocations = payload.get("allocations")
        if isinstance(allocations, list):
            for value in allocations:
                check_budget()
                if isinstance(value, dict):
                    yield from add("resource", value.get("source_bill_id"), "bill")
    elif entity == "account":
        yield from add("resource", payload.get("group_id"), "account_group")
    elif entity == "category":
        yield from add("resource", payload.get("parent_id"), "category")
    elif entity == "tag":
        yield from add("resource", payload.get("group_id"), "tag")
    elif entity == "budget":
        values = payload.get("categories")
        if isinstance(values, list):
            for value in values:
                check_budget()
                if isinstance(value, dict):
                    yield from add("resource", value.get("category_id"), "category")
