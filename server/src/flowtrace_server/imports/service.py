"""Atomic create-only batches, durable source identity and conflict-safe undo."""

import base64
import heapq
from copy import deepcopy
from datetime import datetime
from uuid import UUID, uuid5

from sqlalchemy import and_, or_, select
from sqlalchemy.orm import Session

from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import assert_active_principal, now
from flowtrace_server.books.permissions import authorize_scope
from flowtrace_server.domain.money import DomainError
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.sync.commands import apply_command, scope_set
from flowtrace_server.sync.common import (
    MAX_COMMIT_EVENTS,
    CommandRejected,
    current_entity,
    lock_scopes,
    require_current_client,
    run_transaction,
    visible_entity,
    write_changes,
)
from flowtrace_server.sync.models import SyncEntity
from flowtrace_server.sync.projections import entity_event
from flowtrace_server.sync.schemas import PAYLOAD_TYPES, Operation
from flowtrace_server.sync.writer import _lock_accounts

from .attachment_transfers import (
    lock_private_orphans,
    move_available,
    plan_transfers,
    restore_private_orphans,
    undo_conflicts,
)
from .models import ImportBatch, ImportItem
from .parsers import canonical, decode_json, digest
from .publishing import publish_changes
from .schemas import ImportRequest, UndoRequest

REFERENCE_FIELDS = {
    "book_id",
    "account_id",
    "from_account_id",
    "to_account_id",
    "category_id",
    "parent_id",
    "group_id",
    "source_bill_id",
}
REFERENCE_LISTS = {"tag_ids", "attachment_ids"}


def target_ids(principal: Principal, body: ImportRequest, *, check_budget=None) -> dict[str, str]:
    targets = {}
    for row in body.document.rows:
        if check_budget is not None:
            check_budget()
        targets[row.source_id] = str(
            uuid5(principal.user_id, body.document.source_namespace + ":" + row.source_id)
        )
    return targets


def _rewrite(value, mapping, key=None):
    if isinstance(value, dict):
        return {k: _rewrite(v, mapping, k) for k, v in value.items()}
    if isinstance(value, list):
        return [_rewrite(v, mapping, key) for v in value]
    if key in REFERENCE_FIELDS | REFERENCE_LISTS and isinstance(value, str):
        return mapping.get(value, value)
    return value


def operations_for(
    principal: Principal, body: ImportRequest, *, check_budget=None
) -> list[Operation]:
    targets = target_ids(principal, body, check_budget=check_budget)
    if (set(body.resource_mapping) | set(body.scope_mapping)) & set(targets):
        raise ApiError("import_mapping_conflict", 422)
    if any(
        body.resource_mapping[key] != value
        for key, value in body.scope_mapping.items()
        if key in body.resource_mapping
    ):
        raise ApiError("import_mapping_conflict", 422)
    mapping = {**body.scope_mapping, **body.resource_mapping, **targets}
    commands = []
    for row in body.document.rows:
        if check_budget is not None:
            check_budget()
        payload = _rewrite(deepcopy(row.payload), mapping)
        scope = body.scope_mapping.get(row.scope_id, targets.get(row.scope_id, row.scope_id))
        if row.entity_type == "book":
            scope = str(principal.user_id)
        commands.append(
            Operation.model_validate(
                {
                    "operation_id": str(uuid5(UUID(body.batch_id), row.source_id)),
                    "scope_id": scope,
                    "entity_type": row.entity_type,
                    "entity_id": targets[row.source_id],
                    "action": "create",
                    "base_revision": "0",
                    "depends_on": None,
                    "payload": payload,
                }
            )
        )
    # Dependency sorting, rather than input order, keeps source expenses before receipts.
    by_id = {command.entity_id: command for command in commands}

    def references(value, key=None):
        if isinstance(value, dict):
            return set().union(*(references(v, k) for k, v in value.items()))
        if isinstance(value, list):
            return set().union(*(references(v, key) for v in value))
        if key in REFERENCE_FIELDS | REFERENCE_LISTS and value in by_id:
            return {value}
        return set()

    indexes = {command.entity_id: index for index, command in enumerate(commands)}
    dependencies, dependents = {}, {identifier: set() for identifier in by_id}
    for command in commands:
        if check_budget is not None:
            check_budget()
        required = references(command.payload.model_dump())
        if command.scope_id in by_id:
            required.add(command.scope_id)
        dependencies[command.entity_id] = required
        for identifier in required:
            dependents[identifier].add(command.entity_id)
    ready = [indexes[identifier] for identifier, required in dependencies.items() if not required]
    heapq.heapify(ready)
    ordered = []
    while ready:
        if check_budget is not None:
            check_budget()
        command = commands[heapq.heappop(ready)]
        ordered.append(command)
        for identifier in dependents[command.entity_id]:
            dependencies[identifier].remove(command.entity_id)
            if not dependencies[identifier]:
                heapq.heappush(ready, indexes[identifier])
    if len(ordered) != len(commands):
        raise ApiError("import_dependency_cycle", 422)
    return ordered


