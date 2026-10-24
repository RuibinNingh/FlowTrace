"""Closed staged-import HTTP boundary mounted by the ordinary main app.

Publication groups and explicit source retention remain separate from financial
confirmation; a queued task is never itself proof of published ledger effects.
"""

from time import monotonic
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Path, Query, Request, Response
from pydantic import ValidationError
from sqlalchemy import select
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool

from flowtrace_server.auth.dependencies import authenticated_request, get_session
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import assert_active_principal, now
from flowtrace_server.diagnostics import request_id_context
from flowtrace_server.sync.schemas import Identifier

from . import staging_schemas as model
from .http_schemas import Digest
from .parsers import ImportFormatError, _decode_json
from .router import private
from .source_release import release_stage_source
from .staging import (
    cancel_stage,
    create_stage,
    put_stage_chunk,
    reauthorize_stage,
    seal_stage,
    stage_status,
    update_stage_mapping,
)
from .staging_discard import discard_stage
from .staging_jobs import stage_jobs
from .staging_models import ImportStage
from .staging_preview import request_stage_preview
from .staging_publish import request_stage_apply, request_stage_undo
from .staging_reauthorization_metadata import stage_reauthorization_metadata
from .staging_reauthorize import reauthorize_published_stage
from .staging_requirements import stage_requirements
from .staging_rows import stage_rows
from .staging_source_books import stage_source_books

router = APIRouter(prefix="/api/v1/data-tools/import-stages", tags=["import-stages"])
MAX_JSON_BYTES = 1024 * 1024
REAUTHORIZE_SECONDS = 5


async def _body(request, expected):
    # Unlike sync protocol object keys, resource-name mappings include Chinese.
    # The same import decoder rejects duplicate keys, NaN, floats, NUL and depth.
    try:
        value = _decode_json(await request.body(), MAX_JSON_BYTES)
        return expected.model_validate(value)
    except ImportFormatError as error:
        raise ApiError(
            "invalid_import_stage_body", 413 if error.code == "file_too_large" else 400
        ) from None
    except ValidationError:
        raise ApiError("validation_error", 422) from None


def _queries(request, allowed=()):
    keys = [key for key, _ in request.query_params.multi_items()]
    if len(keys) != len(set(keys)) or set(keys) - set(allowed):
        raise ApiError("import_stage_query_invalid", 422)


def _reauthorization_budget(session, principal):
    origin = assert_active_principal(session, principal, lock=False)
    stamp = now()
    remaining = min(
        REAUTHORIZE_SECONDS,
        *(
            (value - stamp).total_seconds()
            for value in (origin.access_expires_at, origin.expires_at, origin.idle_expires_at)
        ),
    )
    deadline = monotonic() + max(0, remaining)

    def check_budget():
        if monotonic() >= deadline:
            raise ApiError("import_stage_reauthorization_timeout", 503)

    return check_budget


def _release_source(session, principal, stage_id, body):
    origin = assert_active_principal(session, principal, lock=False)
    stamp = now()
    deadline = monotonic() + max(
        0,
        min(
            REAUTHORIZE_SECONDS,
            *(
                (value - stamp).total_seconds()
                for value in (origin.access_expires_at, origin.expires_at, origin.idle_expires_at)
            ),
        ),
    )

    def check_budget():
        if monotonic() >= deadline:
            raise ApiError("import_stage_source_release_timeout", 503)

    return release_stage_source(session, principal, stage_id, body, check_budget=check_budget)


def _discard(session, principal, stage_id, body):
    # This is the current caller, never the abandoned origin session. A user
    # can explicitly discard their unpublished source after that origin ends.
    current = assert_active_principal(session, principal, lock=False)
    stamp = now()
    deadline = monotonic() + max(
        0,
        min(
            REAUTHORIZE_SECONDS,
            *(
                (value - stamp).total_seconds()
                for value in (
                    current.access_expires_at,
                    current.expires_at,
                    current.idle_expires_at,
                )
            ),
        ),
    )

    def check_budget():
        if monotonic() >= deadline:
            raise ApiError("import_stage_discard_timeout", 503)

    return discard_stage(session, principal, stage_id, body, check_budget=check_budget)


