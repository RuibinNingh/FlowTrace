from dataclasses import dataclass
from uuid import UUID

from fastapi import Depends, Request
from sqlalchemy.orm import Session

from flowtrace_server.api.errors import ServiceUnavailable
from flowtrace_server.auth.errors import ApiError


@dataclass(frozen=True)
class Principal:
    user_id: UUID
    session_id: UUID
    client_id: UUID
    purpose: str
    roles: frozenset[str]


def get_session(request: Request):
    engine = request.app.state.engine
    if engine is None:
        raise ServiceUnavailable
    with Session(engine, expire_on_commit=False) as session:
        yield session


def access_from_request(request: Request) -> str:
    value = request.headers.get("authorization", "")
    if not value.startswith("Bearer ") or len(value) > 256:
        raise ApiError("authentication_required", 401)
    return value[7:]


def get_principal(request: Request, session: Session = Depends(get_session)) -> Principal:
    return authenticated_request(session, request)


def authenticated_request(session: Session, request: Request) -> Principal:
    import secrets

    from flowtrace_server.auth.models import UserSession
    from flowtrace_server.auth.router import require_origin
    from flowtrace_server.auth.service import authenticate_access, digest

    principal = authenticate_access(session, access_from_request(request))
    if principal.purpose == "api_web" and request.method not in {"GET", "HEAD", "OPTIONS"}:
        require_origin(request)
        supplied = request.headers.get("x-csrf-token", "")
        record = session.get(UserSession, principal.session_id)
        if not supplied or not secrets.compare_digest(digest(supplied), record.csrf_hash):
            raise ApiError("csrf_invalid", 403)
    return principal