def _principal(session, principal):
    if principal.purpose not in {"api_native", "api_web"}:
        raise ApiError("session_purpose_invalid", 403)
    assert_active_principal(session, principal, lock=True)


def _scope_ids(session, principal, commands, transfers=None, *, check_budget=None):
    new_books = {
        UUID(c.entity_id)
        for c in commands
        if c.entity_type == "book" and current_entity(session, UUID(c.entity_id)) is None
    }
    future = {c.entity_id: c for c in commands}
    wanted = {principal.user_id}
    wanted.update((transfers or {}).values())

    def collect(value, key=None):
        if isinstance(value, dict):
            return set().union(*(collect(v, k) for k, v in value.items()))
        if isinstance(value, list):
            return set().union(*(collect(v, key) for v in value))
        if key in REFERENCE_FIELDS | REFERENCE_LISTS and value:
            return {(key, value)}
        return set()

    for command in commands:
        if check_budget is not None:
            check_budget()
        wanted.add(UUID(command.scope_id))
        for key, identifier in collect(command.payload.model_dump()):
            if identifier in future:
                wanted.add(UUID(future[identifier].scope_id))
            else:
                entity = current_entity(session, UUID(identifier))
                if key == "source_bill_id":
                    entity = visible_entity(
                        session, principal, UUID(identifier), "bill", active=False
                    )
                if entity is not None:
                    wanted.add(entity.scope_id)
    return wanted - new_books


def _source_item(session, principal, body, source_id):
    return session.get(
        ImportItem, (principal.user_id, body.document.source_namespace, UUID(source_id))
    )


def _source_hash(row, command, historical_posting=None):
    value = {
        "source": row.model_dump(),
        "destination_scope": command.scope_id,
        "destination_payload": command.payload.model_dump(),
    }
    if historical_posting is not None:
        value["historical_adjustment_minor"] = historical_posting
    return digest(value)


def request_content_hash(body):
    value = body.model_dump()
    # Adding optional metadata must not invalidate an earlier batch's immutable
    # request hash when that metadata is absent/empty. Nonempty intent is always
    # hashed, including the original payload's field presence.
    if not value["document"]["posting_hints"]:
        value["document"].pop("posting_hints")
    if not value["attachment_transfers"]:
        value.pop("attachment_transfers")
    return digest(value)


def _historical_posting(body, source_id):
    hint = body.document.posting_hints.get(source_id)
    return int(hint.signed_principal_minor) if hint is not None else None


def _import_source_hash(row, command, body, transfers):
    base = _source_hash(row, command, _historical_posting(body, row.source_id))
    intent = {
        identifier: str(transfers[UUID(identifier)])
        for identifier in (command.payload.attachment_ids if command.entity_type == "bill" else [])
        if UUID(identifier) in transfers
    }
    return digest({"content_hash": base, "attachment_transfers": intent}) if intent else base


def _new_attachment_ids(commands, duplicate_ids):
    return {
        identifier
        for command in commands
        if command.entity_type == "bill" and command.entity_id not in duplicate_ids
        for identifier in command.payload.attachment_ids
    }


def _apply_import_command(session, principal, command, scopes, body, source_id):
    hint = _historical_posting(body, source_id)
    if hint is None:
        return apply_command(session, principal, command, None, scopes)
    # This explicit import-only argument retains the original payload and its
    # historical signed movement; ordinary push never supplies the argument.
    return apply_command(
        session,
        principal,
        command,
        None,
        scopes,
        historical_adjustment_minor=hint,
    )


def preview_import(session: Session, principal: Principal, body: ImportRequest) -> dict:
    return run_transaction(
        session,
        lambda: preview_import_in_transaction(session, principal, body),
        repeatable=True,
    )


