"""Finite, persistent metadata planning and sealed group page production.

Only private staging rows are written. Each invocation does a bounded number of
small work units and commits its progress through group_service's transaction.
History inputs are immutable and pinned by the session's captured base/target;
future SyncChange GC must honor the entire pin, not only representative FKs.
"""

from copy import deepcopy
from time import monotonic
from uuid import UUID, uuid4

from sqlalchemy import BigInteger, and_, case, cast, func, or_, select, tuple_, update
from sqlalchemy.exc import DBAPIError

from flowtrace_server.imports.staging_models import ImportPublication, ImportPublicationChunk

from .canonical import canonical_bytes, content_hash
from .group_budget import GroupDeadline
from .group_models import GroupPullPage, GroupPullUnit
from .group_reader import GroupReadError, GroupReadLimits, iter_group_data_pages, project_commit
from .group_schemas import (
    MAX_MANIFEST_PARTS,
    GroupCommitDescriptor,
    GroupPullManifest,
    GroupUnitDescriptor,
    GroupUnitIndexPage,
    GroupUnitManifestPage,
    page_hash_payload,
    unit_manifest_hash,
)
from .group_service import opaque_token, reserve_bytes, store_page
from .models import SyncChange
from .reader import _change_dict


def _set_plan(session, record, unit, value, limits):
    reserve_bytes(
        session, record, len(canonical_bytes(value)) - len(canonical_bytes(unit.plan_state)), limits
    )
    unit.plan_state = value


def _check_source(session, record, unit):
    if unit.kind == "commit":
        identifier = session.scalar(
            select(SyncChange.commit_id).where(
                SyncChange.scope_id == unit.source_scope_id,
                SyncChange.scope_revision == unit.source_scope_revision,
                SyncChange.event_index == unit.source_event_index,
            )
        )
        if identifier != unit.source_commit_id:
            raise GroupReadError("group_source_invalid")
    else:
        publication = session.get(ImportPublication, unit.publication_id)
        if publication is None or publication.sync_epoch != record.sync_epoch:
            raise GroupReadError("group_publication_invalid")
        if any(
            scope in record.checkpoint and int(revision) > int(record.checkpoint[scope])
            for scope, revision in publication.checkpoint.items()
        ):
            raise GroupReadError("group_publication_checkpoint_invalid")


def _discover(session, record, state, limits, cache):
    scopes = sorted(record.checkpoint)
    position = state["scope_index"]
    if position == len(scopes):
        state["phase"] = "plan"
        return
    scope = scopes[position]
    revision = int(
        state["scan_revision"]
        if state["scan_revision"] is not None
        else record.base_cursors.get(scope, "0")
    )
    index = state["scan_event_index"]
    rows = session.execute(
        select(
            SyncChange.scope_id,
            SyncChange.scope_revision,
            SyncChange.event_index,
            SyncChange.commit_id,
        )
        .where(
            SyncChange.scope_id == UUID(scope),
            SyncChange.scope_revision <= int(record.checkpoint[scope]),
            or_(
                SyncChange.scope_revision > revision,
                and_(SyncChange.scope_revision == revision, SyncChange.event_index > index),
            ),
        )
        .order_by(SyncChange.scope_revision, SyncChange.event_index)
        .limit(200)
    ).all()
    if not rows:
        state.update(scope_index=position + 1, scan_revision=None, scan_event_index=199)
        return
    for row in rows:
        if row.commit_id not in cache:
            chunk = session.scalar(
                select(ImportPublicationChunk).where(
                    ImportPublicationChunk.commit_id == row.commit_id
                )
            )
            source = ("publication", chunk.publication_id) if chunk else ("commit", row.commit_id)
            source_key = str(source)
            if source_key not in cache:
                predicate = (
                    GroupPullUnit.publication_id == source[1]
                    if chunk
                    else GroupPullUnit.source_commit_id == source[1]
                )
                unit = session.scalar(
                    select(GroupPullUnit).where(
                        GroupPullUnit.pull_id == record.id,
                        GroupPullUnit.kind == source[0],
                        predicate,
                    )
                )
                if unit is None:
                    if record.unit_count >= limits.units:
                        raise GroupReadError("group_unit_limit")
                    unit = GroupPullUnit(
                        pull_id=record.id,
                        unit_index=state["next_unit"],
                        topological_index=None,
                        group_id=uuid4(),
                        kind=source[0],
                        status="planning",
                        publication_id=chunk.publication_id if chunk else None,
                        source_commit_id=None if chunk else row.commit_id,
                        source_scope_id=None if chunk else row.scope_id,
                        source_scope_revision=None if chunk else row.scope_revision,
                        source_event_index=None if chunk else row.event_index,
                        plan_state={
                            "next_chunk": 0,
                            "private_event_count": 0,
                            "scope_min": {},
                            "scope_max": {},
                            "sort_key": row.commit_id.hex,
                            "data_commit": 0,
                            "data_offset": 0,
                            "data_page": 0,
                            "manifest_page": 0,
                            "manifest_cursor": 0,
                            "manifest_stage": "commits",
                        },
                        predecessor_ids=[],
                        remaining_predecessors=0,
                        commit_count=0,
                        event_count=0,
                        end_cursors={},
                        manifest_parts=[],
                        manifest_sha256=None,
                    )
                    _check_source(session, record, unit)
                    reserve_bytes(
                        session, record, len(canonical_bytes(unit.plan_state)) + 256, limits
                    )
                    session.add(unit)
                    state["next_unit"] += 1
                    record.unit_count += 1
                    session.flush()
                cache[source_key] = unit
            cache[row.commit_id] = cache[source_key]
        state["discovered_events"] += 1
        if state["discovered_events"] > limits.events:
            raise GroupReadError("group_event_limit")
    state.update(scan_revision=str(rows[-1].scope_revision), scan_event_index=rows[-1].event_index)


