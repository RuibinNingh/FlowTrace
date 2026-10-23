from uuid import UUID

from fastapi import APIRouter, Depends, Request, Response
from sqlalchemy.orm import Session

from flowtrace_server.assets import configuration as config
from flowtrace_server.assets import schemas as model
from flowtrace_server.assets.router import private, strict_body
from flowtrace_server.auth.dependencies import authenticated_request, get_session
from flowtrace_server.sync.schemas import Identifier

from .catalog import currency_catalog

router = APIRouter(
    prefix="/api/v1/currencies", tags=["currencies"], dependencies=[Depends(strict_body)]
)


@router.get("/catalog", response_model=model.CurrencyCatalog, operation_id="currencies_catalog")
def catalog(request: Request, response: Response, session: Session = Depends(get_session)):
    principal = authenticated_request(session, request)
    private(response)
    return config.read_configuration(session, principal, lambda *_: currency_catalog())


@router.get(
    "/preferences", response_model=model.PreferenceResponse, operation_id="currency_preferences"
)
def preferences(request: Request, response: Response, session: Session = Depends(get_session)):
    principal = authenticated_request(session, request)
    private(response)
    return config.read_configuration(session, principal, config.preferences)


@router.put(
    "/preferences",
    response_model=model.PreferenceMutation,
    operation_id="currency_preferences_update",
)
def update_preferences(
    body: model.PreferenceCommand,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    private(response)
    return config.mutate_configuration(session, principal, "preferences.update", body)


@router.get("/rates", response_model=model.RateList, operation_id="valuation_rates")
def rates(request: Request, response: Response, session: Session = Depends(get_session)):
    principal = authenticated_request(session, request)
    private(response)
    return config.read_configuration(session, principal, config.rates)


@router.post("/rates", response_model=model.RateMutation, operation_id="valuation_rate_create")
def create_rate(
    body: model.RateCommand,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    private(response)
    return config.mutate_configuration(session, principal, "rates.create", body)


@router.delete(
    "/rates/{rate_id}", response_model=model.RateMutation, operation_id="valuation_rate_delete"
)
def delete_rate(
    rate_id: Identifier,
    body: model.ConfigCommand,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    private(response)
    return config.mutate_configuration(session, principal, "rates.delete", body, UUID(rate_id))
