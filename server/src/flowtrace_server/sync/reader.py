"""Permission-bound immutable pull pages and atomically materialized snapshots."""

import heapq
import secrets
from collections import defaultdict
from copy import deepcopy
from datetime import timedelta
from time import monotonic
from uuid import UUID, uuid4

from sqlalchemy import and_, func, or_, select
from sqlalchemy.orm import Session

from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import assert_active_principal, digest, now
from flowtrace_server.books.models import SyncScope
from flowtrace_server.books.permissions import authorize_scope
from flowtrace_server.imports.staging_models import ImportPublicationChunk

from .canonical import content_hash
from .common import (
    MATERIALIZE_SECONDS,
    MAX_PAGES,
    MAX_PULL_EVENTS,
    MAX_SNAPSHOT_ITEMS,
    PAGE_MINUTES,
    PendingEvent,
    current_entity,
    lock_scopes,
    require_current_client,
    run_transaction,
    visible_entity,
    visible_scopes,
)
from .models import PullPage, PullSession, SnapshotPage, SyncChange, SyncEntity, SyncSnapshot
from .projections import account_links, entity_event, event_dict


def _authorized_vector(session, principal, requested=None):
    available = {scope.id for scope in visible_scopes(session, principal)}
    identifiers = available if requested is None else {UUID(value) for value in requested}
    if not identifiers.issubset(available):
        raise ApiError("scope_forbidden", 403)
    # Membership mutations also lock this user's control scope. Holding only
    # that control row stabilizes authorization without blocking on another
    # user's uncommitted financial scope revision. RR still sees committed 40
    # while a writer holds an uncommitted 41, exactly as the pull contract needs.
    scopes = lock_scopes(session, {principal.user_id})
    rows = session.scalars(select(SyncScope).where(SyncScope.id.in_(identifiers)))
    scopes.update({scope.id: scope for scope in rows})
    for identifier in identifiers:
        authorize_scope(session, principal, identifier)
    return scopes, identifiers


def _versions(scopes, identifiers):
    return {
        str(identifier): str(scopes[identifier].permission_version)
        for identifier in sorted(identifiers)
    }


def _checkpoint(scopes, identifiers):
    return {str(identifier): str(scopes[identifier].revision) for identifier in sorted(identifiers)}


def _binding(session, principal, record, state, *, allow_expired=False):
    if record.user_id != principal.user_id or record.client_id != principal.client_id:
        raise ApiError("not_found", 404)
    if record.sync_epoch != state.sync_epoch:
        raise ApiError("epoch_changed", 409)
    scopes, identifiers = _authorized_vector(session, principal, record.permission_versions)
    if (
        scopes[principal.user_id].permission_version != record.control_version
        or _versions(scopes, identifiers) != record.permission_versions
    ):
        raise ApiError("permission_changed", 410)
    if record.expires_at <= now() and not allow_expired:
        raise ApiError("sync_page_expired", 410)


def list_scopes(session: Session, principal: Principal):
    def read():
        state, client = require_current_client(session, principal, rebuild_read=True)
        scopes, identifiers = _authorized_vector(session, principal)
        current = {str(value) for value in identifiers}
        revoked = sorted(set(client.known_scope_ids) - current)
        client.known_scope_ids = sorted(current)
        result = {
            "sync_epoch": str(state.sync_epoch),
            "control_version": str(scopes[principal.user_id].permission_version),
            "scopes": [
                {
                    "scope_id": str(identifier),
                    "kind": scopes[identifier].kind,
                    "role": authorize_scope(session, principal, identifier).role,
                    "revision": str(scopes[identifier].revision),
                    "permission_version": str(scopes[identifier].permission_version),
                }
                for identifier in sorted(identifiers)
            ],
            "revoked_scope_ids": revoked,
            "requires_rebuild": client.frozen,
        }
        return result

    return run_transaction(session, read, repeatable=True)


def _change_dict(change):
    return event_dict(
        PendingEvent(
            change.scope_id,
            change.entity_type,
            change.entity_id,
            change.revision,
            change.deleted,
            change.data,
        ),
        change.scope_revision,
        change.event_index,
    )


