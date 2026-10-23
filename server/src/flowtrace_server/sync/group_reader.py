"""Pure group projection, metadata topology and byte-bounded transport packing.

No PG service/route or migration is activated here. The later finite-step reader
must select a closed history prefix and expand every selected publication before
calling these primitives. Metadata topology carries no financial payload arrays;
projection processes one <=200-event commit, and packing yields bounded pages.
"""

import heapq
import json
import secrets
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Callable, Iterable, Mapping, Sequence
from uuid import UUID, uuid4

from .canonical import canonical_bytes, content_hash
from .group_schemas import (
    MAX_COMMITS_PER_UNIT,
    MAX_EVENTS,
    MAX_PAGE_BYTES,
    MAX_PAGES,
    MAX_RETAINED_SESSIONS,
    MAX_SCOPES,
    MAX_SESSION_BYTES,
    MAX_STEP_SECONDS,
    MAX_UNITS,
    GroupCommitDescriptor,
    GroupDataPage,
    page_hash_payload,
    validate_group_event,
)


class GroupReadError(ValueError):
    """Only fixed safe codes; never includes a projection or internal UUID."""


@dataclass(frozen=True)
class GroupReadLimits:
    page_bytes: int = MAX_PAGE_BYTES
    session_bytes: int = MAX_SESSION_BYTES
    pages: int = MAX_PAGES
    units: int = MAX_UNITS
    events: int = MAX_EVENTS
    scopes: int = MAX_SCOPES
    retained_sessions: int = MAX_RETAINED_SESSIONS
    step_seconds: int = MAX_STEP_SECONDS

    def __post_init__(self):
        bounds = (
            (self.page_bytes, 1024, MAX_PAGE_BYTES),
            (self.session_bytes, self.page_bytes, MAX_SESSION_BYTES),
            (self.pages, 1, MAX_PAGES),
            (self.units, 1, MAX_UNITS),
            (self.events, 1, MAX_EVENTS),
            (self.scopes, 1, MAX_SCOPES),
            (self.retained_sessions, 1, MAX_RETAINED_SESSIONS),
            (self.step_seconds, 1, MAX_STEP_SECONDS),
        )
        if any(type(value) is not int or not low <= value <= high for value, low, high in bounds):
            raise ValueError("group_limits_invalid")


@dataclass(frozen=True)
class CommitPosition:
    commit_id: UUID
    scope_revisions: tuple[tuple[UUID, int], ...]


@dataclass(frozen=True)
class ProjectedCommit:
    commit_id: UUID
    events_json: str = field(repr=False)
    position: CommitPosition

    @property
    def events(self):
        # Returning a new object prevents callers mutating an already hashed input.
        return json.loads(self.events_json)

    def descriptor(self, index):
        values = self.events
        return GroupCommitDescriptor(
            commit_index=index,
            commit_id=str(self.commit_id),
            event_count=len(values),
            events_sha256=content_hash(values),
        )


def project_commit(commit_id: UUID, events: Sequence[dict], authorized_scopes: set[UUID]):
    if not isinstance(commit_id, UUID) or not 1 <= len(events) <= 200:
        raise GroupReadError("group_commit_invalid")
    visible, revisions, identities = [], {}, set()
    for event in events:
        validate_group_event(event)
        scope = UUID(event["scope_id"])
        revision = int(event["scope_revision"])
        if revision > 2**63 - 1:
            raise GroupReadError("group_revision_invalid")
        identity = (scope, revision, event["event_index"])
        if identity in identities:
            raise GroupReadError("group_event_duplicate")
        identities.add(identity)
        if scope not in authorized_scopes:
            continue
        if scope in revisions and revisions[scope] != revision:
            raise GroupReadError("group_commit_scope_revision_invalid")
        revisions[scope] = revision
        visible.append(event)
    if not visible:
        return None
    visible.sort(
        key=lambda item: (item["scope_id"], int(item["scope_revision"]), item["event_index"])
    )
    raw = canonical_bytes(visible).decode("utf-8")
    return ProjectedCommit(
        commit_id, raw, CommitPosition(commit_id, tuple(sorted(revisions.items())))
    )