def preview_import_in_transaction(
    session: Session,
    principal: Principal,
    body: ImportRequest,
    *,
    publication_id=None,
    check_budget=None,
) -> dict:
    """Actual graph validation, rollback-only effects, caller-owned transaction.

    Public input and its 200-event preview bound stay unchanged. A trusted
    typed publication request requires its explicit matching stage context;
    this path neither commits nor rolls back the caller's outer transaction.
    """
    if publication_id is None and getattr(body, "stage_id", None) is not None:
        raise ValueError("publication_context_required")
    if publication_id is not None and getattr(body, "stage_id", None) != str(publication_id):
        raise ValueError("publication_stage_required")
    if check_budget is not None and not callable(check_budget):
        raise TypeError("trusted_budget_callback_required")
    budget = check_budget if check_budget is not None else lambda: None
    budget()
    commands = operations_for(principal, body, check_budget=budget)
    transfers = plan_transfers(
        body, commands, target_ids(principal, body, check_budget=budget), check_budget=budget
    )
    budget()
    _principal(session, principal)
    if UUID(body.client_id) != principal.client_id:
        raise ApiError("client_mismatch", 403)
    if session.get(ServerState, 1).sync_epoch != UUID(body.sync_epoch):
        raise ApiError("epoch_changed", 409)
    scopes = lock_scopes(
        session, _scope_ids(session, principal, commands, transfers, check_budget=budget)
    )
    for identifier in scopes:
        authorize_scope(session, principal, identifier, write=True)
    scope_versions = {
        str(identifier): {
            "permission_version": str(scope.permission_version),
            "revision": str(scope.revision),
        }
        for identifier, scope in scopes.items()
    }
    rows, fingerprints = [], {}
    targets = target_ids(principal, body, check_budget=budget)
    by_target = {c.entity_id: c for c in commands}
    source_by_target = {targets[r.source_id]: r.source_id for r in body.document.rows}
    known_fingerprints = set()
    known_query = select(SyncEntity).where(
        SyncEntity.scope_id.in_(scopes), SyncEntity.deleted.is_(False)
    )
    if publication_id is None:
        known_query = known_query.limit(1001)
    known_count = 0
    for entity in session.scalars(known_query.execution_options(yield_per=500)):
        budget()
        known_count += 1
        if publication_id is None and known_count > 1000:
            continue
        payload = PAYLOAD_TYPES[entity.entity_type].model_validate(entity.payload).model_dump()
        known_fingerprints.add((entity.entity_type, str(entity.scope_id), digest(payload)))
    for position, row in enumerate(body.document.rows, 1):
        budget()
        item = _source_item(session, principal, body, row.source_id)
        state = "new"
        if item is not None:
            state = (
                "duplicate"
                if item.source_hash
                == _import_source_hash(row, by_target[targets[row.source_id]], body, transfers)
                else "source_conflict"
            )
            if session.get(ImportBatch, item.batch_id).status == "undone":
                state = "previously_undone"
            entity = current_entity(session, item.entity_id)
            if state == "duplicate" and (
                entity is None
                or entity.deleted
                or entity.revision != item.revision
                or digest(entity.payload) != item.payload_hash
            ):
                state = "source_modified"
        fingerprint = digest({"entity_type": row.entity_type, "payload": row.payload})
        warning = "same_content_distinct_source" if fingerprint in fingerprints else None
        command = by_target[targets[row.source_id]]
        if (
            state == "new"
            and (command.entity_type, command.scope_id, digest(command.payload.model_dump()))
            in known_fingerprints
        ):
            warning = "possible_existing_content_distinct_source"
        fingerprints[fingerprint] = position
        rows.append(
            {
                "row": position,
                "source_id": row.source_id,
                "entity_id": targets[row.source_id],
                "status": state,
                "warning": warning,
            }
        )
    errors = []
    can_apply = all(r["status"] in {"new", "duplicate"} for r in rows)
    if can_apply:
        status_by_target = {r["entity_id"]: r["status"] for r in rows}
        position_by_target = {r["entity_id"]: r["row"] for r in rows}
        pending, preview_scopes = set(), dict(scopes)
        savepoint = session.begin_nested()
        try:
            try:
                pending_transfers = lock_private_orphans(
                    session,
                    principal,
                    transfers,
                    _new_attachment_ids(
                        commands,
                        {
                            identifier
                            for identifier, status in status_by_target.items()
                            if status == "duplicate"
                        },
                    ),
                    check_budget=budget,
                )
            except ApiError as error:
                if error.code != "import_attachment_transfer_conflict":
                    raise
                errors.append(
                    {
                        "row": min(
                            position_by_target[c.entity_id]
                            for c in commands
                            if c.entity_type == "bill"
                            and set(c.payload.attachment_ids) & {str(i) for i in transfers}
                        ),
                        "field": "payload.attachment_ids",
                        "code": error.code,
                    }
                )
                can_apply, pending_transfers = False, {}
            transfer_receipts = []
            for command in commands if can_apply else []:
                budget()
                if status_by_target[command.entity_id] == "duplicate":
                    continue
                try:
                    move_available(
                        session,
                        principal,
                        transfers,
                        pending_transfers,
                        preview_scopes,
                        transfer_receipts,
                        check_budget=budget,
                    )
                    if current_entity(session, UUID(command.entity_id)) is not None:
                        raise ApiError("id_conflict", 409)
                    if not scope_set(session, principal, command).issubset(preview_scopes):
                        raise ApiError("import_scope_changed", 409)
                    _lock_accounts(session, principal, command, None, preview_scopes)
                    _, events = _apply_import_command(
                        session,
                        principal,
                        command,
                        preview_scopes,
                        body,
                        source_by_target[command.entity_id],
                    )
                    pending.update((e.scope_id, e.entity_type, e.entity_id) for e in events)
                    if publication_id is None and len(pending) > MAX_COMMIT_EVENTS:
                        raise ApiError("commit_too_large", 422)
                except (ApiError, CommandRejected, DomainError) as error:
                    errors.append(
                        {
                            "row": position_by_target[command.entity_id],
                            "field": "payload",
                            "code": error.code,
                        }
                    )
                    can_apply = False
                    break
        finally:
            savepoint.rollback()
    budget()
    assert_active_principal(session, principal, lock=True)
    result = {
        "batch_id": body.batch_id,
        "content_hash": request_content_hash(body),
        "rows": rows,
        "can_apply": can_apply,
        "errors": errors,
        "fingerprint_scan_complete": publication_id is not None or known_count <= 1000,
    }
    if publication_id is not None:
        result["scope_versions"] = scope_versions
    return result


