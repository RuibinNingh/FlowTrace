"""Private original-book metadata from persisted valid rows, never source I/O."""

import base64

from pydantic import ValidationError
from sqlalchemy import func, select

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.sync.common import run_transaction
from flowtrace_server.sync.schemas import BookPayload

from .parsers import ImportFormatError, canonical, decode_json, digest
from .schemas import ImportRow
from .staging import _current, _stage
from .staging_models import ImportStageRow
from .staging_schemas import StageMapping, StageSourceBook, StageSourceBooksPage

MAX_PAGE_BYTES = 1024 * 1024


def _cursor(stage, after):
    return (
        base64.urlsafe_b64encode(
            canonical(
                dict(
                    stage_id=str(stage.id),
                    stage_version=stage.stage_version,
                    source_sha256=stage.source_sha256,
                    mapping_hash=digest(
                        StageMapping.model_validate(stage.mapping).model_dump(mode="json")
                    ),
                    requirements_hash=stage.requirements_hash,
                    after=after,
                )
            )
        )
        .rstrip(b"=")
        .decode("ascii")
    )


def _after(stage, cursor):
    if cursor is None:
        return 0
    try:
        value = decode_json(
            base64.b64decode(cursor + "=" * (-len(cursor) % 4), altchars=b"-_", validate=True)
        )
        after = value["after"]
        if (
            type(after) is not int
            or not 1 <= after < stage.row_count
            or cursor != _cursor(stage, after)
        ):
            raise ValueError
        return after
    except (ValueError, TypeError, KeyError, ImportFormatError):
        raise ApiError("import_stage_source_books_cursor_invalid", 422) from None


def stage_source_books(session, principal, stage_id, *, stage_version, cursor=None, limit=100):
    if type(limit) is not int or not 1 <= limit <= 100:
        raise ApiError("import_stage_page_size_invalid", 422)
    if cursor is not None and (not isinstance(cursor, str) or not 1 <= len(cursor) <= 512):
        raise ApiError("import_stage_source_books_cursor_invalid", 422)

    def read():
        state = _current(session, principal)
        stage = _stage(session, principal, stage_id, state, version=stage_version)
        if stage.source_released_at is not None:
            raise ApiError("import_stage_source_released", 410)
        if stage.status not in {"parsed", "ready", "applied", "undone", "failed"}:
            raise ApiError("import_stage_source_books_unavailable", 409)
        after = _after(stage, cursor)
        predicates = (
            ImportStageRow.stage_id == stage.id,
            ImportStageRow.parsed_version == stage.stage_version,
            ImportStageRow.row_payload["entity_type"].astext == "book",
        )
        count = session.scalar(select(func.count()).select_from(ImportStageRow).where(*predicates))
        values = list(
            session.scalars(
                select(ImportStageRow)
                .where(*predicates, ImportStageRow.position > after)
                .order_by(ImportStageRow.position)
                .limit(limit + 1)
            )
        )
        items, size = [], 0
        for value in values[:limit]:
            try:
                row = ImportRow.model_validate(value.row_payload)
                book = BookPayload.model_validate(row.payload)
                if row.entity_type != "book" or row.source_id != str(value.source_id):
                    raise ValueError
                item = StageSourceBook(
                    position=value.position,
                    source_id=row.source_id,
                    name=book.name,
                    currency=book.currency,
                    timezone=book.timezone,
                )
            except (ValidationError, ValueError):
                raise ApiError("import_stage_source_books_changed", 409) from None
            encoded = len(canonical(item.model_dump(mode="json"))) + 1
            if size + encoded > MAX_PAGE_BYTES - 2048:
                if not items:
                    raise ApiError("import_stage_source_books_response_too_large", 422)
                break
            items.append(item)
            size += encoded
        has_more = len(values) > len(items)
        result = StageSourceBooksPage(
            stage_id=str(stage.id),
            stage_version=stage.stage_version,
            count=count,
            items=items,
            has_more=has_more,
            next_cursor=_cursor(stage, items[-1].position) if has_more else None,
        )
        if len(canonical(result.model_dump(mode="json"))) > MAX_PAGE_BYTES:
            raise ApiError("import_stage_source_books_response_too_large", 422)
        return result

    return run_transaction(session, read)
