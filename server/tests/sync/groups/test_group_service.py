"""Real PostgreSQL finite steps, durable replay, authority and private projection."""

from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from datetime import timedelta
from time import monotonic
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, insert, select, text
from sqlalchemy.orm import Session
from sync.helpers import account, actor, epoch, expense, operation, push, revoke, share

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import now
from flowtrace_server.books.models import SyncScope
from flowtrace_server.sync.canonical import canonical_bytes, content_hash
from flowtrace_server.sync.group_models import GroupPullPage, GroupPullSession
from flowtrace_server.sync.group_reader import GroupReadLimits
from flowtrace_server.sync.group_schemas import (
    GroupPullCreate,
    GroupPullPageRequest,
    GroupPullStep,
    page_hash_payload,
)
from flowtrace_server.sync.group_service import (
    create_group_pull,
    discard_group_pull,
    group_pull_status,
    read_group_pull_page,
    step_group_pull,
)
from flowtrace_server.sync.models import SyncChange

pytestmark = pytest.mark.postgres


def create(engine, owner, *, cursors=None, request_id=None, limits=None):
    body = GroupPullCreate(
        protocol_version=1,
        request_id=str(request_id or uuid4()),
        client_id=str(owner.principal.client_id),
        sync_epoch=epoch(engine),
        cursors=cursors or {},
    )
    with Session(engine) as session:
        result = create_group_pull(
            session, owner.principal, body, **({"limits": limits} if limits else {})
        )
    return body, result


def step(engine, owner, status, *, work_limit=32, token=None):
    with Session(engine) as session:
        return step_group_pull(
            session,
            owner.principal,
            UUID(status["pull_id"]),
            GroupPullStep(
                client_id=str(owner.principal.client_id),
                step_token=token or status["next_step_token"],
            ),
            work_limit=work_limit,
        )


def ready(engine, owner, status, *, work_limit=32):
    for _ in range(1000):
        if status["status"] == "ready":
            return status
        assert status["manifest"] is None and status["first_page_token"] is None
        status = step(engine, owner, status, work_limit=work_limit)
    raise AssertionError("finite group plan did not finish")


def pages(engine, owner, status):
    token, result, seen = status["first_page_token"], [], set()
    while token is not None:
        assert token not in seen
        seen.add(token)
        with Session(engine) as session:
            body = read_group_pull_page(
                session,
                owner.principal,
                UUID(status["pull_id"]),
                GroupPullPageRequest(client_id=str(owner.principal.client_id), page_token=token),
            )
        assert body["page_sha256"] == content_hash(page_hash_payload(body))
        assert len(canonical_bytes(body)) <= 512 * 1024
        result.append(body)
        token = body["next_page_token"]
    return result


def test_finite_reopen_chain_safe_prefix_and_exact_old_step_replay(postgres_engine):
    owner = actor(postgres_engine)
    cash = account(postgres_engine, owner)
    assert (
        push(
            postgres_engine, owner, operation(owner.book_id, "bill", expense(owner.book_id, cash))
        )[0]["status"]
        == "applied"
    )
    body, pending = create(postgres_engine, owner)
    old_token = pending["next_step_token"]
    advanced = step(postgres_engine, owner, pending, work_limit=1)
    with Session(postgres_engine) as session:
        row = session.get(GroupPullSession, UUID(pending["pull_id"]))
        before = (row.page_count, row.reserved_bytes, deepcopy(row.build_state))
    assert step(postgres_engine, owner, advanced, token=old_token) == advanced
    with Session(postgres_engine) as session:
        row = session.get(GroupPullSession, UUID(pending["pull_id"]))
        assert (row.page_count, row.reserved_bytes, row.build_state) == before
    result = ready(postgres_engine, owner, advanced, work_limit=1)
    wire = pages(postgres_engine, owner, result)
    assert wire[0]["kind"] == "index"
    units = [unit for page in wire if page["kind"] == "index" for unit in page["units"]]
    assert units[-1]["end_cursors"] == result["manifest"]["checkpoint"]
    assert str(owner.principal.user_id) in units[-1]["end_cursors"]
    assert [unit["unit_index"] for unit in units] == list(range(len(units)))
    for unit in units:
        pieces = [page for page in wire if page.get("group_id") == unit["group_id"]]
        assert pieces[0]["kind"] == "manifest" and pieces[-1]["kind"] == "data"
    with Session(postgres_engine) as session:
        replay = create_group_pull(session, owner.principal, body)
    assert replay == result


