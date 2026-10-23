from datetime import timedelta
from typing import Literal
from uuid import UUID, uuid4

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit, AdminControl
from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import AdminRole, Invite, User, UserSession
from flowtrace_server.auth.service import (
    PASSWORDS,
    assert_active_principal,
    create_user,
    digest,
    now,
    roles_for,
    secret,
)

ADMIN_ROLES = frozenset({"server_owner", "service_admin", "recovery_admin"})


def require_portal(session: Session, principal: Principal) -> None:
    if principal.purpose != "admin" or not roles_for(session, principal.user_id).intersection(
        ADMIN_ROLES
    ):
        raise ApiError("admin_forbidden", 403)


def require_recovery(session: Session, principal: Principal) -> None:
    require_portal(session, principal)
    if "recovery_admin" not in roles_for(session, principal.user_id):
        raise ApiError("admin_recovery_required", 403)


def require_admin(session: Session, principal: Principal, owner: bool = False) -> None:
    current_roles = roles_for(session, principal.user_id)
    if (
        principal.purpose != "admin"
        or not current_roles.intersection({"service_admin", "server_owner"})
        or (owner and "server_owner" not in current_roles)
    ):
        raise ApiError("admin_forbidden", 403)


def audit(
    session: Session,
    actor: UUID | None,
    action: str,
    target: UUID | None = None,
    **summary: bool | int,
) -> None:
    session.add(
        AdminAudit(
            id=uuid4(),
            actor_id=actor,
            action=action,
            target_id=target,
            created_at=now(),
            summary=summary,
        )
    )


def lock_admin_control(session: Session) -> None:
    if session.scalar(select(AdminControl).where(AdminControl.id == 1).with_for_update()) is None:
        raise ApiError("admin_not_initialized", 503)


def reauthenticate_admin(
    session: Session,
    principal: Principal,
    password: str,
    *,
    capability: Literal["portal", "service", "owner", "recovery"] = "service",
) -> frozenset[str]:
    """Recheck the current password and roles inside the management lock.

    This is an action-scoped check, never a reusable privilege elevation token.
    The caller commits the protected action and its audit together.
    """
    lock_admin_control(session)
    assert_active_principal(session, principal)
    if capability == "portal":
        require_portal(session, principal)
    elif capability == "recovery":
        require_recovery(session, principal)
    elif capability in {"service", "owner"}:
        require_admin(session, principal, owner=capability == "owner")
    else:
        raise ValueError("Unknown administrator capability")
    user = session.get(User, principal.user_id)
    if not 12 <= len(password) <= 256 or not PASSWORDS.verify(password, user.password_hash):
        raise ApiError("reauthentication_failed", 403)
    return roles_for(session, principal.user_id)


def protect_management_identity(
    session: Session, target_id: UUID, next_roles: frozenset[str], next_enabled: bool
) -> None:
    """Caller holds admin_control and the target user row."""
    previous = roles_for(session, target_id)
    recoverable = {"server_owner", "recovery_admin"}
    if previous.intersection(recoverable) and not (
        next_enabled and next_roles.intersection(recoverable)
    ):
        remaining = session.scalar(
            select(func.count(func.distinct(User.id)))
            .join(AdminRole, User.id == AdminRole.user_id)
            .where(User.enabled.is_(True), User.id != target_id, AdminRole.role.in_(recoverable))
        )
        if not remaining:
            raise ApiError("last_admin_protected", 409)
    if "server_owner" in previous and not (next_enabled and "server_owner" in next_roles):
        remaining_owner = session.scalar(
            select(func.count())
            .select_from(AdminRole)
            .join(User, User.id == AdminRole.user_id)
            .where(User.enabled.is_(True), User.id != target_id, AdminRole.role == "server_owner")
        )
        if not remaining_owner:
            raise ApiError("last_owner_protected", 409)