def _metadata_rows(session, identifier):
    rows = session.execute(
        select(SyncChange.scope_id, SyncChange.scope_revision, SyncChange.event_index)
        .where(SyncChange.commit_id == identifier)
        .order_by(SyncChange.scope_id, SyncChange.scope_revision, SyncChange.event_index)
        .limit(201)
    ).all()
    if not 1 <= len(rows) <= 200:
        raise GroupReadError("group_commit_invalid")
    return rows


def _plan(session, record, state, limits):
    unit = session.scalar(
        select(GroupPullUnit)
        .where(GroupPullUnit.pull_id == record.id, GroupPullUnit.status == "planning")
        .order_by(GroupPullUnit.unit_index)
        .limit(1)
    )
    if unit is None:
        state.update(
            phase="edges",
            edge_scope_index=0,
            edge_after=None,
            edge_prev_unit=None,
            edge_prev_max=None,
        )
        return
    _check_source(session, record, unit)
    plan = deepcopy(unit.plan_state)
    if unit.kind == "publication":
        publication = session.get(ImportPublication, unit.publication_id)
        count, first, last = session.execute(
            select(
                func.count(),
                func.min(ImportPublicationChunk.chunk_index),
                func.max(ImportPublicationChunk.chunk_index),
            ).where(ImportPublicationChunk.publication_id == unit.publication_id)
        ).one()
        if count != publication.chunk_count or first != 0 or last != count - 1:
            raise GroupReadError("group_publication_chunks_invalid")
        chunk = session.get(ImportPublicationChunk, (unit.publication_id, plan["next_chunk"]))
        if chunk is None:
            raise GroupReadError("group_publication_chunks_invalid")
        identifier = chunk.commit_id
        finished = plan["next_chunk"] + 1 == count
    else:
        chunk = None
        identifier = unit.source_commit_id
        finished = True
    rows = _metadata_rows(session, identifier)
    if chunk is not None and len(rows) != chunk.event_count:
        raise GroupReadError("group_publication_count_invalid")
    if chunk is not None:
        raw_rows = session.scalars(
            select(SyncChange)
            .where(SyncChange.commit_id == identifier)
            .order_by(SyncChange.scope_id, SyncChange.scope_revision, SyncChange.event_index)
            .limit(201)
        ).all()
        if content_hash([_change_dict(row) for row in raw_rows]) != chunk.sha256:
            raise GroupReadError("group_publication_hash_invalid")
        plan["private_event_count"] += len(raw_rows)
    revisions = {}
    visible = []
    for row in rows:
        scope = str(row.scope_id)
        if scope not in record.permission_versions:
            continue
        if (
            row.scope_revision > int(record.checkpoint[scope])
            or scope in revisions
            and revisions[scope] != row.scope_revision
        ):
            raise GroupReadError("group_commit_revision_invalid")
        revisions[scope] = row.scope_revision
        visible.append(row)
    if visible:
        descriptor = {
            "kind": "commit_plan",
            "pull_id": str(record.id),
            "group_id": str(unit.group_id),
            "commit_index": unit.commit_count,
            "commit_id": str(identifier),
            "event_count": len(visible),
            "scope_revisions": {scope: str(value) for scope, value in revisions.items()},
            "events_sha256": None,
        }
        store_page(
            session,
            record,
            kind="plan",
            unit_index=unit.unit_index,
            page_index=unit.commit_count,
            response=descriptor,
            limits=limits,
        )
        unit.commit_count += 1
        unit.event_count += len(visible)
        plan["sort_key"] = min(plan["sort_key"], identifier.hex)
        for scope, value in revisions.items():
            if scope in plan["scope_max"] and value <= int(plan["scope_max"][scope]):
                raise GroupReadError("group_publication_order_invalid")
            plan["scope_min"].setdefault(scope, str(value))
            plan["scope_max"][scope] = str(value)
    plan["next_chunk"] += 1
    if finished:
        if unit.kind == "publication" and plan["private_event_count"] != publication.event_count:
            raise GroupReadError("group_publication_count_invalid")
        if not unit.commit_count:
            raise GroupReadError("group_empty_selected_unit")
        unit.status = "planned"
        state["planned_events"] += unit.event_count
        if state["planned_events"] > limits.events:
            raise GroupReadError("group_event_limit")
    _set_plan(session, record, unit, plan, limits)