def test_same_intent_precedes_retained_quota_expiry_does_not_release(postgres_engine):
    owner = actor(postgres_engine)
    body, first = create(postgres_engine, owner)
    create(postgres_engine, owner)
    with Session(postgres_engine) as session:
        assert create_group_pull(session, owner.principal, body) == first
    with pytest.raises(ApiError, match="group_session_quota"):
        create(postgres_engine, owner)
    with Session(postgres_engine) as session:
        session.get(GroupPullSession, UUID(first["pull_id"])).expires_at = now() - timedelta(
            seconds=1
        )
        session.commit()
    with pytest.raises(ApiError, match="group_session_quota"):
        create(postgres_engine, owner)
    with Session(postgres_engine) as session:
        status = group_pull_status(
            session,
            owner.principal,
            UUID(first["pull_id"]),
            client_id=str(owner.principal.client_id),
        )
    assert status["status"] == "expired" and status["manifest"] is None
    with Session(postgres_engine) as session, pytest.raises(ApiError) as failure:
        create_group_pull(session, owner.principal, body)
    assert failure.value.status == 410


def test_permission_change_denies_cached_step_and_ready_pages(postgres_engine):
    owner, viewer = actor(postgres_engine), actor(postgres_engine)
    share(postgres_engine, owner, viewer, "viewer")
    _, status = create(postgres_engine, viewer)
    used = status["next_step_token"]
    status = step(postgres_engine, viewer, status, work_limit=1)
    status = ready(postgres_engine, viewer, status)
    revoke(postgres_engine, owner, viewer)
    with pytest.raises(ApiError) as failure:
        step(postgres_engine, viewer, status, token=used)
    assert failure.value.code in {"scope_forbidden", "permission_changed"}
    with pytest.raises(ApiError) as failure:
        pages(postgres_engine, viewer, status)
    assert failure.value.code in {"scope_forbidden", "permission_changed"}


def test_concurrent_identical_step_is_one_durable_receipt(postgres_engine):
    owner = actor(postgres_engine)
    _, initial = create(postgres_engine, owner)
    with ThreadPoolExecutor(max_workers=2) as pool:
        values = list(
            pool.map(lambda _: step(postgres_engine, owner, initial, work_limit=1), range(2))
        )
    assert values[0] == values[1]
    with Session(postgres_engine) as session:
        assert (
            session.scalar(
                select(func.count())
                .select_from(GroupPullPage)
                .where(
                    GroupPullPage.pull_id == UUID(initial["pull_id"]), GroupPullPage.kind == "step"
                )
            )
            == 1
        )


def test_step_deadline_rolls_back_only_unfinished_work_and_can_resume(postgres_engine, monkeypatch):
    from flowtrace_server.sync import group_materializer as materializer

    owner = actor(postgres_engine)
    _, initial = create(postgres_engine, owner)
    original = materializer._discover
    calls = 0
    first_state = None

    def stalled(session, record, state, limits, cache):
        nonlocal calls, first_state
        calls += 1
        original(session, record, state, limits, cache)
        if calls == 1:
            first_state = deepcopy(state)
        if calls == 2:
            session.execute(text("SELECT pg_sleep(6)"))

    monkeypatch.setattr(materializer, "_discover", stalled)
    started = monotonic()
    result = step(postgres_engine, owner, initial, work_limit=32)
    elapsed = monotonic() - started
    assert elapsed < 5.5 and calls == 2
    with Session(postgres_engine) as session:
        record = session.get(GroupPullSession, UUID(result["pull_id"]))
        expected = {**first_state, "step_index": 1}
        assert record.build_state == expected
        assert record.page_count == 1
    monkeypatch.setattr(materializer, "_discover", original)
    assert ready(postgres_engine, owner, result)["status"] == "ready"


