"""The six-entity sync HTTP surface. Mounted by the application integrator."""

from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse
from pydantic import ValidationError
from sqlalchemy.orm import Session

from flowtrace_server.auth.dependencies import authenticated_request, get_session
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.diagnostics import request_id_context

from .canonical import InvalidSyncBody, decode_body
from .input import parse_push_body
from .reader import create_snapshot, list_scopes, pull, read_entity, snapshot_page, snapshot_status
from .receipt_lookup import lookup_receipt
from .responses import (
    EntityReadResponse,
    PullResponse,
    PushResponse,
    ScopeResponse,
    SnapshotPageResponse,
    SnapshotStatus,
)
from .schemas import (
    Identifier,
    PullRequest,
    PushRequest,
    ReceiptLookupRequest,
    SnapshotPageRequest,
    SnapshotRequest,
)
from .writer import push_operations

router = APIRouter(prefix="/api/v1/sync", tags=["sync"])


async def _strict_body(request: Request, model):
    try:
        return model.model_validate(decode_body(await request.body()))
    except InvalidSyncBody as error:
        raise ApiError(
            "invalid_sync_body", 413 if str(error) == "payload_too_large" else 400
        ) from None
    except ValidationError:
        raise ApiError("validation_error", 422) from None


@router.get("/scopes", response_model=ScopeResponse)
def scopes_route(request: Request, session: Session = Depends(get_session)):
    principal = authenticated_request(session, request)
    return list_scopes(session, principal)


@router.post("/push", response_model=PushResponse, response_model_exclude_unset=True)
async def push_route(body: PushRequest, request: Request, session: Session = Depends(get_session)):
    principal = authenticated_request(session, request)
    try:
        validated = parse_push_body(await request.body())
    except InvalidSyncBody as error:
        raise ApiError(
            "invalid_sync_body", 413 if str(error) == "payload_too_large" else 400
        ) from None
    except ValidationError:
        raise ApiError("validation_error", 422) from None
    result = push_operations(session, principal, validated)
    if len(result["results"]) == 1 and result["results"][0]["status"] == "rejected":
        rejected = result["results"][0]
        return JSONResponse(
            status_code=rejected["error"]["http_status"],
            content={
                "error": {
                    "code": rejected["error"]["code"],
                    "message": "该操作无法完成",
                    "request_id": request_id_context.get() or "unavailable",
                    "details": {
                        "operation_id": rejected["operation_id"],
                        "current": rejected["error"]["current"],
                    },
                }
            },
        )
    return result


@router.post("/receipts/lookup", response_model=PushResponse, response_model_exclude_unset=True)
async def receipt_lookup_route(
    body: ReceiptLookupRequest, request: Request, session: Session = Depends(get_session)
):
    principal = authenticated_request(session, request)
    await _strict_body(request, ReceiptLookupRequest)
    # Hash the original raw intent, preserving omitted fields and explicit nulls.
    validated = parse_push_body(await request.body())
    return lookup_receipt(session, principal, validated)


@router.post("/pull", response_model=PullResponse, response_model_exclude_unset=True)
async def pull_route(body: PullRequest, request: Request, session: Session = Depends(get_session)):
    principal = authenticated_request(session, request)
    validated = await _strict_body(request, PullRequest)
    return pull(session, principal, validated)


@router.post("/snapshots", response_model=SnapshotStatus, status_code=201)
async def snapshot_create_route(
    body: SnapshotRequest, request: Request, session: Session = Depends(get_session)
):
    principal = authenticated_request(session, request)
    validated = await _strict_body(request, SnapshotRequest)
    return create_snapshot(session, principal, validated)


@router.get("/snapshots/{snapshot_id}", response_model=SnapshotStatus)
def snapshot_status_route(
    snapshot_id: Identifier, request: Request, session: Session = Depends(get_session)
):
    principal = authenticated_request(session, request)
    return snapshot_status(session, principal, UUID(snapshot_id))


@router.post(
    "/snapshots/{snapshot_id}/pages",
    response_model=SnapshotPageResponse,
    response_model_exclude_unset=True,
)
async def snapshot_page_route(
    snapshot_id: Identifier,
    body: SnapshotPageRequest,
    request: Request,
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    validated = await _strict_body(request, SnapshotPageRequest)
    return snapshot_page(session, principal, UUID(snapshot_id), validated)


@router.get(
    "/entities/{entity_type}/{entity_id}",
    response_model=EntityReadResponse,
    response_model_exclude_unset=True,
)
def entity_route(
    entity_type: Literal["book", "account", "category", "tag", "bill", "budget"],
    entity_id: Identifier,
    scope_id: Identifier,
    request: Request,
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    return read_entity(session, principal, entity_type, UUID(entity_id), UUID(scope_id))
