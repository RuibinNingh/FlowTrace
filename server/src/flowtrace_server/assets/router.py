from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request, Response
from sqlalchemy.orm import Session

from flowtrace_server.auth.dependencies import authenticated_request, get_session
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.sync.canonical import InvalidSyncBody, decode_body
from flowtrace_server.sync.schemas import BusinessDate, Identifier

from . import configuration as config
from . import schemas as model
from .catalog import BANKS, PROVIDERS
from .service import read_credit_calendar, read_entries, read_history, read_overview


async def strict_body(request: Request):
    if request.method in {"POST", "PATCH", "PUT", "DELETE"}:
        try:
            decode_body(await request.body())
        except InvalidSyncBody:
            raise ApiError("validation_error", 422) from None


router = APIRouter(prefix="/api/v1/assets", tags=["assets"], dependencies=[Depends(strict_body)])


def private(response):
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"


@router.get("/groups", response_model=model.GroupList, operation_id="asset_groups")
def list_groups(request: Request, response: Response, session: Session = Depends(get_session)):
    principal = authenticated_request(session, request)
    private(response)
    return config.read_configuration(session, principal, config.groups)


@router.post("/groups", response_model=model.GroupMutation, operation_id="asset_group_create")
def create_group(
    body: model.GroupCreate,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    private(response)
    return config.mutate_configuration(session, principal, "groups.create", body)


@router.patch(
    "/groups/{group_id}", response_model=model.GroupMutation, operation_id="asset_group_update"
)
def update_group(
    group_id: Identifier,
    body: model.GroupUpdate,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    private(response)
    return config.mutate_configuration(session, principal, "groups.update", body, UUID(group_id))


@router.delete(
    "/groups/{group_id}", response_model=model.GroupMutation, operation_id="asset_group_delete"
)
def delete_group(
    group_id: Identifier,
    body: model.ConfigCommand,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    private(response)
    return config.mutate_configuration(session, principal, "groups.delete", body, UUID(group_id))


@router.get("/banks", response_model=model.BankList, operation_id="asset_banks")
def banks(
    request: Request,
    response: Response,
    q: str = Query(default="", max_length=80),
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    private(response)
    return config.read_configuration(
        session,
        principal,
        lambda *_: {
            "version": 1,
            "banks": [
                row
                for row in BANKS
                if q.casefold() in row["name"].casefold() or q.casefold() in row["id"]
            ],
        },
    )


@router.get("/providers", response_model=model.ProviderList, operation_id="asset_providers")
def providers(request: Request, response: Response, session: Session = Depends(get_session)):
    principal = authenticated_request(session, request)
    private(response)
    return config.read_configuration(
        session, principal, lambda *_: {"version": 1, "providers": PROVIDERS}
    )


@router.get("/overview", response_model=model.AssetOverview, operation_id="assets_overview")
def overview(
    request: Request,
    response: Response,
    as_of: BusinessDate,
    scope_id: Identifier | None = None,
    base_currency: str | None = None,
    valuation_policy: model.Policy | None = None,
    balance_mode: Literal["current", "as_of"] = "current",
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    private(response)
    return read_overview(
        session,
        principal,
        UUID(scope_id) if scope_id else principal.user_id,
        as_of,
        base_currency,
        valuation_policy,
        balance_mode,
    )


@router.get("/history", response_model=model.AssetHistory, operation_id="assets_history")
def history(
    request: Request,
    response: Response,
    start_date: BusinessDate,
    end_date_exclusive: BusinessDate,
    scope_id: Identifier | None = None,
    base_currency: str | None = None,
    valuation_policy: model.Policy | None = None,
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    private(response)
    return read_history(
        session,
        principal,
        UUID(scope_id) if scope_id else principal.user_id,
        start_date,
        end_date_exclusive,
        base_currency,
        valuation_policy,
    )


@router.get(
    "/accounts/{account_id}/entries",
    response_model=model.AccountEntries,
    operation_id="asset_account_entries",
)
def entries(
    account_id: Identifier,
    request: Request,
    response: Response,
    start_date: BusinessDate,
    end_date_exclusive: BusinessDate,
    offset: int = Query(default=0, ge=0, le=50000),
    limit: int = Query(default=100, ge=1, le=200),
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    private(response)
    return read_entries(
        session, principal, UUID(account_id), start_date, end_date_exclusive, offset, limit
    )


@router.get(
    "/accounts/{account_id}/credit-calendar",
    response_model=model.CreditCalendar,
    operation_id="asset_credit_calendar",
)
def calendar(
    account_id: Identifier,
    request: Request,
    response: Response,
    start_date: BusinessDate,
    end_date_exclusive: BusinessDate,
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    private(response)
    return read_credit_calendar(
        session, principal, UUID(account_id), start_date, end_date_exclusive
    )