def test_publication_last_cursor_expands_full_unit_and_viewer_never_gets_namespace(postgres_engine):
    from data_tools.test_staging_parsers import source_file
    from data_tools.test_staging_preview import categories
    from data_tools.test_staging_publish import apply as stage_apply
    from data_tools.test_staging_publish import ready as stage_ready

    from flowtrace_server.imports.staging_models import ImportPublicationChunk

    owner, viewer = actor(postgres_engine), actor(postgres_engine)
    share(postgres_engine, owner, viewer, "viewer")
    stage, _, _, lease = stage_ready(
        postgres_engine, owner, source_file("flowtrace_json", categories(owner, 201))
    )
    assert stage_apply(postgres_engine, lease)["created_count"] == 201
    with Session(postgres_engine) as session:
        chunks = list(
            session.scalars(
                select(ImportPublicationChunk)
                .where(ImportPublicationChunk.publication_id == UUID(stage.stage_id))
                .order_by(ImportPublicationChunk.chunk_index)
            )
        )
        assert len(chunks) == 2
        first_revision = session.scalar(
            select(func.max(SyncChange.scope_revision)).where(
                SyncChange.commit_id == chunks[0].commit_id
            )
        )
    _, initial = create(postgres_engine, viewer, cursors={str(owner.book_id): str(first_revision)})
    result = ready(postgres_engine, viewer, initial, work_limit=2)
    wire = pages(postgres_engine, viewer, result)
    units = [unit for page in wire if page["kind"] == "index" for unit in page["units"]]
    publication = next(unit for unit in units if unit["kind"] == "publication")
    assert publication["commit_count"] == 2 and publication["event_count"] == 201
    frames = [
        fragment
        for page in wire
        if page["kind"] == "data" and page["group_id"] == publication["group_id"]
        for fragment in page["fragments"]
    ]
    assert [frame["commit_index"] for frame in frames] == [0, 1]
    raw = canonical_bytes({"ready": result, "pages": wire})
    assert str(stage.stage_id).encode() not in raw
    assert str(owner.principal.user_id).encode() not in raw
    assert (
        b"chunk_index" not in raw and b"private_event_count" not in raw and b"token_seed" not in raw
    )


@pytest.mark.parametrize("corruption", ["sha", "count"])
def test_private_publication_chunk_integrity_fails_closed(postgres_engine, corruption):
    from data_tools.test_staging_parsers import source_file
    from data_tools.test_staging_preview import categories
    from data_tools.test_staging_publish import apply as stage_apply
    from data_tools.test_staging_publish import ready as stage_ready

    from flowtrace_server.imports.staging_models import ImportPublicationChunk

    owner = actor(postgres_engine)
    stage, _, _, lease = stage_ready(
        postgres_engine, owner, source_file("flowtrace_json", categories(owner, 2))
    )
    stage_apply(postgres_engine, lease)
    with Session(postgres_engine) as session:
        row = session.get(ImportPublicationChunk, (UUID(stage.stage_id), 0))
        if corruption == "sha":
            row.sha256 = "0" * 64
        else:
            row.event_count += 1
        session.commit()
    _, initial = create(postgres_engine, owner)
    with pytest.raises(ApiError) as failure:
        ready(postgres_engine, owner, initial)
    assert failure.value.code == "group_projection_invalid"
    with Session(postgres_engine) as session:
        assert session.get(GroupPullSession, UUID(initial["pull_id"])).manifest is None


def test_stored_page_corruption_rejected_without_raw_validation_details(postgres_engine):
    owner = actor(postgres_engine)
    _, initial = create(postgres_engine, owner)
    result = ready(postgres_engine, owner, initial)
    with Session(postgres_engine) as session:
        page = session.scalar(
            select(GroupPullPage).where(
                GroupPullPage.pull_id == UUID(initial["pull_id"]), GroupPullPage.kind == "data"
            )
        )
        page.response = {**page.response, "unexpected_private_secret": "Synthetic-only-secret"}
        session.commit()
    with pytest.raises(ApiError) as failure:
        pages(postgres_engine, owner, result)
    assert failure.value.code == "group_projection_invalid"
    assert "Synthetic-only-secret" not in str(failure.value)