def _ordered_commits(changes):
    """Topological per-scope order, with a stable UUID tie-break for disjoint work."""
    by_commit, by_scope = defaultdict(list), defaultdict(list)
    for change in changes:
        by_commit[change.commit_id].append(change)
        by_scope[change.scope_id].append(change)
    edges, indegree = {key: set() for key in by_commit}, {key: 0 for key in by_commit}
    for rows in by_scope.values():
        previous = None
        for change in sorted(rows, key=lambda row: (row.scope_revision, row.event_index)):
            current = change.commit_id
            if previous is not None and previous != current and current not in edges[previous]:
                edges[previous].add(current)
                indegree[current] += 1
            previous = current
    ready = [identifier for identifier, count in indegree.items() if count == 0]
    heapq.heapify(ready)
    ordered = []
    while ready:
        identifier = heapq.heappop(ready)
        rows = sorted(
            by_commit[identifier],
            key=lambda row: (row.scope_id, row.scope_revision, row.event_index),
        )
        if len(rows) > 200:
            raise ApiError("sync_projection_invalid", 503)
        ordered.append(
            {"commit_id": str(identifier), "events": [_change_dict(row) for row in rows]}
        )
        for successor in edges[identifier]:
            indegree[successor] -= 1
            if indegree[successor] == 0:
                heapq.heappush(ready, successor)
    if len(ordered) != len(by_commit):
        raise ApiError("sync_projection_invalid", 503)
    return ordered


def _commit_pages(commits, limit):
    pages, page, count = [], [], 0
    for commit in commits:
        size = len(commit["events"])
        if page and count + size > limit:
            pages.append(page)
            page, count = [], 0
        page.append(commit)
        count += size
    pages.append(page)
    if len(pages) > MAX_PAGES:
        raise ApiError("resync_required", 410)
    return pages


def _require_legacy_atomic_projection(session, commit_ids, identifiers):
    """V1 pages cannot install a multi-commit publication atomically.

    Its snapshot path already stages a complete fixed view before installing.
    Keep stored pages and hashes unchanged; refuse an unsafe incremental read
    with the existing recovery response, including an older materialized page.
    Count only currently authorized chunks and never expose private metadata.
    """
    if not commit_ids:
        return
    publications = select(ImportPublicationChunk.publication_id).where(
        ImportPublicationChunk.commit_id.in_(commit_ids)
    )
    multiple = session.scalar(
        select(ImportPublicationChunk.publication_id)
        .join(SyncChange, SyncChange.commit_id == ImportPublicationChunk.commit_id)
        .where(
            ImportPublicationChunk.publication_id.in_(publications),
            SyncChange.scope_id.in_(identifiers),
        )
        .group_by(ImportPublicationChunk.publication_id)
        .having(func.count(func.distinct(ImportPublicationChunk.commit_id)) > 1)
        .limit(1)
    )
    if multiple is not None:
        raise ApiError("resync_required", 410)


def pull(session: Session, principal: Principal, body):
    def read():
        state, _ = require_current_client(session, principal, body.sync_epoch)
        if body.page_token is not None:
            page = session.get(PullPage, digest(body.page_token))
            record = session.get(PullSession, page.pull_id) if page else None
            if record is None:
                raise ApiError("not_found", 404)
            _binding(session, principal, record, state)
            if body.cursors != record.cursors or body.limit != record.page_limit:
                raise ApiError("pull_intent_mismatch", 400)
            _require_legacy_atomic_projection(
                session,
                {UUID(commit["commit_id"]) for commit in page.response["commits"]},
                {UUID(scope) for scope in record.permission_versions},
            )
            return deepcopy(page.response)
        started = monotonic()
        scopes, identifiers = _authorized_vector(session, principal)
        if not {UUID(key) for key in body.cursors}.issubset(identifiers):
            raise ApiError("scope_forbidden", 403)
        checkpoint = _checkpoint(scopes, identifiers)
        if any(int(value) > int(checkpoint[key]) for key, value in body.cursors.items()):
            raise ApiError("invalid_cursor", 409)
        conditions = [
            and_(
                SyncChange.scope_id == identifier,
                SyncChange.scope_revision > int(body.cursors.get(str(identifier), "0")),
                SyncChange.scope_revision <= scopes[identifier].revision,
            )
            for identifier in identifiers
        ]
        selected = list(
            session.scalars(select(SyncChange).where(or_(*conditions)).limit(MAX_PULL_EVENTS + 1))
        )
        if len(selected) > MAX_PULL_EVENTS:
            raise ApiError("resync_required", 410)
        # An arbitrary cursor vector must not split a cross-domain commit. Send
        # its complete currently authorized group, allowing safe duplicate events.
        commits = {change.commit_id for change in selected}
        _require_legacy_atomic_projection(session, commits, identifiers)
        changes = (
            list(
                session.scalars(
                    select(SyncChange).where(
                        SyncChange.commit_id.in_(commits), SyncChange.scope_id.in_(identifiers)
                    )
                )
            )
            if commits
            else []
        )
        if len(changes) > MAX_PULL_EVENTS or monotonic() - started > MATERIALIZE_SECONDS:
            raise ApiError("resync_required", 410)
        grouped = _commit_pages(_ordered_commits(changes), body.limit)
        record = PullSession(
            id=uuid4(),
            user_id=principal.user_id,
            client_id=principal.client_id,
            sync_epoch=state.sync_epoch,
            control_version=scopes[principal.user_id].permission_version,
            permission_versions=_versions(scopes, identifiers),
            checkpoint=checkpoint,
            cursors=body.cursors,
            page_limit=body.limit,
            expires_at=now() + timedelta(minutes=PAGE_MINUTES),
        )
        session.add(record)
        session.flush()
        tokens = [secrets.token_urlsafe(32) for _ in grouped]
        responses = []
        for index, commits_page in enumerate(grouped):
            response = {
                "sync_epoch": str(state.sync_epoch),
                "commits": commits_page,
                "next_page_token": tokens[index + 1] if index + 1 < len(tokens) else None,
                "checkpoint": checkpoint if index == len(tokens) - 1 else None,
            }
            session.add(
                PullPage(
                    token_hash=digest(tokens[index]),
                    pull_id=record.id,
                    page_index=index,
                    response=response,
                )
            )
            responses.append(response)
        assert_active_principal(session, principal, lock=True)
        return responses[0]

    return run_transaction(session, read, repeatable=True)


