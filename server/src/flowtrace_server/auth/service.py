import hashlib
import secrets
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

from pwdlib import PasswordHash
from sqlalchemy import select
from sqlalchemy.orm import Session

from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import AdminRole, Invite, RefreshToken, User, UserSession
from flowtrace_server.books.models import Book, BookMembership, SyncScope

PASSWORDS = PasswordHash.recommended()
DUMMY_HASH = PASSWORDS.hash("FlowTrace-dummy-verification-password")


def now() -> datetime:
    return datetime.now(UTC)


def digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def secret() -> str:
    return secrets.token_urlsafe(32)


def roles_for(session: Session, user_id: UUID) -> frozenset[str]:
    return frozenset(session.scalars(select(AdminRole.role).where(AdminRole.user_id == user_id)))


def create_user(session: Session, username: str, password: str) -> User:
    user = User(
        id=uuid4(),
        username=username,
        password_hash=PASSWORDS.hash(password),
        enabled=True,
        created_at=now(),
    )
    session.add(user)
    session.flush()
    book = Book(id=uuid4(), name="默认账本", owner_user_id=user.id, shared=False, created_at=now())
    session.add(book)
    session.flush()
    session.add_all(
        [
            BookMembership(book_id=book.id, user_id=user.id, role="owner", active=True),
            SyncScope(
                id=user.id,
                kind="user",
                owner_user_id=user.id,
                book_id=None,
                revision=0,
                permission_version=1,
            ),
            SyncScope(
                id=book.id,
                kind="book",
                owner_user_id=user.id,
                book_id=book.id,
                revision=0,
                permission_version=1,
            ),
        ]
    )
    session.flush()
    from flowtrace_server.sync.service import initialize_book_sync

    initialize_book_sync(session, book)
    return user


def register(session: Session, username: str, password: str, invite_token: str) -> User:
    from flowtrace_server.configuration.runtime import require_registration_enabled

    require_registration_enabled(session)
    invitation = session.scalar(
        select(Invite).where(Invite.token_hash == digest(invite_token)).with_for_update()
    )
    if (
        invitation is None
        or invitation.revoked_at is not None
        or invitation.consumed_by is not None
        or invitation.expires_at <= now()
    ):
        raise ApiError("invite_invalid", 422)
    if session.scalar(select(User.id).where(User.username == username)) is not None:
        raise ApiError("username_unavailable", 409)
    user = create_user(session, username, password)
    invitation.consumed_by = user.id
    return user


def verify_password(session: Session, username: str, password: str, admin: bool = False) -> User:
    user = session.scalar(select(User).where(User.username == username).with_for_update())
    valid = PASSWORDS.verify(password, user.password_hash if user else DUMMY_HASH)
    if user is None or not valid or not user.enabled:
        raise ApiError("invalid_credentials", 401)
    if admin and not roles_for(session, user.id).intersection(
        {"service_admin", "recovery_admin", "server_owner"}
    ):
        raise ApiError("admin_forbidden", 403)
    return user


def issue_session(
    session: Session, user: User, client_id: UUID, device_name: str, purpose: str
) -> tuple[UserSession, dict]:
    stamp = now()
    access, refresh, csrf = secret(), secret(), secret()
    admin = purpose == "admin"
    expiry = stamp + (timedelta(hours=8) if admin else timedelta(days=30))
    record = UserSession(
        id=uuid4(),
        user_id=user.id,
        client_id=client_id,
        device_name=device_name,
        purpose=purpose,
        access_hash=digest(access),
        csrf_hash=digest(csrf),
        created_at=stamp,
        access_expires_at=expiry if admin else stamp + timedelta(minutes=15),
        expires_at=expiry,
        idle_expires_at=stamp + timedelta(minutes=30) if admin else expiry,
        revoked_at=None,
    )
    session.add(record)
    session.flush()
    if not admin:
        session.add(
            RefreshToken(
                token_hash=digest(refresh), session_id=record.id, created_at=stamp, used_at=None
            )
        )
    return record, {
        "access_token": access,
        "refresh_token": refresh if not admin else None,
        "csrf_token": csrf,
        "token_type": "bearer",
        "expires_in": 28800 if admin else 900,
        "session_id": str(record.id),
        "user_id": str(user.id),
    }


def authenticate_access(session: Session, raw_token: str, admin: bool = False) -> Principal:
    record = session.scalar(select(UserSession).where(UserSession.access_hash == digest(raw_token)))
    if record is None:
        raise ApiError("authentication_required", 401)
    principal = Principal(
        record.user_id,
        record.id,
        record.client_id,
        record.purpose,
        roles_for(session, record.user_id),
    )
    assert_active_principal(session, principal, lock=False)
    if (record.purpose == "admin") != admin:
        raise ApiError("session_purpose_invalid", 403)
    if admin and not principal.roles:
        raise ApiError("admin_forbidden", 403)
    return principal


def assert_active_principal(
    session: Session, principal: Principal, lock: bool = True
) -> UserSession:
    user_query = (
        select(User).where(User.id == principal.user_id).execution_options(populate_existing=True)
    )
    token_query = (
        select(UserSession)
        .where(UserSession.id == principal.session_id)
        .execution_options(populate_existing=True)
    )
    if lock:
        user_query = user_query.with_for_update()
        token_query = token_query.with_for_update()
    user = session.scalar(user_query)
    record = session.scalar(token_query)
    stamp = now()
    if (
        user is None
        or not user.enabled
        or record is None
        or record.user_id != principal.user_id
        or record.client_id != principal.client_id
        or record.purpose != principal.purpose
        or record.revoked_at is not None
        or record.expires_at <= stamp
        or record.access_expires_at <= stamp
        or record.idle_expires_at <= stamp
    ):
        raise ApiError("session_invalid", 401)
    if principal.purpose == "admin" and lock:
        record.idle_expires_at = min(record.expires_at, stamp + timedelta(minutes=30))
    return record


def refresh_session(
    session: Session, raw_token: str, web: bool = False, csrf_token: str | None = None
) -> dict:
    token = session.get(RefreshToken, digest(raw_token))
    record = session.get(UserSession, token.session_id) if token else None
    if record is None:
        raise ApiError("session_invalid", 401)
    # All write authentication uses user -> session -> refresh-token lock order.
    user = session.scalar(select(User).where(User.id == record.user_id).with_for_update())
    record = session.scalar(
        select(UserSession)
        .where(UserSession.id == record.id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    token = session.scalar(
        select(RefreshToken)
        .where(RefreshToken.token_hash == digest(raw_token))
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    stamp = now()
    if (
        not user.enabled
        or record.revoked_at
        or record.expires_at <= stamp
        or record.purpose != ("api_web" if web else "api_native")
    ):
        raise ApiError("session_invalid", 401)
    if web and (not csrf_token or not secrets.compare_digest(digest(csrf_token), record.csrf_hash)):
        raise ApiError("csrf_invalid", 403)
    if token.used_at is not None:
        record.revoked_at = stamp
        session.commit()  # Persist compromise response before returning the rejection.
        raise ApiError("refresh_reuse", 401)
    token.used_at = stamp
    access, refresh = secret(), secret()
    record.access_hash = digest(access)
    record.access_expires_at = stamp + timedelta(minutes=15)
    session.add(
        RefreshToken(
            token_hash=digest(refresh), session_id=record.id, created_at=stamp, used_at=None
        )
    )
    return {
        "access_token": access,
        "refresh_token": refresh,
        "token_type": "bearer",
        "expires_in": 900,
        "session_id": str(record.id),
        "user_id": str(user.id),
    }
