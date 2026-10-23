from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import Field

from flowtrace_server.api.schemas import StrictModel


class RefreshTokens(StrictModel):
    access_token: str
    refresh_token: str | None = None
    token_type: Literal["bearer"]
    expires_in: int = Field(ge=1)
    session_id: UUID
    user_id: UUID


class LoginTokens(RefreshTokens):
    csrf_token: str


class UserInfo(StrictModel):
    id: UUID
    username: str
    enabled: bool


class SessionInfo(StrictModel):
    id: UUID
    device_name: str
    created_at: datetime
    expires_at: datetime
    revoked: bool


class SessionList(StrictModel):
    items: list[SessionInfo]