def _reauthorize(session, principal, stage_id, body):
    # This lookup only selects a dispatch. Both services then lock the stage and
    # recheck current owner/origin/version/state/epoch; a racing state conflicts.
    status = session.scalar(
        select(ImportStage.status).where(
            ImportStage.id == stage_id, ImportStage.owner_user_id == principal.user_id
        )
    )
    if status is None:
        raise ApiError("import_stage_not_found", 404)
    if status in {"applied", "undone"}:
        return reauthorize_published_stage(
            session,
            principal,
            stage_id,
            body,
            check_budget=_reauthorization_budget(session, principal),
        )
    return reauthorize_stage(session, principal, stage_id, body)


@router.post("", response_model=model.StageCreated, operation_id="import_stage_create")
async def create_route(
    body: model.StageCreateRequest,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request)
    body = await _body(request, model.StageCreateRequest)
    private(response)
    return await run_in_threadpool(create_stage, session, principal, body)


@router.put(
    "/{stage_id}/chunks/{chunk_index}",
    response_model=model.StageChunkReceipt,
    operation_id="import_stage_upload_chunk",
    openapi_extra={
        "requestBody": {
            "required": True,
            "content": {
                "application/octet-stream": {
                    "schema": {
                        "type": "string",
                        "format": "binary",
                        "maxLength": model.STAGE_CHUNK_BYTES,
                    }
                }
            },
        }
    },
)
async def chunk_route(
    stage_id: Identifier,
    chunk_index: Annotated[int, Path(ge=0, lt=model.STAGE_MAX_CHUNKS)],
    stage_version: Annotated[model.StageVersion, Query()],
    chunk_sha256: Annotated[Digest, Header(alias="X-Chunk-SHA256")],
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request, {"stage_version"})
    if (
        request.headers.get("content-type", "").lower() != "application/octet-stream"
        or len(request.headers.getlist("content-type")) != 1
        or len(request.headers.getlist("x-chunk-sha256")) != 1
    ):
        raise ApiError("import_stage_chunk_headers_invalid", 422)
    content = bytearray()
    async for piece in request.stream():
        if len(content) + len(piece) > model.STAGE_CHUNK_BYTES:
            raise ApiError("import_stage_chunk_too_large", 413)
        content.extend(piece)
    private(response)
    return await run_in_threadpool(
        put_stage_chunk,
        session,
        principal,
        UUID(stage_id),
        stage_version,
        chunk_index,
        bytes(content),
        chunk_sha256,
    )


@router.get(
    "/{stage_id}", response_model=model.StageStatusResponse, operation_id="import_stage_status"
)
async def status_route(
    stage_id: Identifier,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request)
    private(response)
    return await run_in_threadpool(stage_status, session, principal, UUID(stage_id))


@router.get(
    "/{stage_id}/jobs",
    response_model=model.StageJobsMetadata,
    operation_id="import_stage_jobs_metadata",
)
async def jobs_metadata_route(
    stage_id: Identifier,
    stage_version: Annotated[model.StageVersion, Query()],
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request, {"stage_version"})
    private(response)
    return await run_in_threadpool(
        stage_jobs, session, principal, UUID(stage_id), stage_version=stage_version
    )


@router.post(
    "/{stage_id}/seal", response_model=model.StageJobResponse, operation_id="import_stage_seal"
)
async def seal_route(
    stage_id: Identifier,
    body: model.StageSeal,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request)
    body = await _body(request, model.StageSeal)
    private(response)
    return await run_in_threadpool(seal_stage, session, principal, UUID(stage_id), body)


@router.put(
    "/{stage_id}/mapping",
    response_model=model.StageStatusResponse,
    operation_id="import_stage_update_mapping",
)
async def mapping_route(
    stage_id: Identifier,
    body: model.StageMappingUpdate,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request)
    body = await _body(request, model.StageMappingUpdate)
    private(response)
    return await run_in_threadpool(update_stage_mapping, session, principal, UUID(stage_id), body)


@router.post(
    "/{stage_id}/preview",
    response_model=model.StageJobResponse,
    operation_id="import_stage_request_preview",
)
async def preview_route(
    stage_id: Identifier,
    body: model.StageVersionInput,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request)
    body = await _body(request, model.StageVersionInput)
    private(response)
    return await run_in_threadpool(request_stage_preview, session, principal, UUID(stage_id), body)