def _edges(session, record, state, limits):
    scopes = sorted(record.checkpoint)
    position = state["edge_scope_index"]
    if position == len(scopes):
        state["phase"] = "topology"
        return
    scope = scopes[position]
    minimum = cast(GroupPullUnit.plan_state["scope_min"][scope].astext, BigInteger)
    query = select(GroupPullUnit).where(
        GroupPullUnit.pull_id == record.id, GroupPullUnit.plan_state["scope_min"].has_key(scope)
    )
    if state["edge_after"] is not None:
        query = query.where(minimum > int(state["edge_after"]))
    rows = session.scalars(query.order_by(minimum, GroupPullUnit.unit_index).limit(32)).all()
    if not rows:
        state.update(
            edge_scope_index=position + 1, edge_after=None, edge_prev_unit=None, edge_prev_max=None
        )
        return
    previous = (
        session.get(GroupPullUnit, (record.id, state["edge_prev_unit"]))
        if state["edge_prev_unit"] is not None
        else None
    )
    for unit in rows:
        lower = int(unit.plan_state["scope_min"][scope])
        if state["edge_prev_max"] is not None and lower <= int(state["edge_prev_max"]):
            raise GroupReadError("group_topology_invalid")
        if previous is not None and str(previous.group_id) not in unit.predecessor_ids:
            old = len(canonical_bytes(unit.predecessor_ids))
            unit.predecessor_ids = [*unit.predecessor_ids, str(previous.group_id)]
            unit.remaining_predecessors += 1
            reserve_bytes(session, record, len(canonical_bytes(unit.predecessor_ids)) - old, limits)
        previous = unit
        state.update(
            edge_after=str(lower),
            edge_prev_unit=unit.unit_index,
            edge_prev_max=unit.plan_state["scope_max"][scope],
        )


def _topology(session, record, state, limits):
    unit = session.scalar(
        select(GroupPullUnit)
        .where(
            GroupPullUnit.pull_id == record.id,
            GroupPullUnit.topological_index.is_(None),
            GroupPullUnit.remaining_predecessors == 0,
        )
        .order_by(GroupPullUnit.plan_state["sort_key"].astext, GroupPullUnit.unit_index)
        .limit(1)
        .execution_options(populate_existing=True)
    )
    if unit is None:
        if state["topological_next"] != record.unit_count:
            raise GroupReadError("group_topology_invalid")
        state["phase"] = "data"
        record.status = "materializing"
        return
    _check_source(session, record, unit)
    unit.topological_index = state["topological_next"]
    state["topological_next"] += 1
    prefix = dict(state["prefix"])
    for scope, value in unit.plan_state["scope_max"].items():
        prefix[scope] = str(max(int(prefix.get(scope, "0")), int(value)))
    state["prefix"] = prefix
    reserve_bytes(session, record, len(canonical_bytes(prefix)), limits)
    unit.end_cursors = prefix
    session.execute(
        update(GroupPullUnit)
        .where(
            GroupPullUnit.pull_id == record.id,
            GroupPullUnit.topological_index.is_(None),
            GroupPullUnit.predecessor_ids.contains([str(unit.group_id)]),
        )
        .values(remaining_predecessors=GroupPullUnit.remaining_predecessors - 1)
        .execution_options(synchronize_session=False)
    )


