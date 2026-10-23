from datetime import timedelta
from typing import Literal
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, Request
from pydantic import Field, field_validator
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from flowtrace_server.admin.service import audit
from flowtrace_server.api.schemas import StrictModel
from flowtrace_server.auth.dependencies import (
    authenticated_request,
    get_session,
)
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import User
from flowtrace_server.auth.service import (
    assert_active_principal,
    digest,
    now,
    secret,
)
from flowtrace_server.books.models import Book, BookInvite, BookMembership, SyncScope
from flowtrace_server.books.permissions import authorize_scope
from flowtrace_server.books.schemas import (
    BookCreated,
    BookInviteResult,
    BookJoined,
    BookList,
    MemberList,
)
from flowtrace_server.domain.money import DomainError
from flowtrace_server.domain.timezone_rules import instant_business_date

router = APIRouter(prefix="/api/v1/books", tags=["books"])


class BookInput(StrictModel):
    id: UUID
    name: str = Field(min_length=1, max_length=80)
    currency: str = Field(default="CNY", pattern="^[A-Z]{3}$")
    timezone: str = "Asia/Shanghai"
    month_start_day: int = Field(default=1, ge=1, le=31)

    @field_validator("name")
    @classmethod
    def valid_name(cls, value: str) -> str:
        if "\x00" in value:
            raise ValueError("text_invalid")
        return value

    @field_validator("timezone")
    @classmethod
    def valid_timezone(cls, value: str) -> str:
        try:
            instant_business_date("2000-01-01T12:00:00Z", value)
        except DomainError:
            raise ValueError("timezone_invalid") from None
        return value


class MemberInviteInput(StrictModel):
    role: Literal["editor", "viewer"] = "viewer"
    days: int = Field(default=7, ge=1, le=30)


class JoinInput(StrictModel):
    token: str = Field(min_length=20, max_length=128)


class MemberRoleInput(StrictModel):
    role: Literal["editor", "viewer"]