def test_quota_failure_does_not_advance_or_publish_manifest(postgres_engine):
    owner = actor(postgres_engine)
    _, initial = create(
        postgres_engine, owner, limits=GroupReadLimits(session_bytes=1024, page_bytes=1024)
    )
    with Session(postgres_engine) as session:
        row = session.get(GroupPullSession, UUID(initial["pull_id"]))
        prior = (deepcopy(row.build_state), row.page_count, row.reserved_bytes)
    with Session(postgres_engine) as session, pytest.raises(ApiError) as failure:
        step_group_pull(
            session,
            owner.principal,
            UUID(initial["pull_id"]),
            GroupPullStep(
                client_id=str(owner.principal.client_id), step_token=initial["next_step_token"]
            ),
            limits=GroupReadLimits(session_bytes=1024, page_bytes=1024),
        )
    assert failure.value.code == "group_storage_quota"
    with Session(postgres_engine) as session:
        row = session.get(GroupPullSession, UUID(initial["pull_id"]))
        assert (row.build_state, row.page_count, row.reserved_bytes) == prior
        assert row.manifest is None


@pytest.mark.parametrize("change", ["origin", "device", "epoch", "expiry"])
def test_current_identity_and_ttl_fence_cached_step_and_ready_page(postgres_engine, change):
    from flowtrace_server.auth.dependencies import Principal
    from flowtrace_server.auth.models import User
    from flowtrace_server.auth.service import issue_session
    from flowtrace_server.persistence.models import ServerState
    from flowtrace_server.sync.models import SyncClient

    owner = actor(postgres_engine)
    _, initial = create(postgres_engine, owner)
    used = initial["next_step_token"]
    result = ready(postgres_engine, owner, initial)
    old_epoch = epoch(postgres_engine)
    principal = owner.principal
    with Session(postgres_engine) as session:
        if change == "origin":
            issued, _ = issue_session(
                session,
                session.get(User, principal.user_id),
                principal.client_id,
                "独立会话",
                principal.purpose,
            )
            principal = Principal(
                principal.user_id, issued.id, principal.client_id, principal.purpose, frozenset()
            )
        elif change == "device":
            session.get(SyncClient, (principal.user_id, principal.client_id)).frozen = True
        elif change == "epoch":
            session.get(ServerState, 1).sync_epoch = uuid4()
        else:
            session.get(GroupPullSession, UUID(result["pull_id"])).expires_at = now() - timedelta(
                seconds=1
            )
        session.commit()
    try:
        with Session(postgres_engine) as session, pytest.raises(ApiError):
            step_group_pull(
                session,
                principal,
                UUID(result["pull_id"]),
                GroupPullStep(client_id=str(principal.client_id), step_token=used),
            )
        with Session(postgres_engine) as session, pytest.raises(ApiError):
            read_group_pull_page(
                session,
                principal,
                UUID(result["pull_id"]),
                GroupPullPageRequest(
                    client_id=str(principal.client_id), page_token=result["first_page_token"]
                ),
            )
    finally:
        if change == "epoch":
            with Session(postgres_engine) as session:
                session.get(ServerState, 1).sync_epoch = UUID(old_epoch)
                session.commit()


def test_private_account_events_are_filtered_and_visible_hashes_recomputed(postgres_engine):
    from data_tools.test_publication import staged_snapshot
    from data_tools.test_staging_parsers import source_file
    from data_tools.test_staging_publish import apply as stage_apply
    from data_tools.test_staging_publish import ready as stage_ready

    from flowtrace_server.imports.staging_models import ImportPublicationChunk

    owner, viewer = actor(postgres_engine), actor(postgres_engine)
    cash = account(postgres_engine, owner)
    share(postgres_engine, owner, viewer, "viewer")
    snapshot = staged_snapshot(postgres_engine, owner, cash, expense_count=3)
    stage, _, _, lease = stage_ready(
        postgres_engine,
        owner,
        source_file("flowtrace_json", [row.model_dump() for row in snapshot.rows]),
    )
    stage_apply(postgres_engine, lease)
    _, initial = create(postgres_engine, viewer)
    result = ready(postgres_engine, viewer, initial)
    wire = pages(postgres_engine, viewer, result)
    unit = next(
        unit
        for page in wire
        if page["kind"] == "index"
        for unit in page["units"]
        if unit["kind"] == "publication"
    )
    events = [
        event
        for page in wire
        if page["kind"] == "data" and page["group_id"] == unit["group_id"]
        for fragment in page["fragments"]
        for event in fragment["events"]
    ]
    manifests = [
        page for page in wire if page["kind"] == "manifest" and page["group_id"] == unit["group_id"]
    ]
    descriptor = next(item for page in manifests for item in page["commits"])
    with Session(postgres_engine) as session:
        raw = session.get(ImportPublicationChunk, (UUID(stage.stage_id), 0))
        assert raw.event_count > len(events) and raw.sha256 != descriptor["events_sha256"]
    assert unit["event_count"] == len(events) == 4
    assert descriptor["events_sha256"] == content_hash(events)
    assert str(cash).encode() not in canonical_bytes(wire)
    assert all(event["scope_id"] != str(owner.principal.user_id) for event in events)
    assert str(owner.principal.user_id) not in result["manifest"]["permission_versions"]


