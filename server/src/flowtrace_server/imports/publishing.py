"""Internal server-atomic publication, without changing sync-v1 commit limits.

Each sync commit remains independently visible to existing clients. A future
publication-group protocol must accumulate these before exposing a full batch.
The caller owns one PostgreSQL transaction covering every returned commit.
"""

from dataclasses import dataclass
from uuid import UUID, uuid5

from flowtrace_server.sync.common import MAX_COMMIT_EVENTS, write_changes


@dataclass(frozen=True)
class PublishedChanges:
    commit_ids: tuple[str, ...]
    scope_revisions: dict[str, str]


def publish_changes(
    session, scopes, events, publication_id: UUID, *, before_chunk=None, check_budget=None
):
    budget = check_budget if check_budget is not None else lambda: None
    budget()
    keys = [(event.scope_id, event.entity_type, event.entity_id) for event in events]
    if len(keys) != len(set(keys)):
        raise ValueError("publication_duplicate_projection")
    ordered = sorted(
        events, key=lambda event: (event.scope_id.hex, event.entity_type, event.entity_id.hex)
    )
    budget()
    commits, vector = [], {}
    for position in range(0, len(ordered), MAX_COMMIT_EVENTS):
        budget()
        chunk = ordered[position : position + MAX_COMMIT_EVENTS]
        index = position // MAX_COMMIT_EVENTS
        if before_chunk:
            before_chunk(index)
        commit, revisions = write_changes(
            session, scopes, chunk, commit_id=uuid5(publication_id, f"sync-commit:{index}")
        )
        commits.append(commit)
        vector.update(revisions)
        budget()
    return PublishedChanges(tuple(commits), vector)