@dataclass(frozen=True)
class AtomicUnitOrder:
    group_id: UUID
    kind: str
    commit_ids: tuple[UUID, ...]
    end_cursors: tuple[tuple[UUID, int], ...]
    publication_id: UUID | None = field(repr=False)


def order_atomic_units(
    positions: Iterable[CommitPosition],
    publications: Mapping[UUID, Sequence[UUID]],
    base_cursors: Mapping[UUID, int],
    *,
    limits=GroupReadLimits(),
    opaque_id_factory: Callable[[], UUID] = uuid4,
):
    """Order a closed selected prefix; publication metadata itself stays private.

    The PG selector, not this pure function, proves that all currently visible
    rows in a selected publication/prefix were fetched. Invisible metadata IDs
    establish original order but never appear in the returned visible commits.
    """
    membership = {}
    for publication, commits in publications.items():
        if not isinstance(publication, UUID) or not 1 <= len(commits) <= MAX_COMMITS_PER_UNIT:
            raise GroupReadError("group_publication_metadata_invalid")
        for index, commit in enumerate(commits):
            if not isinstance(commit, UUID) or commit in membership:
                raise GroupReadError("group_publication_membership_invalid")
            membership[commit] = (publication, index)
            if len(membership) > limits.events:
                raise GroupReadError("group_plan_limit")
    by_unit, by_scope, seen = defaultdict(list), defaultdict(list), set()
    for position in positions:
        commit = position.commit_id
        if commit in seen or not position.scope_revisions:
            raise GroupReadError("group_commit_position_invalid")
        seen.add(commit)
        if len(seen) > limits.events:
            raise GroupReadError("group_plan_limit")
        publication, index = membership.get(commit, (None, 0))
        unit = ("publication", publication) if publication is not None else ("commit", commit)
        by_unit[unit].append((index, commit))
        if len(by_unit) > limits.units:
            raise GroupReadError("group_unit_limit")
        for scope, revision in position.scope_revisions:
            if type(revision) is not int or not 0 <= revision <= 2**63 - 1:
                raise GroupReadError("group_revision_invalid")
            by_scope[scope].append((revision, commit, unit))
        if len(by_scope) > limits.scopes:
            raise GroupReadError("group_scope_limit")
    edges = {unit: set() for unit in by_unit}
    indegree = {unit: 0 for unit in by_unit}
    for rows in by_scope.values():
        previous = None
        last_revision = None
        unit_positions = {}
        for revision, commit, unit in sorted(rows):
            if last_revision == revision:
                raise GroupReadError("group_scope_revision_duplicate")
            if unit[0] == "publication":
                chunk_index = membership[commit][1]
                if chunk_index <= unit_positions.get(unit, -1):
                    raise GroupReadError("group_publication_order_invalid")
                unit_positions[unit] = chunk_index
            if previous is not None and previous != unit and unit not in edges[previous]:
                edges[previous].add(unit)
                indegree[unit] += 1
            previous, last_revision = unit, revision
    priorities = {unit: min(commit.hex for _, commit in values) for unit, values in by_unit.items()}
    ready = [(priorities[unit], unit) for unit, degree in indegree.items() if degree == 0]
    heapq.heapify(ready)
    ordered = []
    while ready:
        _, unit = heapq.heappop(ready)
        ordered.append(unit)
        for successor in edges[unit]:
            indegree[successor] -= 1
            if indegree[successor] == 0:
                heapq.heappush(ready, (priorities[successor], successor))
    if len(ordered) != len(by_unit):
        raise GroupReadError("group_topology_invalid")
    if len(base_cursors) > limits.scopes or any(
        type(value) is not int or not 0 <= value <= 2**63 - 1 for value in base_cursors.values()
    ):
        raise GroupReadError("group_base_cursors_invalid")
    if len(set(base_cursors) | set(by_scope)) > limits.scopes:
        raise GroupReadError("group_scope_limit")
    cursor, output, opaque_ids = dict(base_cursors), [], set()
    unit_revisions = defaultdict(dict)
    for scope, rows in by_scope.items():
        for revision, _, unit in rows:
            unit_revisions[unit][scope] = max(unit_revisions[unit].get(scope, 0), revision)
    for unit in ordered:
        identifier = opaque_id_factory()
        if (
            not isinstance(identifier, UUID)
            or identifier in opaque_ids
            or identifier in membership
            or identifier in publications
        ):
            raise GroupReadError("group_opaque_id_invalid")
        opaque_ids.add(identifier)
        for scope, revision in unit_revisions[unit].items():
            cursor[scope] = max(cursor.get(scope, 0), revision)
        output.append(
            AtomicUnitOrder(
                identifier,
                unit[0],
                tuple(commit for _, commit in sorted(by_unit[unit])),
                tuple(sorted(cursor.items())),
                unit[1] if unit[0] == "publication" else None,
            )
        )
    return tuple(output)