def apply_import(
    session: Session, principal: Principal, body: ImportRequest, *, before_commit=None
) -> dict:
    return run_transaction(
        session,
        lambda: apply_import_in_transaction(session, principal, body, before_commit=before_commit),
    )


def apply_import_in_transaction(
    session: Session,
    principal: Principal,
    body: ImportRequest,
    *,
    before_commit=None,
    publication_id=None,
    before_chunk=None,
    check_budget=None,
) -> dict:
    """Shared effect: never commits, rolls back, or opens an outer transaction."""
    if publication_id is None and getattr(body, "stage_id", None) is not None:
        raise ValueError("publication_context_required")
    if publication_id is not None and getattr(body, "stage_id", None) != str(publication_id):
        raise ValueError("publication_stage_required")
    if check_budget is not None and not callable(check_budget):
        raise TypeError("trusted_budget_callback_required")
    budget = check_budget if check_budget is not None else lambda: None
    budget()
    commands = operations_for(principal, body, check_budget=budget)
    targets = target_ids(principal, body, check_budget=budget)
    transfers = plan_transfers(body, commands, targets, check_budget=budget)
    content_hash = request_content_hash(body)
    source_by_target = {targets[row.source_id]: row for row in body.document.rows}

    require_current_client(session, principal, body.sync_epoch, body.client_id)
    scopes = lock_scopes(
        session, _scope_ids(session, principal, commands, transfers, check_budget=budget)
    )
    for identifier in scopes:
        authorize_scope(session, principal, identifier, write=True)
    existing = session.get(ImportBatch, UUID(body.batch_id))
    if existing is not None:
        if existing.user_id != principal.user_id:
            raise ApiError("import_not_found", 404)
        if existing.content_hash != content_hash:
            raise ApiError("idempotency_mismatch", 409)
        if existing.result.get("publication_id") != (
            str(publication_id) if publication_id is not None else None
        ):
            raise ApiError("import_publication_context_required", 409)
        for identifier in existing.required_scopes:
            authorize_scope(session, principal, UUID(identifier), write=True)
        return {**deepcopy(existing.result), "status": existing.status, "replayed": True}
    batch = ImportBatch(
        id=UUID(body.batch_id),
        user_id=principal.user_id,
        client_id=principal.client_id,
        sync_epoch=UUID(body.sync_epoch),
        source_namespace=body.document.source_namespace,
        content_hash=content_hash,
        status="applied",
        required_scopes=[],
        result={},
        created_at=now(),
    )
    session.add(batch)
    session.flush()
    duplicate_ids = {
        command.entity_id
        for command in commands
        if _source_item(session, principal, body, source_by_target[command.entity_id].source_id)
        is not None
    }
    pending_transfers = lock_private_orphans(
        session,
        principal,
        transfers,
        _new_attachment_ids(commands, duplicate_ids),
        check_budget=budget,
    )
    transfer_receipts = []
    created, duplicates, changed, items = [], [], {}, []
    for position, command in enumerate(commands):
        budget()
        row = source_by_target[command.entity_id]
        item = _source_item(session, principal, body, row.source_id)
        if item is not None:
            if (
                item.source_hash != _import_source_hash(row, command, body, transfers)
                or session.get(ImportBatch, item.batch_id).status != "applied"
            ):
                raise ApiError("import_source_conflict", 409)
            entity = current_entity(session, item.entity_id)
            if (
                entity is None
                or entity.deleted
                or entity.revision != item.revision
                or digest(entity.payload) != item.payload_hash
            ):
                raise ApiError("import_source_modified", 409)
            duplicates.append(str(item.entity_id))
            continue
        if current_entity(session, UUID(command.entity_id)) is not None:
            raise ApiError("id_conflict", 409)
        move_available(
            session,
            principal,
            transfers,
            pending_transfers,
            scopes,
            transfer_receipts,
            check_budget=budget,
        )
        if not scope_set(session, principal, command).issubset(scopes):
            raise ApiError("import_scope_changed", 409)
        _lock_accounts(session, principal, command, None, scopes)
        try:
            entity, events = _apply_import_command(
                session, principal, command, scopes, body, row.source_id
            )
        except (CommandRejected, DomainError) as error:
            raise ApiError(error.code, getattr(error, "status", 422)) from None
        budget()
        for event in events:
            changed[(event.scope_id, event.entity_type, event.entity_id)] = event
        created.append(str(entity.id))
        item = ImportItem(
            user_id=principal.user_id,
            source_namespace=body.document.source_namespace,
            source_id=UUID(row.source_id),
            batch_id=batch.id,
            entity_id=entity.id,
            entity_type=entity.entity_type,
            scope_id=entity.scope_id,
            revision=entity.revision,
            payload_hash=digest(entity.payload),
            source_hash=_import_source_hash(row, command, body, transfers),
            position=position,
        )
        items.append(item)
        session.add(item)
    # Refresh final projections: a later receipt may have touched an earlier source.
    for key in changed:
        budget()
        if key[1] != "bill_private_finance":
            entity = current_entity(session, key[2])
            if entity is not None:
                refreshed = entity_event(session, entity)
                if refreshed.scope_id == key[0] and refreshed.entity_type == key[1]:
                    changed[key] = refreshed
    for item in items:
        budget()
        entity = current_entity(session, item.entity_id)
        item.revision, item.payload_hash = entity.revision, digest(entity.payload)
    published = None
    if publication_id is not None:
        published = publish_changes(
            session,
            scopes,
            list(changed.values()),
            publication_id,
            before_chunk=before_chunk,
            check_budget=budget,
        )
        commit_id, vector = None, published.scope_revisions
    elif changed:
        commit_id, vector = write_changes(session, scopes, list(changed.values()))
    else:
        commit_id, vector = None, {}
    if pending_transfers:
        raise ApiError("import_attachment_book_required", 422)
    result = {
        "batch_id": body.batch_id,
        "status": "applied",
        "created": created,
        "duplicates": duplicates,
        "commit_id": commit_id,
        "scope_revisions": vector,
        "replayed": False,
        "attachment_transfers": transfer_receipts,
    }
    if published is not None:
        result.update(publication_id=str(publication_id), commit_ids=list(published.commit_ids))
    batch.required_scopes, batch.result = [str(i) for i in sorted(scopes)], deepcopy(result)
    assert_active_principal(session, principal, lock=True)
    if before_commit:
        before_commit(result)
    budget()
    return result


