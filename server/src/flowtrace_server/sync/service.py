"""Stable integration helpers; sync transactions never commit their caller's setup."""

from sqlalchemy.orm import Session

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import now
from flowtrace_server.books.models import Book

from .common import CURRENCY_SCALES, PendingEvent, current_entity, lock_scopes, write_changes
from .models import SyncEntity
from .schemas import BookPayload


def initialize_book_sync(
    session: Session,
    book: Book,
    *,
    emit_change: bool = True,
    locked_scopes: dict | None = None,
) -> SyncEntity:
    """Call after Book + membership + user/book scopes are flushed, before commit.

    Runtime creation is revision 1 with a formal book-domain change. Existing
    migrated books retain their revision-zero snapshot baseline. No commit is
    issued here: invitation consumption, identity and this event stay atomic.
    """
    session.flush()
    existing = current_entity(session, book.id)
    if existing is not None:
        if existing.entity_type != "book" or existing.scope_id != book.id:
            raise ApiError("id_conflict", 409)
        return existing
    if book.currency not in CURRENCY_SCALES:
        raise ApiError("currency.unsupported", 422)
    payload = BookPayload.model_validate(
        {
            "name": book.name,
            "currency": book.currency,
            "timezone": book.timezone,
            "month_start_day": book.month_start_day,
        }
    ).model_dump()
    scopes = locked_scopes or lock_scopes(session, {book.id, book.owner_user_id})
    stamp = now()
    entity = SyncEntity(
        id=book.id,
        scope_id=book.id,
        entity_type="book",
        revision=1,
        deleted=False,
        payload=payload,
        balance_minor=None,
        created_at=book.created_at,
        updated_at=stamp,
    )
    session.add(entity)
    session.flush()
    if emit_change:
        write_changes(
            session,
            scopes,
            [
                PendingEvent(
                    book.id,
                    "book",
                    book.id,
                    1,
                    False,
                    {"projection_kind": "book", "payload": payload},
                )
            ],
        )
    return entity