def _replace_plan_frame(session, record, frame, value, limits):
    raw = canonical_bytes(value)
    reserve_bytes(session, record, len(raw) - frame.size_bytes, limits)
    frame.response = deepcopy(value)
    frame.sha256 = content_hash(value)
    frame.size_bytes = len(raw)


def _unit_descriptor(record, unit):
    value = {
        "unit_index": unit.topological_index,
        "group_id": str(unit.group_id),
        "kind": unit.kind,
        "commit_count": unit.commit_count,
        "event_count": unit.event_count,
        "end_cursors": unit.end_cursors,
        "manifest_parts": unit.manifest_parts,
        "manifest_sha256": unit.manifest_sha256 or "0" * 64,
    }
    value["manifest_sha256"] = unit_manifest_hash(str(record.id), value)
    return GroupUnitDescriptor.model_validate(value).model_dump(mode="json")


def _manifest_part(session, record, unit, plan, limits):
    kind = "plan" if plan["manifest_stage"] == "commits" else "data"
    rows = session.scalars(
        select(GroupPullPage)
        .where(
            GroupPullPage.pull_id == record.id,
            GroupPullPage.unit_index == unit.unit_index,
            GroupPullPage.kind == kind,
            GroupPullPage.page_index >= plan["manifest_cursor"],
        )
        .order_by(GroupPullPage.page_index)
        .limit(200)
    ).all()
    if not rows:
        if kind == "plan":
            plan.update(manifest_stage="data", manifest_cursor=0)
            return
        unit.manifest_sha256 = _unit_descriptor(record, unit)["manifest_sha256"]
        unit.status = "ready"
        return
    if rows[0].page_index != plan["manifest_cursor"] or [row.page_index for row in rows] != list(
        range(rows[0].page_index, rows[0].page_index + len(rows))
    ):
        raise GroupReadError("group_manifest_incomplete")
    commits, data = [], []
    for row in rows:
        if kind == "plan":
            raw = row.response
            commits.append(
                GroupCommitDescriptor.model_validate(
                    {
                        key: raw[key]
                        for key in ("commit_index", "commit_id", "event_count", "events_sha256")
                    }
                ).model_dump(mode="json")
            )
        else:
            data.append(
                {
                    "page_index": row.page_index,
                    "item_count": sum(
                        len(fragment["events"]) for fragment in row.response["fragments"]
                    ),
                    "sha256": row.sha256,
                }
            )
    body = {
        "pull_id": str(record.id),
        "group_id": str(unit.group_id),
        "kind": "manifest",
        "page_index": plan["manifest_page"],
        "commits": commits,
        "data_pages": data,
        "next_page_token": None,
    }
    body["page_sha256"] = content_hash(page_hash_payload(body))
    body = GroupUnitManifestPage.model_validate(body).model_dump(mode="json")
    store_page(
        session,
        record,
        kind="manifest",
        unit_index=unit.unit_index,
        page_index=plan["manifest_page"],
        response=body,
        limits=limits,
    )
    if len(unit.manifest_parts) >= MAX_MANIFEST_PARTS:
        raise GroupReadError("group_manifest_limit")
    parts = [
        *unit.manifest_parts,
        {
            "page_index": plan["manifest_page"],
            "item_count": len(rows),
            "sha256": body["page_sha256"],
        },
    ]
    reserve_bytes(
        session,
        record,
        len(canonical_bytes(parts)) - len(canonical_bytes(unit.manifest_parts)),
        limits,
    )
    unit.manifest_parts = parts
    plan["manifest_page"] += 1
    plan["manifest_cursor"] = rows[-1].page_index + 1


