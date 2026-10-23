"""One independent, retryable PostgreSQL transaction per immutable operation."""

from copy import deepcopy
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session

from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import assert_active_principal, now
from flowtrace_server.books.permissions import authorize_scope
from flowtrace_server.diagnostics import event
from flowtrace_server.domain.money import DomainError, parse_minor

from .commands import apply_command, scope_set
from .common import (
    CommandRejected,
    RetryScopeSet,
    current_entity,
    lock_scopes,
    require_current_client,
    run_transaction,
    write_changes,
)
from .input import ValidatedPush
from .models import SyncEntity, SyncReceipt
from .projections import account_links, entity_event, event_dict


def _rejected(operation_id: str, code: str, status: int, current=None) -> dict:
    return {
        "operation_id": operation_id,
        "status": "rejected",
        "error": {"code": code, "http_status": status, "current": current},
    }


def _current_projection(session, principal, operation, scopes):
    entity = current_entity(session, UUID(operation.entity_id))
    if entity is None or entity.scope_id not in scopes:
        return None
    authorize_scope(session, principal, entity.scope_id)
    return event_dict(entity_event(session, entity), scopes[entity.scope_id].revision)


def _lock_accounts(session, principal, operation, entity, scopes):
    identifiers = set()
    if operation.entity_type == "account" and entity is not None:
        identifiers.add(entity.id)
    if operation.entity_type == "bill":
        payloads = [entity.payload] if entity else []
        if operation.action != "delete":
            payloads.append(operation.payload.model_dump())
        for payload in payloads:
            for account_id in account_links(payload).values():
                account = current_entity(session, account_id)
                if account is not None and account.scope_id in scopes:
                    identifiers.add(account_id)
    if identifiers:
        list(
            session.scalars(
                select(SyncEntity)
                .where(SyncEntity.id.in_(identifiers))
                .order_by(SyncEntity.id)
                .with_for_update()
                .execution_options(populate_existing=True)
            )
        )


def push_operations(
    session: Session, principal: Principal, validated: ValidatedPush, *, before_commit=None
):
    body = validated.request
    results = []
    for operation, digest in zip(body.operations, validated.operation_hashes, strict=True):

        def apply_one():
            require_current_client(session, principal, body.sync_epoch, body.client_id)
            primary = authorize_scope(session, principal, UUID(operation.scope_id), write=True)
            key = (principal.user_id, principal.client_id, UUID(operation.operation_id))
            receipt = session.get(SyncReceipt, key)
            # A successful move changes the entity's actual scope. Exact replay
            # must authorize its recorded domains before rediscovering today's
            # entity, or it would fail before reaching its immutable receipt.
            wanted = (
                {UUID(operation.scope_id), *(UUID(value) for value in receipt.required_scope_ids)}
                if receipt is not None
                else scope_set(session, principal, operation)
            )
            scopes = lock_scopes(session, wanted)
            for identifier in sorted(scopes):
                if (
                    operation.entity_type == "book"
                    and operation.action == "delete"
                    and primary.role == "owner"
                    and scopes[identifier].kind == "user"
                    and scopes[identifier].owner_user_id != principal.user_id
                ):
                    # Owner-authorized membership control notification only;
                    # no access to that user's accounts or private payloads.
                    continue
                authorize_scope(session, principal, identifier, write=True)
            if receipt is None and not scope_set(session, principal, operation).issubset(scopes):
                raise RetryScopeSet
            if receipt is not None:
                # Read no cached response until its original permission domains
                # have also been checked against today's membership.
                for identifier in receipt.required_scope_ids:
                    authorize_scope(session, principal, UUID(identifier), write=True)
                if receipt.content_hash != digest:
                    return _rejected(operation.operation_id, "idempotency_mismatch", 409)
                result = deepcopy(receipt.result)
                if receipt.status == "applied":
                    result["replayed"] = True
                elif result["error"]["code"] == "revision_conflict":
                    result["error"]["current"] = _current_projection(
                        session, principal, operation, scopes
                    )
                return result
            entity = current_entity(session, UUID(operation.entity_id))
            _lock_accounts(session, principal, operation, entity, scopes)
            failure = None
            if operation.depends_on is not None:
                dependency = session.get(
                    SyncReceipt,
                    (principal.user_id, principal.client_id, UUID(operation.depends_on)),
                )
                if dependency is None or dependency.status != "applied":
                    failure = ("dependency_failed", 400)
                else:
                    for identifier in dependency.required_scope_ids:
                        authorize_scope(session, principal, UUID(identifier))
            if failure is None:
                if operation.action == "create" and entity is not None:
                    failure = ("id_conflict", 409)
                elif operation.action != "create":
                    if entity is None or entity.entity_type != operation.entity_type:
                        raise ApiError("not_found", 404)
                    if entity.deleted or entity.revision != parse_minor(operation.base_revision):
                        failure = ("revision_conflict", 409)
            if failure is None:
                try:
                    # Rejection rolls back every entity, posting and secondary
                    # revision. A small rejected receipt may survive outside it.
                    with session.begin_nested():
                        entity, events = apply_command(
                            session, principal, operation, entity, scopes
                        )
                        commit_id, revisions = write_changes(session, scopes, events)
                        result = {
                            "operation_id": operation.operation_id,
                            "status": "applied",
                            "entity_id": str(entity.id),
                            "revision": str(entity.revision),
                            "commit_id": commit_id,
                            "scope_revisions": revisions,
                            "replayed": False,
                        }
                except (CommandRejected, DomainError) as error:
                    failure = (error.code, getattr(error, "status", 422))
            if failure is not None:
                result = _rejected(operation.operation_id, *failure)
            stored = deepcopy(result)
            session.add(
                SyncReceipt(
                    user_id=principal.user_id,
                    client_id=principal.client_id,
                    operation_id=UUID(operation.operation_id),
                    content_hash=digest,
                    status=result["status"],
                    result=stored,
                    required_scope_ids=[str(identifier) for identifier in sorted(scopes)],
                    created_at=now(),
                )
            )
            session.flush()
            if result["status"] == "rejected" and result["error"]["code"] == "revision_conflict":
                result["error"]["current"] = _current_projection(
                    session, principal, operation, scopes
                )
            assert_active_principal(session, principal, lock=True)
            if before_commit is not None:
                before_commit(operation, result)
            return result

        try:
            result = run_transaction(session, apply_one)
        except ApiError as error:
            result = _rejected(operation.operation_id, error.code, error.status)
        try:
            if result["status"] == "applied":
                event(
                    "sync_replay" if result["replayed"] else "sync_commit",
                    operation_id=operation.operation_id,
                    entity_id=operation.entity_id,
                    scope_id=operation.scope_id,
                )
            elif result["error"]["code"] == "revision_conflict":
                event(
                    "sync_conflict",
                    operation_id=operation.operation_id,
                    entity_id=operation.entity_id,
                    scope_id=operation.scope_id,
                )
        except Exception:
            # A diagnostic sink cannot turn an already committed receipt into
            # an apparent failure or cause duplicate accounting on a retry.
            pass
        results.append(result)
    return {"results": results}
