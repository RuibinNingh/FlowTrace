"""Declared original-image hashes for explicit selection, never URL fetching."""

from typing import Literal

from pydantic import Field, ValidationError

from flowtrace_server.sync.schemas import ClosedModel, Identifier

from .parsers import ImportFormatError, decode_json, secure_workbook


class AttachmentSource(ClosedModel):
    source_id: Identifier
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    size_bytes: int = Field(ge=1, le=10 * 1024 * 1024)
    media_type: Literal["image/jpeg", "image/png", "image/webp"]


def read_attachment_sources(content, format_name, document):
    if document is None or format_name not in {"flowtrace_json", "flowtrace_xlsx"}:
        return []
    if format_name == "flowtrace_json":
        envelope = decode_json(content)
        if not isinstance(envelope, dict) or envelope.get("format") != "flowtrace-export-v1":
            return []
        records = envelope.get("attachments")
        if not isinstance(records, list) or len(records) > 1000:
            raise ImportFormatError("invalid_attachment_manifest", field="attachments")
    else:
        book = secure_workbook(content)
        try:
            if "attachments" not in book.sheetnames:
                return []
            sheet = book["attachments"]
            if sheet.max_column != 5 or sheet.max_row > 1001:
                raise ImportFormatError("invalid_attachment_manifest", field="attachments")
            rows = sheet.iter_rows()
            headers = ("attachment_id", "sha256", "size_bytes", "media_type", "href")
            if tuple(cell.value for cell in next(rows, ())) != headers:
                raise ImportFormatError("invalid_attachment_manifest", field="attachments")
            records = []
            for row in rows:
                if any(cell.data_type == "f" for cell in row):
                    raise ImportFormatError("invalid_attachment_manifest", field="attachments")
                records.append(dict(zip(headers, (cell.value for cell in row), strict=True)))
        finally:
            book.close()
    referenced = {
        identifier
        for row in document.rows
        if row.entity_type == "bill"
        for identifier in row.payload.get("attachment_ids", [])
    }
    return validate_attachment_manifest(records, referenced)


def validate_attachment_manifest(records, referenced):
    """Validate declared metadata only; bounded readers own record limits."""
    sources = {}
    try:
        for item in records:
            if not isinstance(item, dict) or set(item) - {
                "attachment_id",
                "sha256",
                "size_bytes",
                "media_type",
                "href",
                "authorization",
            }:
                raise ValueError
            source = AttachmentSource.model_validate(
                {
                    "source_id": item["attachment_id"],
                    "sha256": item["sha256"],
                    "size_bytes": item["size_bytes"],
                    "media_type": item["media_type"],
                }
            )
            if source.source_id in sources or source.source_id not in referenced:
                raise ValueError
            if "href" in item and item["href"] != f"/api/v1/attachments/{source.source_id}/content":
                raise ValueError
            if (
                "authorization" in item
                and item["authorization"] != "current_session_and_scope_required"
            ):
                raise ValueError
            sources[source.source_id] = source.model_dump()
        if set(sources) != referenced:
            raise ValueError
    except (ValueError, TypeError, KeyError, ValidationError):
        raise ImportFormatError("invalid_attachment_manifest", field="attachments") from None
    return [sources[identifier] for identifier in sorted(sources)]
