"""Authenticated data tools; operator backup commands are never exposed here."""

import hashlib
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, File, Form, Query, Request, Response, UploadFile
from pydantic import ValidationError
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool

from flowtrace_server.auth.dependencies import authenticated_request, get_session
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.diagnostics import request_id_context
from flowtrace_server.diagnostics.import_events import record_import_check
from flowtrace_server.sync.canonical import InvalidSyncBody, decode_body
from flowtrace_server.sync.schemas import Identifier

from . import http_schemas as model
from .attachment_sources import read_attachment_sources
from .parsers import (
    MAX_FILE_BYTES,
    ImportFormatError,
    canonical,
    decode_json,
    parse_csv,
    parse_json,
    parse_xlsx,
)
from .qianji_template import inspect_mapping_requirements, parse_qianji_csv, parse_qianji_xlsx
from .schemas import ImportRequest, UndoRequest
from .service import apply_import, import_history, preview_import, preview_undo, undo_import

router = APIRouter(prefix="/api/v1/data-tools", tags=["data-tools"])


def private(response):
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"


async def strict_model(request, expected):
    try:
        return expected.model_validate(decode_body(await request.body()))
    except InvalidSyncBody as error:
        raise ApiError(
            "invalid_import_body", 413 if str(error) == "payload_too_large" else 400
        ) from None
    except ValidationError:
        raise ApiError("validation_error", 422) from None


def parse_file(content, format_name, options):
    if format_name.startswith("qianji_") and options.template_mapping is None:
        raise ApiError("template_mapping_required", 422)
    if not format_name.startswith("qianji_") and options.template_mapping is not None:
        raise ApiError("template_mapping_not_applicable", 422)
    requirements, attachment_sources = [], []
    try:
        if format_name.startswith("qianji_"):
            requirements = inspect_mapping_requirements(content, format_name)
        if format_name == "flowtrace_json":
            document, errors = parse_json(content), []
        else:
            parser = {
                "flowtrace_csv": parse_csv,
                "flowtrace_xlsx": parse_xlsx,
                "qianji_csv": parse_qianji_csv,
                "qianji_xlsx": parse_qianji_xlsx,
            }[format_name]
            argument = (
                options.template_mapping
                if format_name.startswith("qianji_")
                else options.source_namespace
            )
            parsed = parser(content, argument)
            document, errors = parsed.document, list(parsed.errors)
        attachment_sources = read_attachment_sources(content, format_name, document)
    except ImportFormatError as error:
        document, errors = None, [{"row": error.row, "field": error.field, "code": error.code}]
    except ValidationError as error:
        document = None
        errors = []
        for detail in error.errors(include_input=False, include_url=False):
            location = detail["loc"]
            row = (
                location[1] + 1
                if len(location) > 1 and location[0] == "rows" and type(location[1]) is int
                else None
            )
            errors.append(
                {"row": row, "field": ".".join(map(str, location)), "code": detail["type"]}
            )
    result = {
        "format": format_name,
        "source_sha256": hashlib.sha256(content).hexdigest(),
        "document": document,
        "errors": [
            {**error, "field": error["field"][:200] if error.get("field") is not None else None}
            for error in errors
        ],
        "mapping_requirements": requirements,
        "attachment_sources": attachment_sources,
    }
    record_import_check(format_name, errors, count=len(document.rows) if document else 0)
    if options.include_diagnostics and request_id_context.get() is not None:
        result["request_id"] = request_id_context.get()
    result = model.ParseResult.model_validate(result).model_dump(mode="json", exclude_unset=True)
    if len(canonical(result)) > 1024 * 1024:
        raise ApiError("import_response_too_large", 413)
    return result


@router.post(
    "/imports/parse",
    response_model=model.ParseResult,
    response_model_exclude_unset=True,
    operation_id="data_import_parse",
)
async def parse_route(
    request: Request,
    response: Response,
    file: Annotated[UploadFile, File()],
    format: Annotated[model.ImportFileFormat, Form()],
    options: Annotated[str, Form(max_length=65536)] = "{}",
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    if principal.purpose not in {"api_native", "api_web"}:
        raise ApiError("session_purpose_invalid", 403)
    private(response)
    try:
        form = await request.form()
        names = [name for name, _ in form.multi_items()]
        if len(names) != len(set(names)) or set(names) - {"file", "format", "options"}:
            raise ApiError("import_multipart_invalid", 422)
        if len(options.encode("utf-8")) > 65536:
            raise ApiError("import_options_too_large", 413)
        try:
            validated = model.ParseOptions.model_validate(decode_json(options.encode("utf-8")))
        except (ImportFormatError, ValidationError):
            raise ApiError("import_options_invalid", 422) from None
        content = bytearray()
        while chunk := await file.read(65536):
            content.extend(chunk)
            if len(content) > MAX_FILE_BYTES:
                raise ApiError("import_file_too_large", 413)
        return await run_in_threadpool(parse_file, bytes(content), format, validated)
    finally:
        await file.close()


@router.post(
    "/imports/preview", response_model=model.ImportPreview, operation_id="data_import_preview"
)
async def preview_route(
    body: ImportRequest,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    validated = await strict_model(request, ImportRequest)
    private(response)
    return await run_in_threadpool(preview_import, session, principal, validated)


@router.post("/imports/apply", response_model=model.ImportApplied, operation_id="data_import_apply")
async def apply_route(
    body: ImportRequest,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    validated = await strict_model(request, ImportRequest)
    private(response)
    return await run_in_threadpool(apply_import, session, principal, validated)


@router.get(
    "/imports/history", response_model=model.ImportHistory, operation_id="data_import_history"
)
def history_route(
    request: Request,
    response: Response,
    cursor: str | None = Query(default=None, max_length=256),
    limit: int = Query(default=100, ge=1, le=100),
    batch_id: UUID | None = Query(default=None),
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    private(response)
    return import_history(session, principal, cursor=cursor, limit=limit, batch_id=batch_id)


@router.get(
    "/imports/{batch_id}/undo-preview",
    response_model=model.UndoPreview,
    operation_id="data_import_undo_preview",
)
def undo_preview_route(
    batch_id: Identifier,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    private(response)
    return preview_undo(session, principal, UUID(batch_id))


@router.post(
    "/imports/{batch_id}/undo",
    response_model=model.ImportUndone,
    response_model_exclude_unset=True,
    operation_id="data_import_undo",
)
async def undo_route(
    batch_id: Identifier,
    body: UndoRequest,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    validated = await strict_model(request, UndoRequest)
    private(response)
    return await run_in_threadpool(undo_import, session, principal, UUID(batch_id), validated)
