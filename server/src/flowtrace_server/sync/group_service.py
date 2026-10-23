"""Private, authority-bound finite-step group-sync persistence.

Standalone wrappers own transactions; no router/capability is activated here.
All rows, including expired ones, retain their reservation until actually GC'd.
Token seeds live only in internal staging state, never in returned DTOs/logs.
"""

import base64
import hashlib
import hmac
import json
import secrets
from copy import deepcopy
from datetime import UTC, timedelta
from uuid import UUID, uuid4

from pydantic import ValidationError
from sqlalchemy import delete, func, select

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import assert_active_principal, digest, now

from .canonical import canonical_bytes, content_hash
from .common import PAGE_MINUTES, require_current_client
from .group_budget import group_transaction
from .group_models import GroupPullPage, GroupPullSession, GroupPullUnit
from .group_reader import GroupReadError, GroupReadLimits
from .group_schemas import (
    GroupDataPage,
    GroupPullCreate,
    GroupPullListing,
    GroupPullManifest,
    GroupPullPageRequest,
    GroupPullStatus,
    GroupPullStep,
    GroupUnitIndexPage,
    GroupUnitManifestPage,
    page_hash_payload,
    unit_manifest_hash,
)
from .reader import _authorized_vector, _checkpoint, _versions


def opaque_token(record, purpose, unit_index, page_index):
    message = canonical_bytes(
        {
            "protocol": "group-sync-v1",
            "purpose": purpose,
            "pull_id": str(record.id),
            "unit_index": unit_index,
            "page_index": page_index,
        }
    )
    value = hmac.new(
        bytes.fromhex(record.build_state["token_seed"]), message, hashlib.sha256
    ).digest()
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def internal_state_bytes(value):
    # Trusted private planner offsets include -1 sentinels. They never enter
    # strict v1 canonical wire JSON (whose integer controls are unsigned).
    return json.dumps(
        value, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def reserve_bytes(session, record, amount, limits):
    if type(amount) is not int:
        raise ValueError("group_reservation_invalid")
    others = session.scalar(
        select(func.coalesce(func.sum(GroupPullSession.reserved_bytes), 0)).where(
            GroupPullSession.user_id == record.user_id, GroupPullSession.id != record.id
        )
    )
    reserved = record.reserved_bytes + amount
    if reserved < 0 or reserved > limits.session_bytes or others + reserved > limits.session_bytes:
        raise ApiError("group_storage_quota", 413)
    record.reserved_bytes = reserved


def store_page(session, record, *, kind, unit_index, page_index, response, limits):
    raw = canonical_bytes(response)
    if len(raw) > limits.page_bytes:
        raise ApiError("group_page_limit", 413)
    token = opaque_token(record, kind, unit_index, page_index)
    identifier = digest(token)
    existing = session.get(GroupPullPage, identifier)
    if existing is not None:
        if existing.pull_id != record.id or canonical_bytes(existing.response) != raw:
            raise ApiError("group_page_conflict", 409)
        return existing
    if record.page_count >= limits.pages:
        raise ApiError("group_page_limit", 413)
    reserve_bytes(session, record, len(raw), limits)
    page = GroupPullPage(
        token_hash=identifier,
        pull_id=record.id,
        unit_index=unit_index,
        kind=kind,
        page_index=page_index,
        response=json.loads(raw),
        sha256=response.get("page_sha256", content_hash(response)),
        size_bytes=len(raw),
    )
    session.add(page)
    record.page_count += 1
    session.flush()
    return page


def _status(record, *, expired=False):
    ready = record.status == "ready" and not expired
    state = "expired" if expired else record.status
    body = {
        "pull_id": str(record.id),
        "request_id": str(record.request_id),
        "sync_epoch": str(record.sync_epoch),
        "expires_at": record.expires_at.astimezone(UTC).isoformat(),
        "status": state,
        "progress_code": "expired"
        if expired
        else state
        if state in {"planning", "materializing", "ready"}
        else "unavailable",
        "next_step_token": opaque_token(record, "step", None, record.build_state["step_index"])
        if state in {"planning", "materializing"}
        else None,
        "manifest": deepcopy(record.manifest) if ready else None,
        "manifest_sha256": record.manifest_sha256 if ready else None,
        "first_page_token": record.first_page_token if ready else None,
    }
    try:
        return GroupPullStatus.model_validate(body).model_dump(mode="json")
    except (ValidationError, ValueError, KeyError):
        raise ApiError("group_projection_invalid", 503) from None


def _owned(session, principal, identifier, *, lock=False):
    query = select(GroupPullSession).where(GroupPullSession.id == identifier)
    if lock:
        query = query.with_for_update()
    record = session.scalar(query)
    if (
        record is None
        or record.user_id != principal.user_id
        or record.client_id != principal.client_id
    ):
        raise ApiError("not_found", 404)
    return record


def _binding(session, principal, record, *, allow_expired=False):
    if record.build_state.get("collected") is True:
        raise ApiError("group_pull_collected", 410)
    state, _ = require_current_client(
        session, principal, str(record.sync_epoch), str(record.client_id)
    )
    if (
        record.origin_session_id != principal.session_id
        or record.origin_purpose != principal.purpose
    ):
        raise ApiError("group_origin_changed", 409)
    if str(state.instance_id) != record.build_state["instance_id"]:
        raise ApiError("epoch_changed", 409)
    scopes, identifiers = _authorized_vector(session, principal, record.permission_versions)
    if (
        scopes[principal.user_id].permission_version != record.control_version
        or _versions(scopes, identifiers) != record.permission_versions
    ):
        raise ApiError("permission_changed", 410)
    if record.expires_at <= now() and not allow_expired:
        raise ApiError("group_pull_expired", 410)
    return state


def create_group_pull(session, principal, body: GroupPullCreate, *, limits=GroupReadLimits()):
    def create(budget):
        assert_active_principal(session, principal, lock=True)
        if body.client_id != str(principal.client_id):
            raise ApiError("client_mismatch", 403)
        intent = content_hash(body.model_dump(mode="json"))
        old = session.scalar(
            select(GroupPullSession).where(
                GroupPullSession.user_id == principal.user_id,
                GroupPullSession.client_id == principal.client_id,
                GroupPullSession.sync_epoch == UUID(body.sync_epoch),
                GroupPullSession.request_id == UUID(body.request_id),
            )
        )
        # Same request recovery precedes any new reservation/quota decision.
        if old is not None:
            if old.build_state.get("collected") is True or old.expires_at <= now():
                raise ApiError("group_pull_expired", 410)
            _binding(session, principal, old)
            if old.intent_hash != intent:
                raise ApiError("group_intent_mismatch", 409)
            return _status(old)
        state, _ = require_current_client(session, principal, body.sync_epoch, body.client_id)
        scopes, identifiers = _authorized_vector(session, principal)
        checkpoint = _checkpoint(scopes, identifiers)
        if len(identifiers) > limits.scopes or not set(body.cursors).issubset(checkpoint):
            raise ApiError("scope_forbidden", 403)
        if any(int(value) > int(checkpoint[key]) for key, value in body.cursors.items()):
            raise ApiError("invalid_cursor", 409)
        count = session.scalar(
            select(func.count())
            .select_from(GroupPullSession)
            .where(
                GroupPullSession.user_id == principal.user_id,
                GroupPullSession.build_state.contains({"collected": True}).is_not(True),
            )
        )
        if count >= limits.retained_sessions:
            raise ApiError("group_session_quota", 409)
        stamp = now()
        record = GroupPullSession(
            id=uuid4(),
            user_id=principal.user_id,
            client_id=principal.client_id,
            request_id=UUID(body.request_id),
            sync_epoch=state.sync_epoch,
            origin_session_id=principal.session_id,
            origin_purpose=principal.purpose,
            control_version=scopes[principal.user_id].permission_version,
            intent_hash=intent,
            base_cursors=dict(body.cursors),
            checkpoint=checkpoint,
            permission_versions=_versions(scopes, identifiers),
            status="planning",
            build_state={
                "instance_id": str(state.instance_id),
                "token_seed": secrets.token_hex(32),
                "step_index": 0,
                "phase": "discover",
                "scope_index": 0,
                "scan_revision": None,
                "scan_event_index": 199,
                "discovered_events": 0,
                "next_unit": 0,
                "planned_events": 0,
                "topological_next": 0,
                "prefix": {key: body.cursors.get(key, "0") for key in checkpoint},
            },
            next_step_token_hash=None,
            reserved_bytes=0,
            unit_count=0,
            page_count=0,
            manifest=None,
            manifest_sha256=None,
            first_page_token=None,
            created_at=stamp,
            expires_at=stamp + timedelta(minutes=PAGE_MINUTES),
        )
        session.add(record)
        session.flush()
        reserve_bytes(
            session,
            record,
            len(
                canonical_bytes(
                    {
                        "base": record.base_cursors,
                        "target": record.checkpoint,
                        "permissions": record.permission_versions,
                        "state": record.build_state,
                    }
                )
            ),
            limits,
        )
        record.next_step_token_hash = digest(opaque_token(record, "step", None, 0))
        assert_active_principal(session, principal, lock=True)
        return _status(record)

    return group_transaction(session, create, repeatable=True, seconds=limits.step_seconds)


def step_group_pull(
    session,
    principal,
    identifier: UUID,
    body: GroupPullStep,
    *,
    limits=GroupReadLimits(),
    work_limit=32,
):
    def step(budget):
        assert_active_principal(session, principal, lock=True)
        if body.client_id != str(principal.client_id):
            raise ApiError("client_mismatch", 403)
        record = _owned(session, principal, identifier, lock=True)
        _binding(session, principal, record)
        prior = session.get(GroupPullPage, digest(body.step_token))
        if prior is not None and prior.pull_id == record.id and prior.kind == "step":
            # Immutable original response, after current authority/TTL validation.
            return deepcopy(prior.response)
        if record.status == "ready" or not hmac.compare_digest(
            digest(body.step_token), record.next_step_token_hash or ""
        ):
            raise ApiError("group_step_mismatch", 409)
        from .group_materializer import materialize_step

        state = deepcopy(record.build_state)
        step_index = state["step_index"]
        try:
            materialize_step(
                session, record, state, limits=limits, work_limit=work_limit, budget=budget
            )
        except GroupReadError as error:
            code = str(error)
            raise ApiError(
                "group_limit"
                if code.endswith("limit") or code.endswith("too_large")
                else "group_projection_invalid",
                413 if code.endswith("limit") or code.endswith("too_large") else 503,
            ) from None
        state["step_index"] += 1
        reserve_bytes(
            session,
            record,
            len(internal_state_bytes(state)) - len(internal_state_bytes(record.build_state)),
            limits,
        )
        record.build_state = state
        record.next_step_token_hash = (
            None
            if record.status == "ready"
            else digest(opaque_token(record, "step", None, state["step_index"]))
        )
        result = _status(record)
        store_page(
            session,
            record,
            kind="step",
            unit_index=None,
            page_index=step_index,
            response=result,
            limits=limits,
        )
        assert_active_principal(session, principal, lock=True)
        return result

    return group_transaction(session, step, seconds=limits.step_seconds)


def discard_group_pull(session, principal, identifier: UUID):
    """Actually remove owned staging, retaining an immutable request tombstone.

    Current API authentication is mandatory. Old origin, epoch, device or scope
    permission is deliberately not required to remove only this user's cache.
    """

    def discard(budget):
        assert_active_principal(session, principal, lock=True)
        if principal.purpose not in {"api_native", "api_web"}:
            raise ApiError("session_purpose_invalid", 403)
        record = session.scalar(
            select(GroupPullSession).where(GroupPullSession.id == identifier).with_for_update()
        )
        if record is None or record.user_id != principal.user_id:
            raise ApiError("not_found", 404)
        session.execute(delete(GroupPullPage).where(GroupPullPage.pull_id == record.id))
        session.execute(delete(GroupPullUnit).where(GroupPullUnit.pull_id == record.id))
        record.status = "failed"
        record.build_state = {"collected": True}
        record.next_step_token_hash = None
        record.manifest = record.manifest_sha256 = record.first_page_token = None
        record.reserved_bytes = record.page_count = record.unit_count = 0
        # These vectors are no longer history retention pins or private cache.
        record.base_cursors = record.checkpoint = record.permission_versions = {}
        assert_active_principal(session, principal, lock=True)
        return {"pull_id": str(record.id), "status": "collected"}

    return group_transaction(session, discard)


def list_group_pulls(session, principal):
    """Recover safe owned handles when a create response was lost.

    No old origin/epoch/scope authority is needed for this metadata. A caller
    must explicitly match its own persisted request before discarding; this
    service never auto-deletes another device's active pull.
    """

    def read(budget):
        assert_active_principal(session, principal, lock=True)
        if principal.purpose not in {"api_native", "api_web"}:
            raise ApiError("session_purpose_invalid", 403)
        rows = session.scalars(
            select(GroupPullSession)
            .where(
                GroupPullSession.user_id == principal.user_id,
                GroupPullSession.build_state.contains({"collected": True}).is_not(True),
            )
            .order_by(GroupPullSession.created_at, GroupPullSession.id)
            .limit(3)
        ).all()
        if len(rows) > 2:
            raise ApiError("group_list_inconsistent", 503)
        return GroupPullListing(
            pulls=[
                {
                    "pull_id": str(row.id),
                    "request_id": str(row.request_id),
                    "client_id": str(row.client_id),
                    "sync_epoch": str(row.sync_epoch),
                    "status": row.status,
                    "expires_at": row.expires_at.astimezone(UTC).isoformat(),
                }
                for row in rows
            ]
        ).model_dump(mode="json")

    return group_transaction(session, read)


def group_pull_status(session, principal, identifier: UUID, *, client_id: str):
    def read(budget):
        assert_active_principal(session, principal, lock=True)
        if client_id != str(principal.client_id):
            raise ApiError("client_mismatch", 403)
        record = _owned(session, principal, identifier)
        _binding(session, principal, record, allow_expired=True)
        return _status(record, expired=record.expires_at <= now())

    return group_transaction(session, read)


def _validated_page(page):
    models = {"index": GroupUnitIndexPage, "manifest": GroupUnitManifestPage, "data": GroupDataPage}
    value = models[page.kind].model_validate(page.response).model_dump(mode="json")
    if (
        value["page_sha256"] != page.sha256
        or len(canonical_bytes(value)) != page.size_bytes
        or value["page_sha256"] != content_hash(page_hash_payload(value))
    ):
        raise ValueError("group_page_integrity")
    return value


def _index_binding(session, record, manifest, page):
    value = _validated_page(page)
    descriptor = next(
        (item for item in manifest["index_pages"] if item["page_index"] == page.page_index), None
    )
    if descriptor != {
        "page_index": page.page_index,
        "sha256": page.sha256,
        "item_count": len(value["units"]),
    }:
        raise ValueError("group_index_integrity")
    return value


def _page_chain(session, record, manifest, page):
    value = _validated_page(page)
    if value["pull_id"] != str(record.id) or value["page_index"] != page.page_index:
        raise ValueError("group_page_binding")
    if page.kind == "index":
        return _index_binding(session, record, manifest, page)
    unit = session.get(GroupPullUnit, (record.id, page.unit_index))
    if unit is None or value["group_id"] != str(unit.group_id):
        raise ValueError("group_unit_binding")
    index = session.scalar(
        select(GroupPullPage).where(
            GroupPullPage.pull_id == record.id,
            GroupPullPage.kind == "index",
            GroupPullPage.response["units"].contains([{"group_id": str(unit.group_id)}]),
        )
    )
    if index is None:
        raise ValueError("group_unit_index_missing")
    units = _index_binding(session, record, manifest, index)["units"]
    descriptor = next(item for item in units if item["group_id"] == str(unit.group_id))
    if descriptor["manifest_sha256"] != unit_manifest_hash(str(record.id), descriptor):
        raise ValueError("group_unit_manifest_integrity")
    if page.kind == "manifest":
        parts, count = (
            descriptor["manifest_parts"],
            len(value["commits"]) + len(value["data_pages"]),
        )
    else:
        manifest_page = session.scalar(
            select(GroupPullPage).where(
                GroupPullPage.pull_id == record.id,
                GroupPullPage.unit_index == unit.unit_index,
                GroupPullPage.kind == "manifest",
                GroupPullPage.response["data_pages"].contains([{"page_index": page.page_index}]),
            )
        )
        if manifest_page is None:
            raise ValueError("group_data_manifest_missing")
        checked = _validated_page(manifest_page)
        expected = {
            "page_index": manifest_page.page_index,
            "sha256": manifest_page.sha256,
            "item_count": len(checked["commits"]) + len(checked["data_pages"]),
        }
        if expected not in descriptor["manifest_parts"]:
            raise ValueError("group_data_manifest_integrity")
        parts, count = (
            checked["data_pages"],
            sum(len(item["events"]) for item in value["fragments"]),
        )
    if {"page_index": page.page_index, "sha256": page.sha256, "item_count": count} not in parts:
        raise ValueError("group_part_integrity")
    return value


def read_group_pull_page(session, principal, identifier: UUID, body: GroupPullPageRequest):
    def read(budget):
        assert_active_principal(session, principal, lock=True)
        if body.client_id != str(principal.client_id):
            raise ApiError("client_mismatch", 403)
        record = _owned(session, principal, identifier)
        _binding(session, principal, record)
        if record.status != "ready":
            raise ApiError("group_not_ready", 409)
        page = session.get(GroupPullPage, digest(body.page_token))
        if (
            page is None
            or page.pull_id != record.id
            or page.kind not in {"index", "manifest", "data"}
        ):
            raise ApiError("not_found", 404)
        # Recheck root integrity before exposing a sealed response.
        try:
            manifest = GroupPullManifest.model_validate(record.manifest).model_dump(mode="json")
            if content_hash(manifest) != record.manifest_sha256:
                raise ValueError("group_root_integrity")
            return deepcopy(_page_chain(session, record, manifest, page))
        except (ValidationError, ValueError, KeyError, StopIteration):
            raise ApiError("group_projection_invalid", 503) from None

    return group_transaction(session, read)