def set_admin_roles(
    session: Session,
    principal: Principal,
    target_id: UUID,
    selected: frozenset[str],
    current_password: str,
) -> None:
    if not selected.issubset(ADMIN_ROLES):
        raise ApiError("admin_role_invalid", 422)
    reauthenticate_admin(session, principal, current_password, capability="owner")
    target = session.scalar(
        select(User)
        .where(User.id == target_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if target is None:
        raise ApiError("not_found", 404)
    previous = roles_for(session, target_id)
    protect_management_identity(session, target_id, selected, target.enabled)
    for record in session.scalars(select(AdminRole).where(AdminRole.user_id == target_id)):
        if record.role not in selected:
            session.delete(record)
    for role in selected - previous:
        session.add(AdminRole(user_id=target_id, role=role))
    if selected != previous:
        for record in session.scalars(
            select(UserSession)
            .where(
                UserSession.user_id == target_id,
                UserSession.purpose == "admin",
                UserSession.revoked_at.is_(None),
            )
            .with_for_update()
        ):
            record.revoked_at = now()
    audit(
        session,
        principal.user_id,
        "admin.roles_change",
        target_id,
        granted_count=len(selected - previous),
        revoked_count=len(previous - selected),
        **{role: role in selected for role in sorted(ADMIN_ROLES)},
    )


def reset_user_password(
    session: Session,
    principal: Principal,
    target_id: UUID,
    current_password: str,
    replacement: str,
    repeated: str,
) -> None:
    roles = reauthenticate_admin(session, principal, current_password)
    if not 12 <= len(replacement) <= 256 or replacement != repeated:
        raise ApiError("password_input_invalid", 422)
    target = session.scalar(
        select(User)
        .where(User.id == target_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    if target is None:
        raise ApiError("not_found", 404)
    if roles_for(session, target_id) and "server_owner" not in roles:
        raise ApiError("admin_owner_required", 403)
    target.password_hash = PASSWORDS.hash(replacement)
    revoked = 0
    for record in session.scalars(
        select(UserSession)
        .where(UserSession.user_id == target_id, UserSession.revoked_at.is_(None))
        .with_for_update()
    ):
        record.revoked_at = now()
        revoked += 1
    audit(session, principal.user_id, "user.password_reset", target_id, revoked_sessions=revoked)


def bootstrap_admin(session: Session, username: str, password: str) -> User:
    lock_admin_control(session)
    if session.scalar(select(func.count()).select_from(AdminRole)):
        raise ApiError("admin_already_initialized", 409)
    user = create_user(session, username, password)
    for role in ("server_owner", "service_admin", "recovery_admin"):
        session.add(AdminRole(user_id=user.id, role=role))
    audit(session, user.id, "admin.bootstrap", user.id)
    return user


def recover_admin(session: Session, username: str, password: str) -> User:
    """Local operating-system authority only; never exposed through an HTTP route."""
    lock_admin_control(session)
    user = session.scalar(select(User).where(User.username == username).with_for_update())
    if user is None:
        raise ApiError("recovery_target_missing", 404)
    user.password_hash = PASSWORDS.hash(password)
    user.enabled = True
    current = roles_for(session, user.id)
    for role in ("server_owner", "service_admin", "recovery_admin"):
        if role not in current:
            session.add(AdminRole(user_id=user.id, role=role))
    for record in session.scalars(select(UserSession).where(UserSession.user_id == user.id)):
        record.revoked_at = now()
    audit(session, user.id, "admin.local_recovery", user.id)
    return user


def create_invite(
    session: Session, principal: Principal, days: int | None = None
) -> tuple[Invite, str]:
    lock_admin_control(session)
    assert_active_principal(session, principal)
    require_admin(session, principal)
    if days is None:
        from flowtrace_server.configuration.runtime import read_runtime_configuration

        days = read_runtime_configuration(session).values.invitation_default_days
    if not 1 <= days <= 30:
        raise ApiError("invite_duration_invalid", 422)
    token = secret()
    invitation = Invite(
        id=uuid4(),
        token_hash=digest(token),
        created_by=principal.user_id,
        created_at=now(),
        expires_at=now() + timedelta(days=days),
        revoked_at=None,
        consumed_by=None,
    )
    session.add(invitation)
    audit(session, principal.user_id, "invite.create", invitation.id)
    return invitation, token


def set_user_enabled(
    session: Session, principal: Principal, target_id: UUID, enabled: bool
) -> None:
    lock_admin_control(session)
    assert_active_principal(session, principal)
    require_admin(session, principal)
    target = session.scalar(select(User).where(User.id == target_id).with_for_update())
    if target is None:
        raise ApiError("not_found", 404)
    target_roles = roles_for(session, target_id)
    if target_roles and "server_owner" not in roles_for(session, principal.user_id):
        raise ApiError("admin_owner_required", 403)
    protect_management_identity(session, target_id, target_roles, enabled)
    target.enabled = enabled
    if not enabled:
        for record in session.scalars(
            select(UserSession).where(
                UserSession.user_id == target_id, UserSession.revoked_at.is_(None)
            )
        ):
            record.revoked_at = now()
    audit(session, principal.user_id, "user.enable" if enabled else "user.disable", target_id)
