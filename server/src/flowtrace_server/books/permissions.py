from dataclasses import dataclass
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session

from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.books.models import Book, BookMembership, SyncScope


@dataclass(frozen=True)
class ScopeGrant:
    role: str
    scope: SyncScope


def authorize_scope(
    session: Session, principal: Principal, scope_id: UUID, write: bool = False, lock: bool = False
) -> ScopeGrant:
    query = (
        select(SyncScope).where(SyncScope.id == scope_id).execution_options(populate_existing=True)
    )
    if lock:
        query = query.with_for_update()
    scope = session.scalar(query)
    if scope is None:
        raise ApiError("scope_forbidden", 403)
    if scope.kind == "user":
        if scope.owner_user_id != principal.user_id:
            raise ApiError("scope_forbidden", 403)
        return ScopeGrant("owner", scope)
    if session.scalar(select(Book.deleted).where(Book.id == scope.book_id)) is not False:
        raise ApiError("scope_forbidden", 403)
    member = session.scalar(
        select(BookMembership)
        .where(
            BookMembership.book_id == scope.book_id,
            BookMembership.user_id == principal.user_id,
            BookMembership.active.is_(True),
        )
        .execution_options(populate_existing=True)
    )
    if member is None or (write and member.role == "viewer"):
        raise ApiError("scope_forbidden", 403)
    return ScopeGrant(member.role, scope)