def _data(session, record, state, limits):
    unit = session.scalar(
        select(GroupPullUnit)
        .where(GroupPullUnit.pull_id == record.id, GroupPullUnit.status != "ready")
        .order_by(GroupPullUnit.topological_index)
        .limit(1)
    )
    if unit is None:
        state.update(phase="index", index_after=-1, index_page=0, index_descriptors=[])
        return
    _check_source(session, record, unit)
    unit.status = "materializing"
    plan = deepcopy(unit.plan_state)
    if plan["data_commit"] == unit.commit_count:
        _manifest_part(session, record, unit, plan, limits)
        _set_plan(session, record, unit, plan, limits)
        return
    frame = session.scalar(
        select(GroupPullPage).where(
            GroupPullPage.pull_id == record.id,
            GroupPullPage.unit_index == unit.unit_index,
            GroupPullPage.kind == "plan",
            GroupPullPage.page_index == plan["data_commit"],
        )
    )
    if frame is None:
        raise GroupReadError("group_plan_incomplete")
    identifier = UUID(frame.response["commit_id"])
    rows = session.scalars(
        select(SyncChange)
        .where(SyncChange.commit_id == identifier)
        .order_by(SyncChange.scope_id, SyncChange.scope_revision, SyncChange.event_index)
        .limit(201)
    ).all()
    projected = project_commit(
        identifier,
        [_change_dict(row) for row in rows],
        {UUID(key) for key in record.permission_versions},
    )
    if (
        projected is None
        or len(projected.events) != frame.response["event_count"]
        or {str(scope): str(value) for scope, value in projected.position.scope_revisions}
        != frame.response["scope_revisions"]
    ):
        raise GroupReadError("group_projection_invalid")
    descriptor = projected.descriptor(plan["data_commit"]).model_dump(mode="json")
    if frame.response["events_sha256"] is None:
        _replace_plan_frame(
            session,
            record,
            frame,
            {**frame.response, "events_sha256": descriptor["events_sha256"]},
            limits,
        )
    elif frame.response["events_sha256"] != descriptor["events_sha256"]:
        raise GroupReadError("group_projection_invalid")
    iterator = iter_group_data_pages(
        record.id,
        unit.group_id,
        [projected],
        limits=limits,
        commit_index_start=plan["data_commit"],
        page_index_start=plan["data_page"],
        first_event_offset=plan["data_offset"],
        next_token_factory=lambda index: opaque_token(record, "data", unit.unit_index, index),
    )
    try:
        page = next(iterator)
    finally:
        iterator.close()
    body = page.model_dump(mode="json")
    store_page(
        session,
        record,
        kind="data",
        unit_index=unit.unit_index,
        page_index=plan["data_page"],
        response=body,
        limits=limits,
    )
    last = page.fragments[-1]
    offset = last.event_offset + len(last.events)
    if offset == descriptor["event_count"]:
        plan.update(data_commit=plan["data_commit"] + 1, data_offset=0)
    else:
        plan["data_offset"] = offset
    plan["data_page"] += 1
    _set_plan(session, record, unit, plan, limits)


def _index(session, record, state, limits):
    rows = session.scalars(
        select(GroupPullUnit)
        .where(
            GroupPullUnit.pull_id == record.id,
            GroupPullUnit.topological_index > state["index_after"],
        )
        .order_by(GroupPullUnit.topological_index)
        .limit(200)
    ).all()
    if not rows:
        state.update(phase="seal", seal_after=None)
        return
    body = {
        "pull_id": str(record.id),
        "kind": "index",
        "page_index": state["index_page"],
        "units": [],
        "next_page_token": "x" * 128,
        "page_sha256": "0" * 64,
    }
    size = len(canonical_bytes(body))
    for unit in rows:
        value = _unit_descriptor(record, unit)
        delta = len(canonical_bytes(value)) + bool(body["units"])
        if size + delta > limits.page_bytes:
            break
        body["units"].append(value)
        size += delta
        state["index_after"] = unit.topological_index
    if not body["units"]:
        raise GroupReadError("group_manifest_limit")
    body["next_page_token"] = None
    body["page_sha256"] = content_hash(page_hash_payload(body))
    body = GroupUnitIndexPage.model_validate(body).model_dump(mode="json")
    store_page(
        session,
        record,
        kind="index",
        unit_index=None,
        page_index=state["index_page"],
        response=body,
        limits=limits,
    )
    state["index_descriptors"].append(
        {
            "page_index": state["index_page"],
            "item_count": len(body["units"]),
            "sha256": body["page_sha256"],
        }
    )
    state["index_page"] += 1


