"""Trusted stage adapters; public 50-row/5-MiB contracts stay unchanged.

JSON is decoded within the 50-MiB source bound. CSV/XLSX records are consumed
one at a time; all adapters sample a caller-owned cooperative execution budget.
Nothing reads a user path, extracts an archive member or fetches an image URL.
"""

import csv
import hashlib
import io
import json
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Annotated, Iterator, Literal
from xml.etree.ElementTree import ParseError
from zipfile import BadZipFile

from defusedxml.common import DefusedXmlException
from pydantic import Field, StringConstraints, ValidationError

from flowtrace_server.domain.money import parse_minor
from flowtrace_server.sync.schemas import ClosedModel, Identifier

from .attachment_sources import validate_attachment_manifest
from .parsers import HEADERS, ImportFormatError, _decode_json, _secure_workbook
from .qianji_export import EXPORT_NAMESPACE, export_profile, prepare_export, xlsx_text
from .qianji_template import convert_public_record
from .schemas import HistoricalPosting, ImportRow
from .staging_references import (
    SourceReference,
    native_definition,
    native_references,
    native_shape,
    qianji_references,
)
from .staging_schemas import STAGE_MAX_ROWS, STAGE_MAX_SOURCE_BYTES, StageMapping


class _DocumentHeader(ClosedModel):
    format: Literal["flowtrace-data-v1"]
    source_namespace: Annotated[str, StringConstraints(min_length=1, max_length=80)]
    posting_hints: dict[Identifier, HistoricalPosting] = Field(
        default_factory=dict, max_length=STAGE_MAX_ROWS
    )


@dataclass(frozen=True)
class ParsedStageRow:
    position: int
    source_line: int
    row: ImportRow | None
    raw_hash: str
    errors: tuple[dict, ...]
    requirements: tuple[SourceReference, ...] = ()
    defined_source_id: str | None = None


@dataclass(frozen=True)
class StageSource:
    source_namespace: str
    posting_hints: dict[str, HistoricalPosting]
    attachment_sources: list[dict]
    rows: Iterator[ParsedStageRow]


def _header(value):
    try:
        return _DocumentHeader.model_validate(value)
    except ValidationError:
        raise ImportFormatError("invalid_document_header") from None


def _error(line, code, field=None):
    if field is not None and (len(field) > 200 or "\x00" in field):
        field = "payload"
    return {"row": line, "field": field, "code": code if len(code) <= 64 else "invalid_row"}


def _hash_raw(value):
    # DictReader may represent extra columns with a None key. Preserve that
    # original shape without sorting unlike JSON keys of different types.
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode()
    ).hexdigest()


def _validated_rows(
    records,
    hints,
    manifest,
    convert,
    check_budget,
    *,
    qianji=False,
    table=False,
    export_context=None,
):
    seen, referenced, hint_rows, count, any_errors = set(), set(), set(), 0, False
    for position, (line, raw) in enumerate(records, 1):
        check_budget()
        if position > STAGE_MAX_ROWS:
            raise ImportFormatError("too_many_rows", row=line)
        count = position
        row, errors, requirement_errors, requirements, defined = None, (), (), [], None
        try:
            if qianji:
                references = qianji_references(
                    raw, line, check_budget=check_budget, exported=export_context is not None
                )
                if export_context is not None:
                    defined = export_context.definition(raw)
                    reference = export_context.reference(raw)
                    if reference is not None:
                        requirements.append(
                            SourceReference("resource", "identifier", reference, "bill", line)
                        )
            else:
                shape = native_shape(raw, table=table)
                defined = native_definition(shape)
                references = native_references(shape, line, check_budget=check_budget)
            for value in references:
                check_budget()
                requirements.append(value)
        except ImportFormatError as error:
            requirement_errors = (_error(line, error.code, error.field),)
        try:
            row = convert(raw, line)
            if row.source_id in seen:
                raise ImportFormatError("duplicate_source_id", field="source_id")
            seen.add(row.source_id)
            hint = hints.get(row.source_id)
            if hint is not None:
                hint_rows.add(row.source_id)
                if (
                    row.entity_type != "bill"
                    or row.payload.get("bill_type") != "balance_adjustment"
                ):
                    raise ImportFormatError(
                        "historical_posting_requires_adjustment", field="posting_hints"
                    )
                signed = parse_minor(hint.signed_principal_minor)
                if signed == 0 or abs(signed) != parse_minor(row.payload["money"]["amount_minor"]):
                    raise ImportFormatError(
                        "historical_posting_amount_mismatch", field="posting_hints"
                    )
            if row.entity_type == "bill":
                referenced.update(row.payload.get("attachment_ids", []))
        except ImportFormatError as error:
            row, errors = None, (_error(line, error.code, error.field),)
        except ValidationError as error:
            errors = tuple(
                _error(line, detail["type"], ".".join(map(str, detail["loc"])))
                for detail in error.errors(include_input=False, include_url=False)[:100]
            )
            row = None
        if requirement_errors:
            unique_errors = dict.fromkeys(
                tuple(item.items()) for item in errors + requirement_errors
            )
            errors = tuple(dict(item) for item in unique_errors)[:100]
            row = None
        any_errors |= bool(errors)
        yield ParsedStageRow(
            position, line, row, _hash_raw(raw), errors, tuple(requirements), defined
        )
    if not count:
        raise ImportFormatError("empty_import")
    if set(hints) - hint_rows - seen:
        raise ImportFormatError("historical_posting_source_missing", field="posting_hints")
    # A malformed row already prevents preview/apply; do not misdiagnose its
    # otherwise valid manifest as an unrelated missing attachment.
    if (
        manifest is not None
        and not any_errors
        and {item["source_id"] for item in manifest} != referenced
    ):
        raise ImportFormatError("invalid_attachment_manifest", field="attachments")
    check_budget()


