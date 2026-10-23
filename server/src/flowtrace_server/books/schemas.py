from datetime import datetime
from typing import Literal
from uuid import UUID

from flowtrace_server.api.schemas import StrictModel


class BookInfo(StrictModel):
    id: UUID
    name: str
    role: Literal["owner", "editor", "viewer"]
    currency: str
    timezone: str
    month_start_day: int
    shared: bool


class BookList(StrictModel):
    items: list[BookInfo]


class BookCreated(StrictModel):
    id: UUID
    replayed: bool


class BookJoined(StrictModel):
    book_id: UUID
    role: Literal["owner", "editor", "viewer"]
    replayed: bool


class BookInviteResult(StrictModel):
    id: UUID
    token: str
    expires_at: datetime
    role: Literal["editor", "viewer"]


class MemberInfo(StrictModel):
    user_id: UUID
    username: str
    role: Literal["owner", "editor", "viewer"]


class MemberList(StrictModel):
    items: list[MemberInfo]