def iter_group_data_pages(
    pull_id: UUID,
    group_id: UUID,
    commits: Iterable[ProjectedCommit],
    *,
    limits=GroupReadLimits(),
    next_token_factory: Callable[[int], str] = lambda index: secrets.token_urlsafe(32),
    check_budget: Callable[[], None] = lambda: None,
    commit_index_start: int = 0,
    page_index_start: int = 0,
    first_event_offset: int = 0,
):
    """Stream exact raw events; never split a field or exceed full-envelope bytes.

    Reserve the maximum token length while packing. Event JSON is encoded once
    for size accounting; whole pages are validated/hashed only at emission.
    """
    if (
        type(commit_index_start) is not int
        or not 0 <= commit_index_start < MAX_COMMITS_PER_UNIT
        or type(page_index_start) is not int
        or not 0 <= page_index_start < limits.pages
        or type(first_event_offset) is not int
        or not 0 <= first_event_offset <= 199
    ):
        raise GroupReadError("group_resume_position_invalid")
    page_index, fragments, event_count, total_bytes, total_events = page_index_start, [], 0, 0, 0

    def body(items, token, checksum):
        return {
            "pull_id": str(pull_id),
            "group_id": str(group_id),
            "kind": "data",
            "page_index": page_index,
            "fragments": items,
            "page_sha256": checksum,
            "next_page_token": token,
        }

    def emit(token):
        nonlocal total_bytes
        value = body(fragments, token, "0" * 64)
        value["page_sha256"] = content_hash(page_hash_payload(value))
        page = GroupDataPage.model_validate(value)
        size = len(canonical_bytes(page.model_dump(mode="json")))
        total_bytes += size
        if (
            size > limits.page_bytes
            or total_bytes > limits.session_bytes
            or page_index >= limits.pages
        ):
            raise GroupReadError("group_storage_limit")
        return page

    size = len(canonical_bytes(body([], "x" * 128, "0" * 64)))
    for position, commit in enumerate(commits):
        commit_index = commit_index_start + position
        if commit_index >= MAX_COMMITS_PER_UNIT:
            raise GroupReadError("group_commit_limit")
        values = commit.events
        if not 1 <= len(values) <= 200:
            raise GroupReadError("group_commit_invalid")
        for offset, event in enumerate(values):
            if position == 0 and offset < first_event_offset:
                continue
            check_budget()
            event_bytes = len(canonical_bytes(event))
            continuation = bool(fragments and fragments[-1]["commit_index"] == commit_index)
            delta = event_bytes + (
                1
                if continuation
                else len(
                    canonical_bytes(
                        {"commit_index": commit_index, "event_offset": offset, "events": []}
                    )
                )
                + bool(fragments)
            )
            if event_count == 200 or size + delta > limits.page_bytes:
                if not fragments:
                    raise GroupReadError("group_event_too_large")
                yield emit(next_token_factory(page_index + 1))
                page_index += 1
                fragments, event_count = [], 0
                size = len(canonical_bytes(body([], "x" * 128, "0" * 64)))
                continuation = False
                delta = event_bytes + len(
                    canonical_bytes(
                        {"commit_index": commit_index, "event_offset": offset, "events": []}
                    )
                )
                if size + delta > limits.page_bytes:
                    raise GroupReadError("group_event_too_large")
            if not continuation:
                fragments.append(
                    {"commit_index": commit_index, "event_offset": offset, "events": []}
                )
            fragments[-1]["events"].append(event)
            size += delta
            event_count += 1
            total_events += 1
            if total_events > limits.events:
                raise GroupReadError("group_event_limit")
    if fragments:
        yield emit(None)
