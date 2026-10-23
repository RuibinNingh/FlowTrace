"""Versioned configuration store; the caller owns commit and rollback.

The privileged facade validates prepared secret bindings before constructing a
save command. Its candidate validator performs only local checks, never network
I/O. This module cannot create or reveal secret material.
"""

import hashlib
import json
from collections.abc import Callable, Iterable
from datetime import UTC
from uuid import UUID

from pydantic import ValidationError
from sqlalchemy import select
from sqlalchemy.orm import Session

from flowtrace_server.admin.service import audit, reauthenticate_admin, require_admin
from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import assert_active_principal, now

from .models import PUBLIC_KEYS, SECRET_KEYS, ConfigurationHead, ConfigurationRevision
from .schemas import (
    INITIAL_PUBLIC_VALUES,
    INITIAL_SECRET_REFS,
    MAX_VERSION,
    ConfigurationKey,
    ConfigurationMutationResult,
    ConfigurationRollbackCommand,
    ConfigurationSaveCommand,
    ConfigurationView,
    PublicConfiguration,
    PublicConfigurationPatch,
    SecretPresence,
    SecretReferences,
)

CandidateValidator = Callable[[PublicConfiguration, SecretReferences], None]


def _require_read(session: Session, principal: Principal) -> None:
    assert_active_principal(session, principal, lock=False)
    require_admin(session, principal)


def _head(session: Session, *, lock: bool = False) -> ConfigurationHead:
    statement = select(ConfigurationHead).where(ConfigurationHead.id == 1)
    if lock:
        statement = statement.with_for_update()
    record = session.scalar(statement.execution_options(populate_existing=True))
    if record is None:
        raise ApiError("configuration_not_initialized", 503)
    return record


def _snapshot(public: dict, refs: dict) -> tuple[PublicConfiguration, SecretReferences]:
    try:
        if set(public) != set(PUBLIC_KEYS) or set(refs) != set(SECRET_KEYS):
            raise ValueError
        # PostgreSQL stores JSON strings; the Python DTO intentionally requires
        # UUID objects. Check canonical storage syntax before conversion.
        decoded = {key: None if value is None else UUID(value) for key, value in refs.items()}
        if any(value is not None and str(decoded[key]) != value for key, value in refs.items()):
            raise ValueError
        return PublicConfiguration.model_validate(public), SecretReferences.model_validate(decoded)
    except (ValidationError, ValueError, TypeError, AttributeError):
        raise ApiError("configuration_snapshot_invalid", 503) from None


def _view(
    version: int,
    public: PublicConfiguration,
    refs: SecretReferences,
    *,
    effective_fields: Iterable[ConfigurationKey] = (),
    editable_fields: Iterable[ConfigurationKey] = PUBLIC_KEYS,
) -> ConfigurationView:
    return ConfigurationView(
        version=version,
        public_values=public,
        secret_presence=SecretPresence(
            **{key: value is not None for key, value in refs.model_dump().items()}
        ),
        effective_fields=tuple(effective_fields),
        editable_fields=tuple(editable_fields),
    )


def read_configuration(
    session: Session,
    principal: Principal,
    *,
    effective_fields: Iterable[ConfigurationKey] = (),
    editable_fields: Iterable[ConfigurationKey] = PUBLIC_KEYS,
) -> ConfigurationView:
    _require_read(session, principal)
    head = _head(session)
    public, refs = _snapshot(head.public_values, head.secret_refs)
    return _view(
        head.current_version,
        public,
        refs,
        effective_fields=effective_fields,
        editable_fields=editable_fields,
    )


def preview_configuration(
    session: Session,
    principal: Principal,
    patch: PublicConfigurationPatch,
    *,
    effective_fields: Iterable[ConfigurationKey] = (),
    editable_fields: Iterable[ConfigurationKey] = PUBLIC_KEYS,
) -> ConfigurationView:
    _require_read(session, principal)
    head = _head(session)
    public, refs = _snapshot(head.public_values, head.secret_refs)
    return _view(
        head.current_version,
        patch.apply(public),
        refs,
        effective_fields=effective_fields,
        editable_fields=editable_fields,
    )


def read_revision(session: Session, principal: Principal, target_version: int) -> ConfigurationView:
    _require_read(session, principal)
    if type(target_version) is not int or not 0 <= target_version <= MAX_VERSION:
        raise ApiError("configuration_rollback_target_invalid", 422)
    if target_version == 0:
        public, refs = _snapshot(INITIAL_PUBLIC_VALUES, INITIAL_SECRET_REFS)
    else:
        record = session.get(ConfigurationRevision, target_version)
        if record is None:
            raise ApiError("configuration_rollback_target_invalid", 422)
        public, refs = _snapshot(record.public_values, record.secret_refs)
    return _view(target_version, public, refs)