def undo_import(
    session: Session, principal: Principal, batch_id: UUID, body: UndoRequest, *, before_commit=None
) -> dict:
    return run_transaction(
        session,
        lambda: undo_import_in_transaction(
            session, principal, batch_id, body, before_commit=before_commit
        ),
    )


def undo_import_in_transaction(
    session: Session,
    principal: Principal,
    batch_id: UUID,
    body: UndoRequest,
    *,
    before_commit=None,
    publication_id=None,
    before_chunk=None,
    check_budget=None,
) -> dict:
    if check_budget is not None and not callable(check_budget):
        raise TypeError("trusted_budget_callback_required")
    budget = check_budget if check_budget is not None else lambda: None
    budget()
    require_current_client(session, principal, body.sync_epoch, body.client_id)
    # All imports by one user lock its control scope before their batch row.
    lock_scopes(session, {principal.user_id})
    batch = session.get(ImportBatch, batch_id)
    if batch is None or batch.user_id != principal.user_id:
        raise ApiError("import_not_found", 404)
    if batch.result.get("publication_id") != (
        str(publication_id) if publication_id is not None else None
    ):
        raise ApiError("import_publication_context_required", 409)
    if batch.status == "undone":
        # Own operation metadata survives loss/deletion of the old scope;
        # it never returns an old scope vector or entity identities.
        result = {"batch_id": str(batch_id), "status": "undone", "replayed": True}
        if publication_id is not None:
            result["publication_id"] = str(publication_id)
        return result
    scopes = lock_scopes(session, {UUID(i) for i in batch.required_scopes})
    for identifier in scopes:
        authorize_scope(session, principal, identifier, write=True)
    items = list(
        session.scalars(
            select(ImportItem)
            .where(ImportItem.batch_id == batch_id)
            .order_by(ImportItem.position.desc())
        )
    )
    attachment_conflicts, transferred = undo_conflicts(
        session,
        principal,
        batch.result.get("attachment_transfers", []),
        scopes,
        {item.entity_id for item in items if item.entity_type == "bill"},
        lock=True,
        check_budget=budget,
    )
    # Preflight every item before touching any object; modified batches stay intact.
    conflicts = []
    for item in items:
        budget()
        entity = current_entity(session, item.entity_id)
        if (
            entity is None
            or entity.deleted
            or entity.revision != item.revision
            or digest(entity.payload) != item.payload_hash
        ):
            conflicts.append(str(item.entity_id))
    if conflicts or attachment_conflicts:
        raise ApiError("import_undo_conflict", 409)
    changed = {}
    for item in items:
        budget()
        entity = current_entity(session, item.entity_id)
        command = Operation.model_validate(
            {
                "operation_id": str(uuid5(batch.id, "undo:" + str(item.source_id))),
                "entity_id": str(entity.id),
                "entity_type": entity.entity_type,
                "scope_id": str(entity.scope_id),
                "action": "delete",
                "base_revision": str(entity.revision),
                "depends_on": None,
                "payload": {},
            }
        )
        if not scope_set(session, principal, command).issubset(scopes):
            raise ApiError("import_scope_changed", 409)
        _lock_accounts(session, principal, command, entity, scopes)
        try:
            _, events = apply_command(session, principal, command, entity, scopes)
        except (CommandRejected, DomainError) as error:
            raise ApiError(error.code, getattr(error, "status", 422)) from None
        budget()
        for event in events:
            changed[(event.scope_id, event.entity_type, event.entity_id)] = event
    restore_private_orphans(session, principal, transferred, check_budget=budget)
    published = None
    if publication_id is not None:
        # Different deterministic commit IDs for the reverse publication.
        published = publish_changes(
            session,
            scopes,
            list(changed.values()),
            uuid5(publication_id, "undo"),
            before_chunk=before_chunk,
            check_budget=budget,
        )
        commit_id, vector = None, published.scope_revisions
    else:
        commit_id, vector = (
            write_changes(session, scopes, list(changed.values())) if changed else (None, {})
        )
    batch.status = "undone"
    result = {
        "batch_id": str(batch_id),
        "status": "undone",
        "replayed": False,
        "commit_id": commit_id,
        "scope_revisions": vector,
    }
    if published is not None:
        result.update(publication_id=str(publication_id), commit_ids=list(published.commit_ids))
    assert_active_principal(session, principal, lock=True)
    if before_commit:
        before_commit(result)
    budget()
    return result