def _snapshot_items(session, principal, scopes, identifiers):
    started, items = monotonic(), []
    entities = session.scalars(
        select(SyncEntity)
        .where(SyncEntity.scope_id.in_(identifiers), SyncEntity.deleted.is_(False))
        .order_by(SyncEntity.scope_id, SyncEntity.entity_type, SyncEntity.id)
        .limit(MAX_SNAPSHOT_ITEMS + 1)
    )
    for entity in entities:
        items.append(
            event_dict(
                entity_event(session, entity), scopes[entity.scope_id].revision, len(items) % 200
            )
        )
        if len(items) > MAX_SNAPSHOT_ITEMS or monotonic() - started > MATERIALIZE_SECONDS:
            raise ApiError("snapshot_limit", 413)
    if principal.user_id in identifiers:
        # Use the last financial event, not a current full shared bill. A later
        # shared note edit/revocation cannot leak into this private projection.
        ranked = (
            select(
                SyncChange.scope_id,
                SyncChange.scope_revision,
                SyncChange.event_index,
                func.row_number()
                .over(
                    partition_by=SyncChange.entity_id,
                    order_by=(SyncChange.scope_revision.desc(), SyncChange.event_index.desc()),
                )
                .label("rank"),
            )
            .where(
                SyncChange.scope_id == principal.user_id,
                SyncChange.entity_type == "bill",
            )
            .subquery()
        )
        rows = session.scalars(
            select(SyncChange)
            .join(
                ranked,
                and_(
                    SyncChange.scope_id == ranked.c.scope_id,
                    SyncChange.scope_revision == ranked.c.scope_revision,
                    SyncChange.event_index == ranked.c.event_index,
                ),
            )
            .where(ranked.c.rank == 1)
            .order_by(SyncChange.entity_id)
            .limit(MAX_SNAPSHOT_ITEMS + 1)
        )
        seen = set()
        for row in rows:
            if row.entity_id in seen:
                continue
            seen.add(row.entity_id)
            if (
                not row.deleted
                and row.data
                and row.data["projection_kind"] == "bill_private_finance"
            ):
                items.append(
                    event_dict(
                        PendingEvent(
                            row.scope_id, "bill", row.entity_id, row.revision, False, row.data
                        ),
                        scopes[row.scope_id].revision,
                        len(items) % 200,
                    )
                )
            if len(items) > MAX_SNAPSHOT_ITEMS or monotonic() - started > MATERIALIZE_SECONDS:
                raise ApiError("snapshot_limit", 413)
    return items


def _snapshot_status(record, *, expired=False):
    ready = record.status == "ready" and not expired
    return {
        "snapshot_id": str(record.id),
        "status": "expired" if expired else record.status,
        "expires_at": record.expires_at.isoformat(),
        "sync_epoch": str(record.sync_epoch),
        "checkpoint": record.manifest["checkpoint"] if ready else None,
        "permission_versions": record.permission_versions,
        "first_page_token": record.first_page_token if ready else None,
        "manifest_sha256": record.manifest_sha256 if ready else None,
        "manifest": record.manifest if ready else None,
    }