def add_history(engine, owner, events):
    """Synthetic immutable history fixture, not a financial writer benchmark."""
    with Session(engine) as session:
        scope = session.get(SyncScope, owner.book_id)
        revision, rows = scope.revision, []
        for offset in range(0, len(events), 200):
            revision += 1
            commit_id = uuid4()
            for index, value in enumerate(events[offset : offset + 200]):
                rows.append(
                    {
                        "scope_id": owner.book_id,
                        "scope_revision": revision,
                        "event_index": index,
                        "commit_id": commit_id,
                        "entity_type": value["entity_type"],
                        "entity_id": UUID(value["entity_id"]),
                        "revision": int(value["revision"]),
                        "deleted": value["deleted"],
                        "data": value["data"],
                        "created_at": now(),
                    }
                )
            if len(rows) >= 1000:
                session.execute(insert(SyncChange), rows)
                rows.clear()
        if rows:
            session.execute(insert(SyncChange), rows)
        scope.revision = revision
        session.commit()


def test_bootstrap_above_legacy_50000_uses_finite_stream_without_snapshot(postgres_engine):
    owner = actor(postgres_engine)
    values = [
        {
            "entity_type": "category",
            "entity_id": str(uuid4()),
            "revision": "1",
            "deleted": True,
            "data": None,
        }
        for _ in range(50001)
    ]
    add_history(postgres_engine, owner, values)
    _, initial = create(postgres_engine, owner)
    assert initial["manifest"] is None
    result = ready(postgres_engine, owner, initial, work_limit=1024)
    wire = pages(postgres_engine, owner, result)
    events = [
        event
        for page in wire
        if page["kind"] == "data"
        for fragment in page["fragments"]
        for event in fragment["events"]
    ]
    assert sum(event["deleted"] for event in events) == 50001
    assert len(events) == 50002  # existing book creation remains in bootstrap
    units = [unit for page in wire if page["kind"] == "index" for unit in page["units"]]
    assert units[-1]["end_cursors"] == result["manifest"]["checkpoint"]


def test_full_commit_larger_than_transport_resumes_event_offsets_exactly(postgres_engine):
    from sync.groups.test_group_primitives import event

    owner = actor(postgres_engine)
    values = [event(index=index, note="𠮷" * 2000) for index in range(200)]
    add_history(postgres_engine, owner, values)
    _, initial = create(postgres_engine, owner)
    result = ready(postgres_engine, owner, initial, work_limit=1)
    wire = pages(postgres_engine, owner, result)
    data = [
        page
        for page in wire
        if page["kind"] == "data" and page["fragments"][0]["events"][0]["entity_type"] == "account"
    ]
    assert len(data) >= 3
    output = [
        item for page in data for fragment in page["fragments"] for item in fragment["events"]
    ]
    assert len(output) == 200
    assert [item["event_index"] for item in output] == list(range(200))
    assert all(item["data"]["balance"]["amount_minor"] == "9007199254740993" for item in output)