def _manifest(records):
    if records is None:
        return None
    if not isinstance(records, list) or len(records) > STAGE_MAX_ROWS:
        raise ImportFormatError("invalid_attachment_manifest", field="attachments")
    return validate_attachment_manifest(
        records,
        {
            item.get("attachment_id")
            for item in records
            if isinstance(item, dict) and isinstance(item.get("attachment_id"), str)
        },
    )


def _native_record(raw, line):
    return ImportRow.model_validate(raw)


def _table_record(raw, line):
    if set(raw) != set(HEADERS) or None in raw.values():
        raise ImportFormatError("invalid_columns")
    if not isinstance(raw["payload"], str):
        raise ImportFormatError("payload_json_required", field="payload")
    return ImportRow.model_validate(
        {**raw, "payload": _decode_json(raw["payload"].encode(), STAGE_MAX_SOURCE_BYTES)}
    )


def _csv_records(reader, headers):
    while True:
        line = reader.line_num + 1
        try:
            values = next(reader, None)
        except (UnicodeError, csv.Error):
            raise ImportFormatError("invalid_csv") from None
        if values is None:
            return
        if not values:
            continue
        if len(values) != len(headers):
            yield line, {None: values}
        else:
            yield line, dict(zip(headers, values, strict=True))


def _xlsx_records(cells, headers, *, qianji=False, exported=False):
    for line, row in enumerate(cells, 2):
        if len(row) > len(headers) or any(cell.data_type == "f" for cell in row):
            yield line, {None: "workbook_formula_or_extra_columns"}
            continue
        values = []
        for index in range(len(headers)):
            value = row[index].value if index < len(row) else None
            if qianji:
                value = (
                    xlsx_text(headers[index], row[index], export=exported)
                    if index < len(row)
                    else ""
                )
            values.append(value)
        yield line, dict(zip(headers, values, strict=True))


def _sheet_rows(sheet, expected_headers):
    # A worksheet may lie about its dimensions. Iterate actual XML rows and
    # impose the source/row budget ourselves, including auxiliary sheets.
    sheet.reset_dimensions()
    cells = _safe_cells(sheet.iter_rows())
    header = tuple(cell.value for cell in next(cells, ()))
    if header != expected_headers:
        raise ImportFormatError("invalid_columns", row=1)
    return cells


def _safe_cells(cells):
    while True:
        try:
            row = next(cells)
        except StopIteration:
            return
        except (ParseError, DefusedXmlException, BadZipFile, EOFError):
            raise ImportFormatError("invalid_xlsx") from None
        yield row


def _xlsx_hints(book, check_budget):
    if "historical_postings" not in book.sheetnames:
        return {}
    cells = _sheet_rows(book["historical_postings"], ("source_id", "signed_principal_minor"))
    hints = {}
    for position, row in enumerate(cells, 1):
        check_budget()
        if (
            position > STAGE_MAX_ROWS
            or len(row) != 2
            or any(cell.data_type == "f" or not isinstance(cell.value, str) for cell in row)
        ):
            raise ImportFormatError("invalid_historical_postings")
        identifier, signed = (cell.value for cell in row)
        if identifier in hints:
            raise ImportFormatError("duplicate_historical_posting")
        hints[identifier] = {"signed_principal_minor": signed}
    return hints


def _xlsx_manifest(book, check_budget):
    if "attachments" not in book.sheetnames:
        return None
    headers = ("attachment_id", "sha256", "size_bytes", "media_type", "href")
    cells = _sheet_rows(book["attachments"], headers)
    records = []
    for position, row in enumerate(cells, 1):
        check_budget()
        if (
            position > STAGE_MAX_ROWS
            or len(row) != len(headers)
            or any(cell.data_type == "f" for cell in row)
        ):
            raise ImportFormatError("invalid_attachment_manifest")
        records.append(dict(zip(headers, (cell.value for cell in row), strict=True)))
    return _manifest(records)