def request_hash(actor_id: UUID, command) -> str:
    """Include explicit delete/keep and prepared UUID semantics in replay identity."""
    body = {
        "actor_id": str(actor_id),
        "kind": "update" if isinstance(command, ConfigurationSaveCommand) else "rollback",
        "base_version": command.base_version,
        "request_id": str(command.request_id),
    }
    if isinstance(command, ConfigurationSaveCommand):
        body["public_patch"] = command.public_patch.model_dump(mode="json", exclude_unset=True)
        body["secret_patch"] = command.prepared_secret_refs.model_dump(
            mode="json", exclude_unset=True
        )
    else:
        body["target_version"] = command.target_version
    return hashlib.sha256(
        json.dumps(body, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    ).hexdigest()


def _prepare_mutation(session, principal, command, password):
    reauthenticate_admin(session, principal, password, capability="service")
    # All writers use admin_control -> actor/session -> singleton. The singleton
    # serializes both the global version and unique request lookup.
    head = _head(session, lock=True)
    digest = request_hash(principal.user_id, command)
    replay = session.scalar(
        select(ConfigurationRevision).where(ConfigurationRevision.request_id == command.request_id)
    )
    if replay is not None:
        if replay.actor_user_id != principal.user_id or replay.request_hash != digest:
            raise ApiError("configuration_request_conflict", 409)
        return head, digest, ConfigurationMutationResult(version=replay.version, replayed=True)
    if head.current_version != command.base_version:
        raise ApiError("configuration_version_conflict", 409)
    if head.current_version >= MAX_VERSION:
        raise ApiError("configuration_version_exhausted", 409)
    return head, digest, None


def _record(session, principal, command, head, digest, public, refs, target=None):
    stamp = now()
    version = head.current_version + 1
    serialized_public = public.model_dump(mode="json")
    serialized_refs = refs.model_dump(mode="json")
    kind = "update" if target is None else "rollback"
    session.add(
        ConfigurationRevision(
            version=version,
            base_version=head.current_version,
            request_id=command.request_id,
            request_hash=digest,
            actor_user_id=principal.user_id,
            change_kind=kind,
            rollback_target_version=target,
            public_values=serialized_public,
            secret_refs=serialized_refs,
            created_at=stamp,
        )
    )
    head.current_version = version
    head.public_values = serialized_public
    head.secret_refs = serialized_refs
    head.updated_at = stamp
    audit(
        session,
        principal.user_id,
        f"configuration.{kind}",
        command.request_id,
        version=version,
        base_version=command.base_version,
    )
    session.flush()
    return ConfigurationMutationResult(version=version, replayed=False)


def save_configuration(
    session: Session,
    principal: Principal,
    command: ConfigurationSaveCommand,
    *,
    password: str,
    validate_candidate: CandidateValidator,
) -> ConfigurationMutationResult:
    head, digest, replay = _prepare_mutation(session, principal, command, password)
    if replay is not None:
        return replay
    public, refs = _snapshot(head.public_values, head.secret_refs)
    public = command.public_patch.apply(public)
    refs = command.prepared_secret_refs.apply(refs)
    validate_candidate(public, refs)
    return _record(session, principal, command, head, digest, public, refs)


def rollback_configuration(
    session: Session,
    principal: Principal,
    command: ConfigurationRollbackCommand,
    *,
    password: str,
    validate_candidate: CandidateValidator,
) -> ConfigurationMutationResult:
    head, digest, replay = _prepare_mutation(session, principal, command, password)
    if replay is not None:
        return replay
    if command.target_version >= head.current_version:
        raise ApiError("configuration_rollback_target_invalid", 422)
    if command.target_version == 0:
        public, refs = _snapshot(INITIAL_PUBLIC_VALUES, INITIAL_SECRET_REFS)
    else:
        record = session.get(ConfigurationRevision, command.target_version)
        if record is None:
            raise ApiError("configuration_rollback_target_invalid", 422)
        public, refs = _snapshot(record.public_values, record.secret_refs)
    validate_candidate(public, refs)
    return _record(
        session, principal, command, head, digest, public, refs, target=command.target_version
    )


def list_revisions(session: Session, principal: Principal, *, before: int | None = None):
    _require_read(session, principal)
    if before is not None and (type(before) is not int or not 1 <= before <= MAX_VERSION):
        raise ApiError("configuration_cursor_invalid", 422)
    statement = select(ConfigurationRevision)
    if before is not None:
        statement = statement.where(ConfigurationRevision.version < before)
    records = list(
        session.scalars(statement.order_by(ConfigurationRevision.version.desc()).limit(21))
    )
    items = []
    for record in records[:20]:
        public, refs = _snapshot(record.public_values, record.secret_refs)
        items.append(
            {
                "version": record.version,
                "base_version": record.base_version,
                "change_kind": record.change_kind,
                "rollback_target_version": record.rollback_target_version,
                "actor_id": str(record.actor_user_id),
                "created_at": record.created_at.astimezone(UTC).isoformat(),
                "public_values": public.model_dump(mode="json"),
                "secret_presence": {
                    key: value is not None for key, value in refs.model_dump().items()
                },
            }
        )
    return {
        "items": items,
        "has_more": len(records) > 20,
        "next_cursor": records[19].version if len(records) > 20 else None,
    }
