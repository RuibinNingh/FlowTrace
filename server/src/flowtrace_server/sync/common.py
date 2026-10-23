"""Small shared transaction primitives; no route or application startup side effects."""

from collections import defaultdict
from dataclasses import dataclass
from datetime import timedelta
from uuid import UUID, uuid4

from sqlalchemy import select, text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.orm import Session

from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import assert_active_principal, now
from flowtrace_server.books.models import Book, BookMembership, SyncScope
from flowtrace_server.books.permissions import authorize_scope
from flowtrace_server.currencies.catalog import CURRENCY_SCALES
from flowtrace_server.domain.money import Money, checked_minor
from flowtrace_server.persistence.models import ServerState

from .models import SyncChange, SyncClient, SyncEntity

DEVICE_DAYS = 90
PAGE_MINUTES = 15
MAX_COMMIT_EVENTS = 200
MAX_PULL_EVENTS = 50000
MAX_SNAPSHOT_ITEMS = 200000
MAX_PAGES = 1000
MATERIALIZE_SECONDS = 10


class CommandRejected(Exception):
    def __init__(self, code: str, status: int = 422):
        self.code, self.status = code, status


class RetryScopeSet(Exception):
    """A pre-lock reference changed. Retry without acquiring out-of-order locks."""


@dataclass(frozen=True)
class PendingEvent:
    scope_id: UUID
    entity_type: str
    entity_id: UUID
    revision: int
    deleted: bool
    data: dict | None


def checked_currency(money: dict) -> Money:
    amount = Money.from_json(money)
    if CURRENCY_SCALES.get(amount.currency) != amount.currency_scale:
        raise CommandRejected("currency.unsupported_or_scale")
    return amount


def lock_scopes(session: Session, ids: set[UUID]) -> dict[UUID, SyncScope]:
    rows = list(
        session.scalars(
            select(SyncScope)
            .where(SyncScope.id.in_(ids))
            .order_by(SyncScope.id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
    )
    if len(rows) != len(ids):
        raise ApiError("scope_forbidden", 403)
    return {row.id: row for row in rows}


def visible_scopes(session: Session, principal: Principal) -> list[SyncScope]:
    books = (
        select(BookMembership.book_id)
        .join(Book, Book.id == BookMembership.book_id)
        .where(
            BookMembership.user_id == principal.user_id,
            BookMembership.active.is_(True),
            Book.deleted.is_(False),
        )
    )
    return list(
        session.scalars(
            select(SyncScope)
            .where((SyncScope.id == principal.user_id) | SyncScope.book_id.in_(books))
            .order_by(SyncScope.id)
        )
    )


def require_current_client(
    session: Session,
    principal: Principal,
    epoch: str | None = None,
    client_id: str | None = None,
    *,
    rebuild_read: bool = False,
) -> tuple[ServerState, SyncClient]:
    assert_active_principal(session, principal, lock=True)
    if principal.purpose not in {"api_native", "api_web"}:
        raise ApiError("session_purpose_invalid", 403)
    if client_id is not None and UUID(client_id) != principal.client_id:
        raise ApiError("client_mismatch", 403)
    state = session.scalar(select(ServerState).with_for_update(read=True))
    if state is None:
        raise ApiError("service_unavailable", 503)
    if epoch is not None and UUID(epoch) != state.sync_epoch:
        raise ApiError("epoch_changed", 409)
    client = session.get(SyncClient, (principal.user_id, principal.client_id))
    stamp = now()
    if client is None:
        client = SyncClient(
            user_id=principal.user_id,
            client_id=principal.client_id,
            sync_epoch=state.sync_epoch,
            valid_until=stamp + timedelta(days=DEVICE_DAYS),
            last_seen_at=stamp,
            frozen=False,
            known_scope_ids=[],
        )
        session.add(client)
        session.flush()
    expired = client.frozen or client.valid_until <= stamp or client.sync_epoch != state.sync_epoch
    if expired and not rebuild_read:
        raise ApiError("resync_required", 410)
    if expired:
        client.frozen = True
    else:
        client.last_seen_at = stamp
        client.valid_until = stamp + timedelta(days=DEVICE_DAYS)
    return state, client


def current_entity(session: Session, identifier: UUID) -> SyncEntity | None:
    return session.scalar(
        select(SyncEntity)
        .where(SyncEntity.id == identifier)
        .execution_options(populate_existing=True)
    )


def visible_entity(
    session: Session,
    principal: Principal,
    identifier: UUID,
    entity_type: str | None = None,
    *,
    active: bool = True,
) -> SyncEntity:
    entity = current_entity(session, identifier)
    if (
        entity is None
        or (active and entity.deleted)
        or (entity_type is not None and entity.entity_type != entity_type)
    ):
        raise ApiError("not_found", 404)
    try:
        authorize_scope(session, principal, entity.scope_id)
    except ApiError:
        raise ApiError("not_found", 404) from None
    return entity


def write_changes(
    session: Session,
    scopes: dict[UUID, SyncScope],
    events: list[PendingEvent],
    commit_id: UUID | None = None,
) -> tuple[str, dict[str, str]]:
    if not 1 <= len(events) <= MAX_COMMIT_EVENTS:
        raise CommandRejected("commit_too_large")
    groups = defaultdict(list)
    for event in events:
        if event.scope_id not in scopes:
            raise RetryScopeSet
        groups[event.scope_id].append(event)
    commit_id, stamp = commit_id or uuid4(), now()
    revisions = {}
    for scope_id in sorted(groups):
        scope = scopes[scope_id]
        scope.revision = checked_minor(scope.revision + 1)
        revisions[str(scope_id)] = str(scope.revision)
        ordered = sorted(groups[scope_id], key=lambda e: (e.entity_type, e.entity_id.hex))
        for index, event in enumerate(ordered):
            session.add(
                SyncChange(
                    scope_id=scope_id,
                    scope_revision=scope.revision,
                    event_index=index,
                    commit_id=commit_id,
                    entity_type=event.entity_type,
                    entity_id=event.entity_id,
                    revision=event.revision,
                    deleted=event.deleted,
                    data=event.data,
                    created_at=stamp,
                )
            )
    session.flush()
    return str(commit_id), revisions


def run_transaction(session: Session, callback, *, repeatable: bool = False):
    """Discard authentication reads, then retry only transaction-safe failures."""
    session.rollback()
    for attempt in range(3):
        try:
            if repeatable:
                session.connection(execution_options={"isolation_level": "REPEATABLE READ"})
            else:
                session.begin()
            session.execute(text("SET LOCAL statement_timeout = '10000ms'"))
            session.execute(text("SET LOCAL lock_timeout = '3000ms'"))
            result = callback()
            session.commit()
            return result
        except RetryScopeSet:
            session.rollback()
            if attempt == 2:
                raise ApiError("sync_busy", 503) from None
        except DBAPIError as error:
            session.rollback()
            code = getattr(error.orig, "sqlstate", None)
            if code in {"40001", "40P01", "55P03", "23505"} and attempt < 2:
                continue
            raise ApiError("sync_unavailable", 503) from None
        except Exception:
            session.rollback()
            raise
