"""Bounded group-sync-v1 HTTP boundary, negotiated through server-info."""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Request, Response
from pydantic import Field, ValidationError
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool

from flowtrace_server.auth.dependencies import authenticated_request, get_session
from flowtrace_server.auth.errors import ApiError

from .canonical import InvalidSyncBody, decode_body
from .group_schemas import (
    GroupDataPage,
    GroupPullCreate,
    GroupPullDiscard,
    GroupPullDiscarded,
    GroupPullListing,
    GroupPullPageRequest,
    GroupPullStatus,
    GroupPullStep,
    GroupUnitIndexPage,
    GroupUnitManifestPage,
)
from .group_service import (
    create_group_pull,
    discard_group_pull,
    group_pull_status,
    list_group_pulls,
    read_group_pull_page,
    step_group_pull,
)
from .schemas import Identifier

router = APIRouter(prefix="/api/v1/sync/group-pulls", tags=["group-sync"])
MAX_BODY_BYTES = 1024 * 1024
GroupPage = Annotated[
    GroupUnitIndexPage | GroupUnitManifestPage | GroupDataPage, Field(discriminator="kind")
]


def _body_schema(model):
    # No automatic FastAPI Body parameter: it would read the entire body before
    # the streaming bound below. These closed DTO schemas contain no $refs.
    return {
        "requestBody": {
            "required": True,
            "content": {"application/json": {"schema": model.model_json_schema(mode="validation")}},
        }
    }


async def _strict_body(request, model):
    if (
        len(request.headers.getlist("content-type")) != 1
        or request.headers.get("content-type", "").split(";", 1)[0].strip().lower()
        != "application/json"
    ):
        raise ApiError("group_content_type_invalid", 415)
    value = bytearray()
    async for chunk in request.stream():
        if len(value) + len(chunk) > MAX_BODY_BYTES:
            raise ApiError("invalid_group_body", 413)
        value.extend(chunk)
    try:
        return model.model_validate(decode_body(bytes(value), MAX_BODY_BYTES))
    except InvalidSyncBody as error:
        raise ApiError(
            "invalid_group_body", 413 if str(error) == "payload_too_large" else 400
        ) from None
    except ValidationError:
        raise ApiError("validation_error", 422) from None


def _queries(request, allowed=()):
    keys = [key for key, _ in request.query_params.multi_items()]
    if len(keys) != len(set(keys)) or set(keys) - set(allowed):
        raise ApiError("group_query_invalid", 422)


def _private(response):
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"


@router.get("", response_model=GroupPullListing, operation_id="group_pull_list")
def list_route(request: Request, response: Response, session: Session = Depends(get_session)):
    principal = authenticated_request(session, request)
    _queries(request)
    _private(response)
    return list_group_pulls(session, principal)


@router.post(
    "",
    response_model=GroupPullStatus,
    status_code=201,
    operation_id="group_pull_create",
    openapi_extra=_body_schema(GroupPullCreate),
)
async def create_route(
    request: Request, response: Response, session: Session = Depends(get_session)
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request)
    body = await _strict_body(request, GroupPullCreate)
    _private(response)
    return await run_in_threadpool(create_group_pull, session, principal, body)


@router.get("/{pull_id}", response_model=GroupPullStatus, operation_id="group_pull_status")
def status_route(
    pull_id: Identifier,
    client_id: Identifier,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    _queries(request, {"client_id"})
    _private(response)
    return group_pull_status(session, principal, UUID(pull_id), client_id=client_id)


@router.post(
    "/{pull_id}/steps",
    response_model=GroupPullStatus,
    operation_id="group_pull_step",
    openapi_extra=_body_schema(GroupPullStep),
)
async def step_route(
    pull_id: Identifier,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request)
    body = await _strict_body(request, GroupPullStep)
    _private(response)
    return await run_in_threadpool(step_group_pull, session, principal, UUID(pull_id), body)


@router.post(
    "/{pull_id}/pages",
    response_model=GroupPage,
    response_model_exclude_unset=True,
    operation_id="group_pull_page",
    openapi_extra=_body_schema(GroupPullPageRequest),
)
async def page_route(
    pull_id: Identifier,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request)
    body = await _strict_body(request, GroupPullPageRequest)
    _private(response)
    return await run_in_threadpool(read_group_pull_page, session, principal, UUID(pull_id), body)


@router.post(
    "/{pull_id}/discard",
    response_model=GroupPullDiscarded,
    operation_id="group_pull_discard",
    openapi_extra=_body_schema(GroupPullDiscard),
)
async def discard_route(
    pull_id: Identifier,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = await run_in_threadpool(authenticated_request, session, request)
    _queries(request)
    body = await _strict_body(request, GroupPullDiscard)
    if body.client_id != str(principal.client_id):
        raise ApiError("client_mismatch", 403)
    _private(response)
    return await run_in_threadpool(discard_group_pull, session, principal, UUID(pull_id))