def preview_undo(session: Session, principal: Principal, batch_id: UUID) -> dict:
    def read():
        _principal(session, principal)
        batch = session.get(ImportBatch, batch_id)
        if batch is None or batch.user_id != principal.user_id:
            raise ApiError("import_not_found", 404)
        if batch.status == "undone":
            return {
                "batch_id": str(batch.id),
                "status": "undone",
                "conflicts": [],
                "attachment_conflicts": [],
                "can_undo": False,
                "created_count": len(batch.result.get("created", [])),
            }
        scopes = lock_scopes(session, {UUID(i) for i in batch.required_scopes})
        for identifier in scopes:
            authorize_scope(session, principal, identifier, write=True)
        items = list(
            session.scalars(
                select(ImportItem)
                .where(ImportItem.batch_id == batch_id)
                .order_by(ImportItem.position)
            )
        )
        conflicts = []
        for item in items:
            entity = current_entity(session, item.entity_id)
            if batch.status == "applied" and (
                entity is None
                or entity.deleted
                or entity.revision != item.revision
                or digest(entity.payload) != item.payload_hash
            ):
                conflicts.append(
                    {
                        "source_id": str(item.source_id),
                        "entity_id": str(item.entity_id),
                        "code": "modified_or_deleted",
                    }
                )
        attachment_conflicts, _ = undo_conflicts(
            session,
            principal,
            batch.result.get("attachment_transfers", []) if batch.status == "applied" else [],
            scopes,
            {item.entity_id for item in items if item.entity_type == "bill"},
        )
        return {
            "batch_id": str(batch.id),
            "status": batch.status,
            "conflicts": conflicts,
            "attachment_conflicts": attachment_conflicts,
            "can_undo": batch.status == "applied" and not conflicts and not attachment_conflicts,
            "created_count": len(items),
        }

    return run_transaction(session, read, repeatable=True)