def _seal(session, record, state, limits):
    first = case((GroupPullPage.kind == "index", 0), else_=1)
    unit_order = func.coalesce(GroupPullUnit.topological_index, -1)
    kind_order = case((GroupPullPage.kind == "manifest", 0), else_=1)
    key = (first, unit_order, kind_order, GroupPullPage.page_index)
    query = (
        select(GroupPullPage, *key)
        .outerjoin(
            GroupPullUnit,
            and_(
                GroupPullUnit.pull_id == GroupPullPage.pull_id,
                GroupPullUnit.unit_index == GroupPullPage.unit_index,
            ),
        )
        .where(
            GroupPullPage.pull_id == record.id,
            GroupPullPage.kind.in_(["index", "manifest", "data"]),
        )
    )
    if state["seal_after"] is not None:
        query = query.where(tuple_(*key) > tuple_(*state["seal_after"]))
    rows = session.execute(query.order_by(*key).limit(2)).all()
    if not rows:
        if state["prefix"] != record.checkpoint:
            raise GroupReadError("group_checkpoint_incomplete")
        manifest = GroupPullManifest.model_validate(
            {
                "protocol": "group-sync-v1",
                "pull_id": str(record.id),
                "request_id": str(record.request_id),
                "instance_id": state["instance_id"],
                "user_id": str(record.user_id),
                "client_id": str(record.client_id),
                "sync_epoch": str(record.sync_epoch),
                "control_version": str(record.control_version),
                "permission_versions": record.permission_versions,
                "base_cursors": record.base_cursors,
                "checkpoint": record.checkpoint,
                "unit_count": record.unit_count,
                "index_pages": state["index_descriptors"],
            }
        ).model_dump(mode="json")
        reserve_bytes(session, record, len(canonical_bytes(manifest)), limits)
        record.manifest = manifest
        record.manifest_sha256 = content_hash(manifest)
        record.first_page_token = (
            opaque_token(record, "index", None, 0) if record.unit_count else None
        )
        record.next_step_token_hash = None
        record.status = "ready"
        state["phase"] = "ready"
        return
    page = rows[0][0]
    token = (
        opaque_token(record, rows[1][0].kind, rows[1][0].unit_index, rows[1][0].page_index)
        if len(rows) == 2
        else None
    )
    value = {**page.response, "next_page_token": token}
    raw = canonical_bytes(value)
    if len(raw) > limits.page_bytes:
        raise GroupReadError("group_page_limit")
    reserve_bytes(session, record, len(raw) - page.size_bytes, limits)
    page.response, page.size_bytes = value, len(raw)
    state["seal_after"] = list(rows[0][1:])


def materialize_step(
    session, record, state, *, limits=GroupReadLimits(), work_limit=32, budget=None
):
    if type(work_limit) is not int or not 1 <= work_limit <= 1024:
        raise ValueError("group_work_limit_invalid")
    deadline = (
        min(monotonic() + limits.step_seconds * 0.8, budget.deadline - limits.step_seconds * 0.2)
        if budget
        else monotonic() + limits.step_seconds * 0.8
    )
    cache = {}
    phases = {
        "discover": lambda: _discover(session, record, state, limits, cache),
        "plan": lambda: _plan(session, record, state, limits),
        "edges": lambda: _edges(session, record, state, limits),
        "topology": lambda: _topology(session, record, state, limits),
        "data": lambda: _data(session, record, state, limits),
        "index": lambda: _index(session, record, state, limits),
        "seal": lambda: _seal(session, record, state, limits),
    }
    for _ in range(work_limit):
        if monotonic() >= deadline or record.status == "ready":
            break
        previous = deepcopy(state)
        if budget:
            budget.current_deadline = deadline
        try:
            with session.begin_nested():
                phases[state["phase"]]()
                session.flush()
        except (GroupDeadline, DBAPIError) as error:
            if isinstance(error, DBAPIError) and getattr(error.orig, "sqlstate", None) != "57014":
                raise
            state.clear()
            state.update(previous)
            # The savepoint discarded this unfinished work unit only. Earlier
            # units remain durable when the outer step commits its receipt.
            break
        finally:
            if budget:
                budget.current_deadline = budget.deadline
