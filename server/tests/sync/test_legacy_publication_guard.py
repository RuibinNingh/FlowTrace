from copy import deepcopy
from uuid import UUID, uuid5

import pytest
from data_tools.test_staging_parsers import source_file
from data_tools.test_staging_preview import categories
from data_tools.test_staging_publish import apply, ready
from sqlalchemy.orm import Session

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.sync.reader import create_snapshot, pull
from flowtrace_server.sync.schemas import PullRequest, SnapshotRequest

from .helpers import actor, epoch, operation, push, share

pytestmark = pytest.mark.postgres


def request(owner, engine, **values):
    return PullRequest(
        sync_epoch=epoch(engine),
        cursors={},
        limit=1,
        page_token=values.get("page_token"),
    )


def test_legacy_multichunk_read_requires_atomic_snapshot_and_preserves_old_pages(postgres_engine):
    owner = actor(postgres_engine)
    for index in range(3):
        assert (
            push(
                postgres_engine,
                owner,
                operation(owner.book_id, "tag", {"name": f"旧页-{index}", "color": "#123456"}),
            )[0]["status"]
            == "applied"
        )
    with Session(postgres_engine) as session:
        before = pull(session, owner.principal, request(owner, postgres_engine))
        token = before["next_page_token"]
        assert token is not None
        old_request = request(owner, postgres_engine, page_token=token)
        old_page = deepcopy(pull(session, owner.principal, old_request))
    _, _, _, lease = ready(
        postgres_engine, owner, source_file("flowtrace_json", categories(owner, 201))
    )
    apply(postgres_engine, lease)
    with Session(postgres_engine) as session:
        with pytest.raises(ApiError) as error:
            pull(session, owner.principal, request(owner, postgres_engine))
        assert (error.value.code, error.value.status) == ("resync_required", 410)
        assert pull(session, owner.principal, old_request) == old_page
        snapshot = create_snapshot(
            session,
            owner.principal,
            SnapshotRequest(
                protocol_version=1,
                client_id=str(owner.principal.client_id),
                sync_epoch=epoch(postgres_engine),
                scope_ids=[str(owner.book_id)],
            ),
        )
        assert snapshot["status"] == "ready"
        assert sum(page["item_count"] for page in snapshot["manifest"]["pages"]) >= 201
    viewer = actor(postgres_engine)
    share(postgres_engine, owner, viewer, "viewer")
    with Session(postgres_engine) as session:
        with pytest.raises(ApiError) as error:
            pull(session, viewer.principal, request(viewer, postgres_engine))
        assert error.value.code == "resync_required"


def test_single_visible_commit_remains_compatible_with_legacy_wire(postgres_engine):
    owner = actor(postgres_engine)
    stage, _, _, lease = ready(
        postgres_engine, owner, source_file("flowtrace_json", categories(owner, 5))
    )
    apply(postgres_engine, lease)
    body = request(owner, postgres_engine)
    seen = []
    with Session(postgres_engine) as session:
        while True:
            response = pull(session, owner.principal, body)
            seen.extend(response["commits"])
            token = response["next_page_token"]
            if token is None:
                break
            body = request(owner, postgres_engine, page_token=token)
    assert any(
        commit["commit_id"] == str(uuid5(UUID(stage.stage_id), "sync-commit:0")) for commit in seen
    )