def test_actual_discard_frees_only_deleted_cache_keeps_request_tombstone(postgres_engine):
    from flowtrace_server.sync.group_models import GroupPullUnit

    owner = actor(postgres_engine)
    body, initial = create(postgres_engine, owner)
    result = ready(postgres_engine, owner, initial)
    create(postgres_engine, owner)
    with Session(postgres_engine) as session:
        old = session.get(GroupPullSession, UUID(initial["pull_id"]))
        intent = old.intent_hash
        assert old.page_count and old.reserved_bytes and old.unit_count
    renewed = actor(postgres_engine, existing_user=owner.principal.user_id)
    with Session(postgres_engine) as session:
        assert discard_group_pull(session, renewed.principal, UUID(initial["pull_id"])) == {
            "pull_id": initial["pull_id"],
            "status": "collected",
        }
    with Session(postgres_engine) as session:
        row = session.get(GroupPullSession, UUID(initial["pull_id"]))
        assert row.request_id == UUID(body.request_id) and row.intent_hash == intent
        assert row.build_state == {"collected": True}
        assert row.reserved_bytes == row.page_count == row.unit_count == 0
        assert (
            row.manifest
            is row.manifest_sha256
            is row.first_page_token
            is row.next_step_token_hash
            is None
        )
        assert not session.scalar(
            select(func.count()).select_from(GroupPullPage).where(GroupPullPage.pull_id == row.id)
        )
        assert not session.scalar(
            select(func.count()).select_from(GroupPullUnit).where(GroupPullUnit.pull_id == row.id)
        )
    create(postgres_engine, owner)
    with Session(postgres_engine) as session, pytest.raises(ApiError) as failure:
        create_group_pull(session, owner.principal, body)
    assert failure.value.status == 410
    with Session(postgres_engine) as session:
        discard_group_pull(session, renewed.principal, UUID(initial["pull_id"]))
    with pytest.raises(ApiError) as failure:
        pages(postgres_engine, owner, result)
    assert failure.value.code == "group_pull_collected"


def test_cache_discard_does_not_require_old_permissions_but_rejects_other_owner(postgres_engine):
    owner, member, stranger = actor(postgres_engine), actor(postgres_engine), actor(postgres_engine)
    share(postgres_engine, owner, member)
    _, initial = create(postgres_engine, member)
    ready(postgres_engine, member, initial)
    revoke(postgres_engine, owner, member)
    with Session(postgres_engine) as session:
        row = session.get(GroupPullSession, UUID(initial["pull_id"]))
        row.expires_at = now() - timedelta(seconds=1)
        session.commit()
    with Session(postgres_engine) as session, pytest.raises(ApiError) as failure:
        discard_group_pull(session, stranger.principal, UUID(initial["pull_id"]))
    assert failure.value.code == "not_found"
    with Session(postgres_engine) as session:
        assert session.get(GroupPullSession, UUID(initial["pull_id"])).reserved_bytes > 0
        assert (
            discard_group_pull(session, member.principal, UUID(initial["pull_id"]))["status"]
            == "collected"
        )


def test_projection_ids_stable_within_pull_different_across_pulls_and_tokens_are_closed(
    postgres_engine,
):
    from flowtrace_server.sync.group_service import opaque_token

    owner = actor(postgres_engine)
    body, first = create(postgres_engine, owner)
    first = ready(postgres_engine, owner, first)
    _, second = create(postgres_engine, owner)
    second = ready(postgres_engine, owner, second)
    first_ids = {
        unit["group_id"]
        for page in pages(postgres_engine, owner, first)
        if page["kind"] == "index"
        for unit in page["units"]
    }
    second_ids = {
        unit["group_id"]
        for page in pages(postgres_engine, owner, second)
        if page["kind"] == "index"
        for unit in page["units"]
    }
    assert first_ids and second_ids and first_ids.isdisjoint(second_ids)
    with Session(postgres_engine) as session:
        assert create_group_pull(session, owner.principal, body) == first
        changed = body.model_copy(update={"cursors": {str(owner.principal.user_id): "0"}})
        with pytest.raises(ApiError) as failure:
            create_group_pull(session, owner.principal, changed)
        assert failure.value.code == "group_intent_mismatch"
    with Session(postgres_engine) as session:
        record = session.get(GroupPullSession, UUID(first["pull_id"]))
        private_plan_token = opaque_token(record, "plan", 0, 0)
    for token in (second["first_page_token"], private_plan_token):
        with Session(postgres_engine) as session, pytest.raises(ApiError) as failure:
            read_group_pull_page(
                session,
                owner.principal,
                UUID(first["pull_id"]),
                GroupPullPageRequest(client_id=str(owner.principal.client_id), page_token=token),
            )
        assert failure.value.code == "not_found"
