import secrets
from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Depends, Request, Response
from pydantic import Field, field_validator
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from flowtrace_server.api.schemas import StrictModel
from flowtrace_server.auth.dependencies import (
    authenticated_request,
    get_session,
)
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import User, UserSession
from flowtrace_server.auth.schemas import LoginTokens, RefreshTokens, SessionList, UserInfo
from flowtrace_server.auth.service import (
    assert_active_principal,
    digest,
    issue_session,
    now,
    refresh_session,
    register,
    verify_password,
)

router = APIRouter(prefix="/api/v1", tags=["identity"])


class LoginInput(StrictModel):
    username: str = Field(min_length=3, max_length=64, pattern=r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
    password: str = Field(min_length=12, max_length=256)
    client_id: UUID
    device_name: str = Field(default="设备", max_length=80)
    client_kind: Literal["native", "web"] = "native"

    @field_validator("username")
    @classmethod
    def normalize_username(cls, value: str) -> str:
        return value.lower()

    @field_validator("device_name")
    @classmethod
    def valid_device_name(cls, value: str) -> str:
        if "\x00" in value:
            raise ValueError("text_invalid")
        return value


class RegisterInput(LoginInput):
    invite_token: str = Field(min_length=20, max_length=128)


class RefreshInput(StrictModel):
    refresh_token: str | None = Field(default=None, max_length=128)
    client_kind: Literal["native", "web"] = "native"


def require_origin(request: Request) -> None:
    allowed = {str(request.base_url).rstrip("/"), *request.app.state.settings.cors_origins}
    if request.headers.get("origin") not in allowed:
        raise ApiError("origin_invalid", 403)


def web_result(request: Request, response: Response, tokens: dict) -> dict:
    secure = request.app.state.settings.environment == "production"
    response.set_cookie(
        "flowtrace_refresh",
        tokens["refresh_token"],
        max_age=30 * 86400,
        httponly=True,
        secure=secure,
        samesite="strict",
        path="/api/v1/auth",
    )
    csrf = tokens.get("csrf_token")
    if csrf:
        response.set_cookie(
            "flowtrace_web_csrf",
            csrf,
            max_age=30 * 86400,
            httponly=False,
            secure=secure,
            samesite="strict",
            path="/",
        )
    return {key: value for key, value in tokens.items() if key != "refresh_token"}


@router.post(
    "/auth/register", status_code=201, response_model=LoginTokens, response_model_exclude_none=True
)
def registration(
    body: RegisterInput,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    if body.client_kind == "web":
        require_origin(request)
    try:
        user = register(session, body.username, body.password, body.invite_token)
        _, tokens = issue_session(
            session,
            user,
            body.client_id,
            body.device_name,
            "api_web" if body.client_kind == "web" else "api_native",
        )
        session.commit()
    except IntegrityError:
        session.rollback()
        raise ApiError("username_unavailable", 409) from None
    return web_result(request, response, tokens) if body.client_kind == "web" else tokens


@router.post("/auth/login", response_model=LoginTokens, response_model_exclude_none=True)
def login(
    body: LoginInput, request: Request, response: Response, session: Session = Depends(get_session)
):
    if body.client_kind == "web":
        require_origin(request)
    user = verify_password(session, body.username, body.password)
    _, tokens = issue_session(
        session,
        user,
        body.client_id,
        body.device_name,
        "api_web" if body.client_kind == "web" else "api_native",
    )
    session.commit()
    return web_result(request, response, tokens) if body.client_kind == "web" else tokens


@router.post("/auth/refresh", response_model=RefreshTokens, response_model_exclude_none=True)
def refresh(
    body: RefreshInput,
    request: Request,
    response: Response,
    session: Session = Depends(get_session),
):
    web = body.client_kind == "web"
    if web:
        require_origin(request)
    raw = request.cookies.get("flowtrace_refresh") if web else body.refresh_token
    if not raw:
        raise ApiError("session_invalid", 401)
    tokens = refresh_session(session, raw, web, request.headers.get("x-csrf-token"))
    session.commit()
    return web_result(request, response, tokens) if web else tokens


@router.post("/auth/logout", status_code=204)
def logout(request: Request, response: Response, session: Session = Depends(get_session)):
    principal = authenticated_request(session, request)
    record = assert_active_principal(session, principal)
    if principal.purpose == "api_web":
        require_origin(request)
        csrf = request.headers.get("x-csrf-token", "")
        if not secrets.compare_digest(digest(csrf), record.csrf_hash):
            raise ApiError("csrf_invalid", 403)
    record.revoked_at = now()
    session.commit()
    response.delete_cookie("flowtrace_refresh", path="/api/v1/auth")
    response.delete_cookie("flowtrace_web_csrf", path="/")


@router.get("/users/me", response_model=UserInfo)
def me(request: Request, session: Session = Depends(get_session)):
    principal = authenticated_request(session, request)
    user = session.get(User, principal.user_id)
    return {"id": str(user.id), "username": user.username, "enabled": user.enabled}


@router.get("/sessions", response_model=SessionList)
def list_sessions(request: Request, session: Session = Depends(get_session)):
    principal = authenticated_request(session, request)
    return {
        "items": [
            {
                "id": str(record.id),
                "device_name": record.device_name,
                "created_at": record.created_at,
                "expires_at": record.expires_at,
                "revoked": record.revoked_at is not None,
            }
            for record in session.scalars(
                select(UserSession)
                .where(UserSession.user_id == principal.user_id, UserSession.purpose != "admin")
                .order_by(UserSession.created_at)
            )
        ]
    }


@router.delete("/sessions/{session_id}", status_code=204)
def revoke_session(session_id: UUID, request: Request, session: Session = Depends(get_session)):
    principal = authenticated_request(session, request)
    assert_active_principal(session, principal)
    record = session.scalar(
        select(UserSession)
        .where(UserSession.id == session_id, UserSession.user_id == principal.user_id)
        .with_for_update()
    )
    if record is None:
        raise ApiError("not_found", 404)
    record.revoked_at = now()
    session.commit()