def create_snapshot(session: Session, principal: Principal, body):
    def materialize():
        state, _ = require_current_client(
            session, principal, body.sync_epoch, body.client_id, rebuild_read=True
        )
        scopes, identifiers = _authorized_vector(session, principal, body.scope_ids)
        items = _snapshot_items(session, principal, scopes, identifiers)
        pages = [items[index : index + 200] for index in range(0, len(items), 200)] or [[]]
        if len(pages) > MAX_PAGES:
            raise ApiError("snapshot_limit", 413)
        tokens = [secrets.token_urlsafe(32) for _ in pages]
        identifier = uuid4()
        manifest = {
            "snapshot_id": str(identifier),
            "instance_id": str(state.instance_id),
            "sync_epoch": str(state.sync_epoch),
            "checkpoint": _checkpoint(scopes, identifiers),
            "permission_versions": _versions(scopes, identifiers),
            "pages": [
                {"page_index": index, "item_count": len(page), "sha256": content_hash(page)}
                for index, page in enumerate(pages)
            ],
        }
        record = SyncSnapshot(
            id=identifier,
            user_id=principal.user_id,
            client_id=principal.client_id,
            sync_epoch=state.sync_epoch,
            control_version=scopes[principal.user_id].permission_version,
            permission_versions=manifest["permission_versions"],
            status="ready",
            manifest=manifest,
            manifest_sha256=content_hash(manifest),
            first_page_token=tokens[0],
            expires_at=now() + timedelta(minutes=PAGE_MINUTES),
        )
        session.add(record)
        session.flush()
        for index, page in enumerate(pages):
            session.add(
                SnapshotPage(
                    token_hash=digest(tokens[index]),
                    snapshot_id=identifier,
                    page_index=index,
                    response={
                        "snapshot_id": str(identifier),
                        "items": page,
                        "page_index": index,
                        "page_sha256": manifest["pages"][index]["sha256"],
                        "next_page_token": tokens[index + 1] if index + 1 < len(tokens) else None,
                    },
                )
            )
        assert_active_principal(session, principal, lock=True)
        return _snapshot_status(record)

    return run_transaction(session, materialize, repeatable=True)


def snapshot_status(session: Session, principal: Principal, identifier: UUID):
    def read():
        state, _ = require_current_client(session, principal, rebuild_read=True)
        record = session.get(SyncSnapshot, identifier)
        if (
            record is None
            or record.user_id != principal.user_id
            or record.client_id != principal.client_id
        ):
            raise ApiError("not_found", 404)
        if record.expires_at <= now():
            # Expiration reveals no manifest or old projection content.
            _binding(session, principal, record, state, allow_expired=True)
            return _snapshot_status(record, expired=True)
        _binding(session, principal, record, state)
        return _snapshot_status(record)

    return run_transaction(session, read, repeatable=True)


def snapshot_page(session: Session, principal: Principal, identifier: UUID, body):
    def read():
        state, _ = require_current_client(
            session, principal, client_id=body.client_id, rebuild_read=True
        )
        record = session.get(SyncSnapshot, identifier)
        page = session.get(SnapshotPage, digest(body.page_token))
        if record is None or page is None or page.snapshot_id != identifier:
            raise ApiError("not_found", 404)
        _binding(session, principal, record, state)
        return deepcopy(page.response)

    return run_transaction(session, read, repeatable=True)


def read_entity(
    session: Session, principal: Principal, entity_type: str, entity_id: UUID, scope_id: UUID
):
    def read():
        require_current_client(session, principal, rebuild_read=True)
        scopes, _ = _authorized_vector(session, principal, [str(scope_id)])
        entity = current_entity(session, entity_id)
        if entity is None or entity.entity_type != entity_type:
            raise ApiError("not_found", 404)
        if entity.deleted:
            # A fresh read can confirm deletion without retaining any old
            # payload. A move's historical source is still not this entity's
            # actual domain and must not be treated as its current location.
            if entity.scope_id != scope_id:
                raise ApiError("not_found", 404)
            return {
                "event": event_dict(entity_event(session, entity), scopes[scope_id].revision),
                "editable_payload": None,
            }
        if entity.scope_id != scope_id:
            if scope_id != principal.user_id or entity_type != "bill":
                raise ApiError("not_found", 404)
            change = session.scalar(
                select(SyncChange)
                .where(
                    SyncChange.scope_id == scope_id,
                    SyncChange.entity_id == entity_id,
                    SyncChange.entity_type == "bill",
                )
                .order_by(SyncChange.scope_revision.desc(), SyncChange.event_index.desc())
                .limit(1)
            )
            if (
                change is None
                or change.deleted
                or change.data["projection_kind"] != "bill_private_finance"
            ):
                raise ApiError("not_found", 404)
            return {"event": _change_dict(change), "editable_payload": None}
        grant = authorize_scope(session, principal, scope_id)
        editable = grant.role != "viewer" and (entity_type != "book" or grant.role == "owner")
        if editable and entity_type == "bill":
            try:
                for account_id in account_links(entity.payload).values():
                    target = visible_entity(session, principal, account_id, "account")
                    authorize_scope(session, principal, target.scope_id, write=True)
                for item in entity.payload["allocations"]:
                    target = visible_entity(
                        session, principal, UUID(item["source_bill_id"]), "bill"
                    )
                    authorize_scope(session, principal, target.scope_id, write=True)
            except ApiError:
                editable = False
        return {
            "event": event_dict(entity_event(session, entity), scopes[scope_id].revision),
            "editable_payload": deepcopy(entity.payload) if editable else None,
        }

    return run_transaction(session, read, repeatable=True)
