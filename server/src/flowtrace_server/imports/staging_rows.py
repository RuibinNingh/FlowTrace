"""Private stage-version keyset pages; parsed is not a domain preview."""

import base64

from sqlalchemy import select

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.sync.common import run_transaction

from .parsers import canonical, decode_json
from .staging import _current, _stage
from .staging_models import ImportStageRow
from .staging_schemas import StageRowPreview, StageRowsPage

MAX_PAGE_BYTES = 1024 * 1024


def _cursor(stage, position):
    return (
        base64.urlsafe_b64encode(
            canonical(
                {"stage_id": str(stage.id), "stage_version": stage.stage_version, "after": position}
            )
        )
        .rstrip(b"=")
        .decode("ascii")
    )


def _after(stage, cursor):
    if cursor is None:
        return 0
    try:
        if not isinstance(cursor, str) or not 1 <= len(cursor) <= 256:
            raise ValueError
        value = decode_json(
            base64.b64decode(cursor + "=" * (-len(cursor) % 4), altchars=b"-_", validate=True)
        )
        if (
            not isinstance(value, dict)
            or set(value) != {"stage_id", "stage_version", "after"}
            or value["stage_id"] != str(stage.id)
            or type(value["stage_version"]) is not int
            or value["stage_version"] != stage.stage_version
            or type(value["after"]) is not int
            or not 1 <= value["after"] <= stage.row_count
            or cursor != _cursor(stage, value["after"])
        ):
            raise ValueError
        return value["after"]
    except (ValueError, TypeError):
        raise ApiError("import_stage_cursor_invalid", 422) from None


def stage_rows(session, principal, stage_id, *, stage_version, cursor=None, limit=100):
    """Current real owner/origin/epoch only; no private operation-history exception."""
    if type(limit) is not int or not 1 <= limit <= 100:
        raise ApiError("import_stage_page_size_invalid", 422)

    def read():
        state = _current(session, principal)
        stage = _stage(session, principal, stage_id, state, version=stage_version)
        if stage.source_released_at is not None:
            raise ApiError("import_stage_source_released", 410)
        if stage.status not in {"parsed", "ready", "applied", "undone", "failed"}:
            raise ApiError("import_stage_rows_unavailable", 409)
        after = _after(stage, cursor)
        values = list(
            session.scalars(
                select(ImportStageRow)
                .where(
                    ImportStageRow.stage_id == stage.id,
                    ImportStageRow.parsed_version == stage.stage_version,
                    ImportStageRow.position > after,
                )
                .order_by(ImportStageRow.position)
                .limit(limit + 1)
            )
        )
        rows, size = [], 0
        for value in values[:limit]:
            row = StageRowPreview(
                position=value.position,
                source_line=value.source_line,
                source_id=str(value.source_id) if value.source_id else None,
                row=value.row_payload,
                target_entity_id=str(value.target_entity_id) if value.target_entity_id else None,
                status=value.preview_status or "parsed",
                warning=value.preview_warning,
                errors=value.errors,
            )
            row_bytes = len(canonical(row.model_dump(mode="json"))) + 1
            # Return a shorter explicit page instead of truncating records or
            # exceeding the current normal client's JSON transport budget.
            if size + row_bytes > MAX_PAGE_BYTES - 1024:
                if not rows:
                    raise ApiError("import_stage_row_response_too_large", 422)
                break
            rows.append(row)
            size += row_bytes
        has_more = len(values) > len(rows)
        result = StageRowsPage(
            stage_id=str(stage.id),
            stage_version=stage.stage_version,
            rows=rows,
            has_more=has_more,
            next_cursor=_cursor(stage, rows[-1].position) if has_more else None,
        )
        if len(canonical(result.model_dump(mode="json"))) > MAX_PAGE_BYTES:
            raise ApiError("import_stage_page_response_too_large", 422)
        return result

    return run_transaction(session, read)