def _history_cursor(batch):
    return (
        base64.urlsafe_b64encode(
            canonical({"created_at": batch.created_at.isoformat(), "batch_id": str(batch.id)})
        )
        .decode("ascii")
        .rstrip("=")
    )


def _read_history_cursor(value):
    if not isinstance(value, str) or not 1 <= len(value) <= 256:
        raise ApiError("import_history_cursor_invalid", 422)
    try:
        decoded = decode_json(
            base64.b64decode(value + "=" * (-len(value) % 4), altchars=b"-_", validate=True)
        )
        if not isinstance(decoded, dict) or set(decoded) != {"created_at", "batch_id"}:
            raise ValueError
        stamp, identifier = datetime.fromisoformat(decoded["created_at"]), UUID(decoded["batch_id"])
        if stamp.tzinfo is None or str(identifier) != decoded["batch_id"]:
            raise ValueError
        return stamp, identifier
    except (ValueError, TypeError, KeyError, UnicodeError):
        raise ApiError("import_history_cursor_invalid", 422) from None


def import_history(
    session: Session, principal: Principal, *, cursor=None, limit=100, batch_id: UUID | None = None
) -> dict:
    if type(limit) is not int or not 1 <= limit <= 100:
        raise ApiError("import_history_limit_invalid", 422)
    before = _read_history_cursor(cursor) if cursor is not None else None

    def read():
        _principal(session, principal)
        statement = select(ImportBatch).where(
            ImportBatch.user_id == principal.user_id,
        )
        if batch_id is not None:
            statement = statement.where(ImportBatch.id == batch_id)
        if before is not None:
            statement = statement.where(
                or_(
                    ImportBatch.created_at < before[0],
                    and_(ImportBatch.created_at == before[0], ImportBatch.id < before[1]),
                )
            )
        rows = list(
            session.scalars(
                statement.order_by(ImportBatch.created_at.desc(), ImportBatch.id.desc()).limit(
                    limit + 1
                )
            )
        )
        has_more = len(rows) > limit
        rows = rows[:limit]
        result = []
        for batch in rows:
            result.append(
                {
                    "batch_id": str(batch.id),
                    "status": batch.status,
                    "source_namespace": batch.source_namespace,
                    "created_at": batch.created_at.isoformat(),
                    "created_count": len(batch.result.get("created", [])),
                    "duplicate_count": len(batch.result.get("duplicates", [])),
                }
            )
        return {
            "batches": result,
            "limit": limit,
            "has_more": has_more,
            "next_cursor": _history_cursor(rows[-1]) if has_more else None,
        }

    return run_transaction(session, read, repeatable=True)