@router.get(
    "/{stage_id}/rows",
    response_model=model.StageRowsPage,
    response_model_exclude_unset=True,
    operation_id="import_stage_rows",
)
async def rows_route(
    stage_id: Identifier,
    stage_version: Annotated[model.StageVersion, Query()],
    request: Request,
    response: Response,
    cursor: Annotated[str | None, Query(min_length=1, max_length=256)] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 100,
    include_diagnostics: bool = False,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request, {"stage_version", "cursor", "limit", "include_diagnostics"})
    private(response)
    result = await run_in_threadpool(
        stage_rows,
        session,
        principal,
        UUID(stage_id),
        stage_version=stage_version,
        cursor=cursor,
        limit=limit,
    )
    if include_diagnostics:
        result.request_id = request_id_context.get()
    return result


@router.get(
    "/{stage_id}/requirements",
    response_model=model.StageRequirementsPage,
    operation_id="import_stage_requirements",
)
async def requirements_route(
    stage_id: Identifier,
    stage_version: Annotated[model.StageVersion, Query()],
    request: Request,
    response: Response,
    cursor: Annotated[str | None, Query(min_length=1, max_length=512)] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 100,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request, {"stage_version", "cursor", "limit"})
    private(response)
    return await run_in_threadpool(
        stage_requirements,
        session,
        principal,
        UUID(stage_id),
        stage_version=stage_version,
        cursor=cursor,
        limit=limit,
    )


@router.get(
    "/{stage_id}/source-books",
    response_model=model.StageSourceBooksPage,
    operation_id="import_stage_source_books",
)
async def source_books_route(
    stage_id: Identifier,
    stage_version: Annotated[model.StageVersion, Query()],
    request: Request,
    response: Response,
    cursor: Annotated[str | None, Query(min_length=1, max_length=512)] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 100,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request, {"stage_version", "cursor", "limit"})
    private(response)
    return await run_in_threadpool(
        stage_source_books,
        session,
        principal,
        UUID(stage_id),
        stage_version=stage_version,
        cursor=cursor,
        limit=limit,
    )


@router.post(
    "/{stage_id}/apply",
    response_model=model.StageJobResponse,
    operation_id="import_stage_request_apply",
)
async def apply_route(
    stage_id: Identifier,
    body: model.StageApply,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request)
    body = await _body(request, model.StageApply)
    private(response)
    return await run_in_threadpool(request_stage_apply, session, principal, UUID(stage_id), body)


@router.post(
    "/{stage_id}/undo",
    response_model=model.StageJobResponse,
    operation_id="import_stage_request_undo",
)
async def undo_route(
    stage_id: Identifier,
    body: model.StageUndo,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request)
    body = await _body(request, model.StageUndo)
    private(response)
    return await run_in_threadpool(request_stage_undo, session, principal, UUID(stage_id), body)


@router.get(
    "/{stage_id}/reauthorization",
    response_model=model.StageReauthorizationMetadata,
    operation_id="import_stage_reauthorization_metadata",
)
async def reauthorization_metadata_route(
    stage_id: Identifier,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request)
    private(response)
    return await run_in_threadpool(
        stage_reauthorization_metadata, session, principal, UUID(stage_id)
    )


@router.post(
    "/{stage_id}/reauthorize",
    response_model=model.StageStatusResponse,
    operation_id="import_stage_reauthorize",
)
async def reauthorize_route(
    stage_id: Identifier,
    body: model.StageReauthorize,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request)
    body = await _body(request, model.StageReauthorize)
    private(response)
    return await run_in_threadpool(_reauthorize, session, principal, UUID(stage_id), body)


@router.post(
    "/{stage_id}/cancel",
    response_model=model.StageStatusResponse,
    operation_id="import_stage_cancel",
)
async def cancel_route(
    stage_id: Identifier,
    body: model.StageVersionInput,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request)
    body = await _body(request, model.StageVersionInput)
    private(response)
    return await run_in_threadpool(
        cancel_stage, session, principal, UUID(stage_id), body.stage_version
    )


@router.post(
    "/{stage_id}/discard",
    response_model=model.StageStatusResponse,
    operation_id="import_stage_discard",
)
async def discard_route(
    stage_id: Identifier,
    body: model.StageDiscard,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request)
    body = await _body(request, model.StageDiscard)
    private(response)
    return await run_in_threadpool(_discard, session, principal, UUID(stage_id), body)


@router.post(
    "/{stage_id}/source-release",
    response_model=model.StageSourceReleaseReceipt,
    operation_id="import_stage_release_source",
)
async def source_release_route(
    stage_id: Identifier,
    body: model.StageSourceReleaseRequest,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request)
    body = await _body(request, model.StageSourceReleaseRequest)
    private(response)
    return await run_in_threadpool(_release_source, session, principal, UUID(stage_id), body)