@contextmanager
def open_stage_source(content, format_name, mapping, *, check_budget):
    """Yield a single-consumption typed reader from verified, bounded bytes.

    All records must be consumed to validate cross-row hints/manifest identity.
    Cooperative callback exceptions deliberately propagate unchanged.
    """
    if (
        not isinstance(content, bytes)
        or not isinstance(mapping, StageMapping)
        or not callable(check_budget)
    ):
        raise TypeError("verified_bytes_closed_mapping_and_budget_required")
    check_budget()
    if not 1 <= len(content) <= STAGE_MAX_SOURCE_BYTES:
        raise ImportFormatError("file_too_large")
    book = None
    export_context = None
    try:
        hints, manifest, namespace = {}, None, mapping.source_namespace
        convert = _native_record
        if format_name == "flowtrace_json":
            value = _decode_json(content, STAGE_MAX_SOURCE_BYTES)
            if isinstance(value, dict) and value.get("format") == "flowtrace-export-v1":
                if (
                    set(value) - {"format", "document", "attachments", "scope_versions", "filter"}
                    or "document" not in value
                ):
                    raise ImportFormatError("invalid_export_envelope")
                manifest = _manifest(value.get("attachments"))
                if manifest is None:
                    raise ImportFormatError("invalid_attachment_manifest")
                value = value["document"]
            if not isinstance(value, dict) or not isinstance(value.get("rows"), list):
                raise ImportFormatError("invalid_document_header")
            header = _header({key: item for key, item in value.items() if key != "rows"})
            namespace, hints = header.source_namespace, header.posting_hints
            records = enumerate(value["rows"], 1)
        elif format_name in {"flowtrace_csv", "qianji_csv"}:
            try:
                reader = csv.reader(
                    io.StringIO(content.decode("utf-8-sig"), newline=""), strict=True
                )
                headers = next(reader, ())
            except (UnicodeError, csv.Error):
                raise ImportFormatError("invalid_csv") from None
            records = _csv_records(reader, headers)
            if format_name == "qianji_csv":

                def records_factory():
                    fresh = csv.reader(
                        io.StringIO(content.decode("utf-8-sig"), newline=""), strict=True
                    )
                    next(fresh, ())
                    return _csv_records(fresh, headers)

            if format_name == "flowtrace_csv":
                if tuple(headers) != HEADERS:
                    raise ImportFormatError("invalid_columns", row=1)
                convert = _table_record
        elif format_name in {"flowtrace_xlsx", "qianji_xlsx"}:
            book = _secure_workbook(content, STAGE_MAX_SOURCE_BYTES, 200 * 1024 * 1024, 2000)
            if format_name == "flowtrace_xlsx":
                if "records" not in book.sheetnames or len(book.sheetnames) > 5:
                    raise ImportFormatError("records_sheet_required")
                records = _xlsx_records(_sheet_rows(book["records"], HEADERS), HEADERS)
                hints, manifest = (
                    _xlsx_hints(book, check_budget),
                    _xlsx_manifest(book, check_budget),
                )
                header = _header(
                    {
                        "format": "flowtrace-data-v1",
                        "source_namespace": namespace,
                        "posting_hints": hints,
                    }
                )
                hints = header.posting_hints
                convert = _table_record
            else:
                if len(book.sheetnames) != 1:
                    raise ImportFormatError("one_template_sheet_required")
                book.active.reset_dimensions()
                cells = _safe_cells(book.active.iter_rows())
                headers = tuple(cell.value for cell in next(cells, ()))
                exported = export_profile(headers)
                records = _xlsx_records(cells, headers, qianji=True, exported=exported)

                def records_factory():
                    fresh = _safe_cells(book.active.iter_rows())
                    next(fresh, ())
                    return _xlsx_records(fresh, headers, qianji=True, exported=exported)
        else:
            raise ImportFormatError("unsupported_import_format")
        if format_name.startswith("qianji_"):
            exported = export_profile(headers)
            if mapping.template_mapping is None:
                raise ImportFormatError("template_mapping_required")
            if exported:
                export_context = prepare_export(
                    records,
                    mapping.template_mapping,
                    max_rows=STAGE_MAX_ROWS,
                    check_budget=check_budget,
                )
                records = records_factory()
            namespace = EXPORT_NAMESPACE if exported else "qianji-public-template-v10"
            file_sha = hashlib.sha256(content).hexdigest()

            def convert(raw, line):
                return (
                    export_context.convert(raw, mapping.template_mapping, line)
                    if export_context is not None
                    else convert_public_record(raw, file_sha, mapping.template_mapping, line)
                )

        yield StageSource(
            namespace,
            hints,
            manifest or [],
            _validated_rows(
                records,
                hints,
                manifest,
                convert,
                check_budget,
                qianji=format_name.startswith("qianji_"),
                table=format_name in {"flowtrace_csv", "flowtrace_xlsx"},
                export_context=export_context,
            ),
        )
    finally:
        if book is not None:
            book.close()