def lock_scope_set(session: Session, ids: list[UUID]) -> None:
    rows = list(
        session.scalars(
            select(SyncScope)
            .where(SyncScope.id.in_(set(ids)))
            .order_by(SyncScope.id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
    )
    if len(rows) != len(set(ids)):
        raise ApiError("scope_forbidden", 403)


def change_permission(session: Session, book_id: UUID, user_id: UUID) -> None:
    session.get(SyncScope, book_id).permission_version += 1
    session.get(SyncScope, user_id).permission_version += 1


@router.get("", response_model=BookList)
def list_books(request: Request, session: Session = Depends(get_session)):
    principal = authenticated_request(session, request)
    rows = session.execute(
        select(Book, BookMembership.role)
        .join(BookMembership, Book.id == BookMembership.book_id)
        .where(
            BookMembership.user_id == principal.user_id,
            BookMembership.active.is_(True),
            Book.deleted.is_(False),
        )
        .order_by(Book.created_at)
    ).all()
    return {
        "items": [
            {
                "id": str(book.id),
                "name": book.name,
                "role": role,
                "currency": book.currency,
                "timezone": book.timezone,
                "month_start_day": book.month_start_day,
                "shared": book.shared,
            }
            for book, role in rows
        ]
    }


@router.post("", status_code=201, response_model=BookCreated)
def create_book(body: BookInput, request: Request, session: Session = Depends(get_session)):
    principal = authenticated_request(session, request)
    assert_active_principal(session, principal)
    existing = session.get(Book, body.id)
    if existing:
        if (
            existing.deleted
            or existing.owner_user_id != principal.user_id
            or existing.name != body.name
            or existing.currency != body.currency
            or existing.timezone != body.timezone
            or existing.month_start_day != body.month_start_day
        ):
            raise ApiError("id_conflict", 409)
        return {"id": str(existing.id), "replayed": True}
    if session.get(SyncScope, body.id) is not None:
        raise ApiError("id_conflict", 409)
    book = Book(
        id=body.id,
        name=body.name,
        owner_user_id=principal.user_id,
        shared=False,
        currency=body.currency,
        timezone=body.timezone,
        month_start_day=body.month_start_day,
        created_at=now(),
    )
    try:
        with session.begin_nested():
            session.add(book)
            session.flush()
    except IntegrityError:
        raise ApiError("id_conflict", 409) from None
    session.add_all(
        [
            BookMembership(book_id=book.id, user_id=principal.user_id, role="owner", active=True),
            SyncScope(
                id=book.id,
                kind="book",
                owner_user_id=principal.user_id,
                book_id=book.id,
                revision=0,
                permission_version=1,
            ),
        ]
    )
    lock_scope_set(session, [principal.user_id])
    session.get(SyncScope, principal.user_id).permission_version += 1
    session.flush()
    from flowtrace_server.sync.service import initialize_book_sync

    initialize_book_sync(session, book)
    session.commit()
    return {"id": str(book.id), "replayed": False}


@router.post("/join", response_model=BookJoined)
def join_book(body: JoinInput, request: Request, session: Session = Depends(get_session)):
    principal = authenticated_request(session, request)
    assert_active_principal(session, principal)
    invitation = session.scalar(
        select(BookInvite).where(BookInvite.token_hash == digest(body.token))
    )
    if invitation is None:
        raise ApiError("book_invite_invalid", 422)
    lock_scope_set(session, [invitation.book_id, principal.user_id])
    if session.scalar(select(Book.deleted).where(Book.id == invitation.book_id)) is not False:
        raise ApiError("book_invite_invalid", 422)
    invitation = session.scalar(
        select(BookInvite)
        .where(BookInvite.id == invitation.id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if (
        invitation.revoked_at is not None
        or invitation.expires_at <= now()
        or invitation.consumed_by not in (None, principal.user_id)
    ):
        raise ApiError("book_invite_invalid", 422)
    membership = session.get(BookMembership, (invitation.book_id, principal.user_id))
    if invitation.consumed_by is not None:
        if membership is not None and membership.active:
            return {"book_id": str(invitation.book_id), "role": membership.role, "replayed": True}
        raise ApiError("book_invite_invalid", 422)
    if membership is None:
        membership = BookMembership(
            book_id=invitation.book_id, user_id=principal.user_id, role=invitation.role, active=True
        )
        session.add(membership)
    elif membership.role == "owner":
        raise ApiError("book_already_owned", 409)
    else:
        membership.active = True
        membership.role = invitation.role
    invitation.consumed_by = principal.user_id
    change_permission(session, invitation.book_id, principal.user_id)
    audit(session, principal.user_id, "book.join", invitation.book_id)
    session.commit()
    return {"book_id": str(invitation.book_id), "role": membership.role, "replayed": False}


@router.post("/{book_id}/invites", status_code=201, response_model=BookInviteResult)
def invite_member(
    book_id: UUID,
    body: MemberInviteInput,
    request: Request,
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    assert_active_principal(session, principal)
    grant = authorize_scope(session, principal, book_id, write=True, lock=True)
    if grant.role != "owner":
        raise ApiError("book_owner_required", 403)
    token = secret()
    record = BookInvite(
        id=uuid4(),
        book_id=book_id,
        token_hash=digest(token),
        role=body.role,
        created_by=principal.user_id,
        expires_at=now() + timedelta(days=body.days),
        revoked_at=None,
        consumed_by=None,
    )
    session.add(record)
    session.get(Book, book_id).shared = True
    audit(session, principal.user_id, "book.invite", book_id)
    session.commit()
    return {
        "id": str(record.id),
        "token": token,
        "expires_at": record.expires_at,
        "role": record.role,
    }


@router.get("/{book_id}/members", response_model=MemberList)
def list_members(book_id: UUID, request: Request, session: Session = Depends(get_session)):
    principal = authenticated_request(session, request)
    authorize_scope(session, principal, book_id)
    rows = session.execute(
        select(BookMembership, User.username)
        .join(User, User.id == BookMembership.user_id)
        .where(BookMembership.book_id == book_id, BookMembership.active.is_(True))
    ).all()
    return {
        "items": [
            {"user_id": str(member.user_id), "username": username, "role": member.role}
            for member, username in rows
        ]
    }


def update_membership(
    session: Session, principal, book_id: UUID, user_id: UUID, role: str | None
) -> None:
    assert_active_principal(session, principal)
    lock_scope_set(session, [book_id, user_id])
    grant = authorize_scope(session, principal, book_id, write=True)
    if grant.role != "owner":
        raise ApiError("book_owner_required", 403)
    member = session.get(BookMembership, (book_id, user_id))
    if member is None or not member.active:
        raise ApiError("not_found", 404)
    if member.role == "owner":
        raise ApiError("book_owner_protected", 409)
    if role is None:
        member.active = False
    else:
        member.role = role
    change_permission(session, book_id, user_id)
    audit(session, principal.user_id, "book.member_role" if role else "book.member_remove", user_id)


@router.patch("/{book_id}/members/{user_id}", status_code=204)
def member_role(
    book_id: UUID,
    user_id: UUID,
    body: MemberRoleInput,
    request: Request,
    session: Session = Depends(get_session),
):
    principal = authenticated_request(session, request)
    update_membership(session, principal, book_id, user_id, body.role)
    session.commit()


@router.delete("/{book_id}/members/{user_id}", status_code=204)
def remove_member(
    book_id: UUID, user_id: UUID, request: Request, session: Session = Depends(get_session)
):
    principal = authenticated_request(session, request)
    update_membership(session, principal, book_id, user_id, None)
    session.commit()
