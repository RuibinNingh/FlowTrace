"""Pure/DDL evidence only: no migration, PG materializer or public route claim."""

import json
from copy import deepcopy
from pathlib import Path
from uuid import UUID

import pytest
from pydantic import ValidationError
from sqlalchemy.dialects import postgresql
from sqlalchemy.schema import CreateIndex, CreateTable

from flowtrace_server.sync.canonical import canonical_bytes, content_hash
from flowtrace_server.sync.group_reader import (
    CommitPosition,
    GroupReadError,
    GroupReadLimits,
    iter_group_data_pages,
    order_atomic_units,
    project_commit,
)
from flowtrace_server.sync.group_schemas import (
    MAX_PAGE_BYTES,
    GroupCommitDescriptor,
    GroupDataPage,
    GroupFragment,
    GroupPullCreate,
    GroupPullStatus,
    GroupUnitIndexPage,
    GroupUnitManifestPage,
    page_hash_payload,
)


def uid(number):
    return UUID(int=number)


def event(scope=1, revision=1, index=0, *, note=None):
    value = {
        "scope_id": str(uid(scope)),
        "scope_revision": str(revision),
        "event_index": index,
        "entity_type": "account",
        "entity_id": str(uid(1000 + index)),
        "revision": "1",
        "deleted": True,
        "data": None,
    }
    if note is not None:
        money = {"currency": "CNY", "currency_scale": 2, "amount_minor": "9007199254740993"}
        value.update(
            deleted=False,
            data={
                "projection_kind": "account",
                "payload": {
                    "name": "合成账户",
                    "kind": "cash",
                    "opening": money,
                    "include_in_net_assets": True,
                    "hidden": False,
                    "note": note,
                },
                "balance": money,
            },
        )
    return value


def data_page(*, pull=101, group=102, events=None):
    raw = {
        "pull_id": str(uid(pull)),
        "group_id": str(uid(group)),
        "kind": "data",
        "page_index": 0,
        "next_page_token": None,
        "fragments": [{"commit_index": 0, "event_offset": 0, "events": events or [event()]}],
    }
    raw["page_sha256"] = content_hash(raw)
    # Delivery tokens are outside the content hash; scope/IDs/index are inside it.
    raw["page_sha256"] = content_hash(page_hash_payload(raw))
    return raw


@pytest.mark.parametrize(
    "change",
    [
        {"protocol_version": True},
        {"protocol_version": 1.0},
        {"url": "https://invalid"},
        {"path": "C:/never"},
        {"max_bytes": 999},
        {"origin_session_id": str(uid(8))},
        {"cursors": {str(uid(1)): "9223372036854775808"}},
        {"cursors": {str(uid(1)): 1}},
    ],
)
def test_create_intent_is_closed_and_caller_cannot_select_budgets_or_origin(change):
    body = {
        "protocol_version": 1,
        "request_id": str(uid(1)),
        "client_id": str(uid(2)),
        "sync_epoch": str(uid(3)),
        "cursors": {},
    }
    assert GroupPullCreate.model_validate(body).cursors == {}
    with pytest.raises(ValidationError):
        GroupPullCreate.model_validate({**body, **change})


def test_pending_status_has_no_installable_manifest_or_internal_counts():
    body = {
        "pull_id": str(uid(1)),
        "request_id": str(uid(2)),
        "sync_epoch": str(uid(3)),
        "expires_at": "2026-10-23T00:00:00Z",
        "status": "planning",
        "progress_code": "planning",
        "next_step_token": "x" * 32,
        "manifest": None,
        "manifest_sha256": None,
        "first_page_token": None,
    }
    assert GroupPullStatus.model_validate(body).manifest is None
    for extra in (
        {"publication_id": str(uid(9))},
        {"private_chunk_count": 10},
        {"manifest_sha256": "a" * 64},
        {"first_page_token": "x" * 32},
    ):
        with pytest.raises(ValidationError):
            GroupPullStatus.model_validate({**body, **extra})


@pytest.mark.parametrize(
    "changes",
    [
        {"commit_index": True},
        {"event_count": 201},
        {"event_count": 0},
        {"events_sha256": "f" * 63},
        {"original_chunk_index": 9},
    ],
)
def test_commit_descriptor_is_dense_bounded_and_has_no_original_position(changes):
    body = {
        "commit_index": 0,
        "commit_id": str(uid(1)),
        "event_count": 1,
        "events_sha256": "a" * 64,
    }
    with pytest.raises(ValidationError):
        GroupCommitDescriptor.model_validate({**body, **changes})


@pytest.mark.parametrize(
    "change",
    [
        {"pull_id": str(uid(99))},
        {"group_id": str(uid(99))},
        {"page_index": 1},
        {"page_sha256": "0" * 64},
    ],
)
def test_page_hash_binds_pull_group_index_and_raw_content(change):
    body = data_page()
    assert GroupDataPage.model_validate(body)
    with pytest.raises(ValidationError):
        GroupDataPage.model_validate({**body, **change})


def test_projection_filters_private_events_and_preserves_raw_default_absence():
    raw = [event(1, index=0, note="中文"), event(2, index=1, note="private-never-wire")]
    projected = project_commit(uid(10), raw, {uid(1)})
    assert projected.descriptor(0).event_count == 1
    assert "private-never-wire" not in projected.events_json
    assert "archived" not in projected.events[0]["data"]["payload"]
    raw[0]["data"]["payload"]["note"] = "later caller mutation"
    assert projected.events[0]["data"]["payload"]["note"] == "中文"
    assert project_commit(uid(11), [event(2)], {uid(1)}) is None


def test_publication_chunk_order_beats_disjoint_scope_uuid_order_and_hides_gaps():
    # Original chunk 1 is entirely private. Its index and namespace stay internal.
    namespace = uid(900)
    units = order_atomic_units(
        [CommitPosition(uid(30), ((uid(1), 1),)), CommitPosition(uid(10), ((uid(2), 1),))],
        {namespace: (uid(30), uid(20), uid(10))},
        {},
        opaque_id_factory=lambda: uid(901),
    )
    assert len(units) == 1 and units[0].group_id == uid(901)
    assert units[0].commit_ids == (uid(30), uid(10))
    assert str(namespace) not in repr(units[0])


def test_scope_dag_puts_ordinary_predecessor_before_whole_group_and_uses_safe_prefix():
    opaque = iter((uid(501), uid(502), uid(503)))
    units = order_atomic_units(
        [
            CommitPosition(uid(30), ((uid(1), 3),)),
            CommitPosition(uid(10), ((uid(1), 1),)),
            CommitPosition(uid(20), ((uid(1), 2),)),
        ],
        {uid(900): (uid(20), uid(30))},
        {uid(1): 0, uid(2): 8},
        opaque_id_factory=lambda: next(opaque),
    )
    assert [unit.kind for unit in units] == ["commit", "publication"]
    assert dict(units[0].end_cursors) == {uid(1): 1, uid(2): 8}
    assert dict(units[1].end_cursors) == {uid(1): 3, uid(2): 8}
    # A caller cursor beyond a replayed chunk must never move backwards.
    replay = order_atomic_units(
        [CommitPosition(uid(20), ((uid(1), 2),))], {uid(900): (uid(20),)}, {uid(1): 7}
    )
    assert dict(replay[0].end_cursors)[uid(1)] == 7


def test_corrupt_group_interleaving_creates_cycle_and_is_never_published():
    positions = [CommitPosition(uid(n), ((uid(1), n),)) for n in (1, 2, 3)]
    with pytest.raises(GroupReadError, match="topology_invalid"):
        order_atomic_units(positions, {uid(900): (uid(1), uid(3))}, {})
    with pytest.raises(GroupReadError, match="opaque_id_invalid"):
        order_atomic_units(
            [positions[0]], {uid(900): (uid(1),)}, {}, opaque_id_factory=lambda: uid(900)
        )


def test_long_200_event_commit_is_split_by_envelope_bytes_and_reassembled_exactly():
    raw = [event(index=index, note="😀" * 2000) for index in range(200)]
    assert len(canonical_bytes(raw)) > 1024 * 1024
    commit = project_commit(uid(10), raw, {uid(1)})
    pages = list(iter_group_data_pages(uid(101), uid(102), [commit]))
    assert len(pages) > 2
    rebuilt = []
    for index, page in enumerate(pages):
        assert page.page_index == index
        assert len(canonical_bytes(page.model_dump(mode="json"))) <= MAX_PAGE_BYTES
        assert sum(len(fragment.events) for fragment in page.fragments) <= 200
        for fragment in page.fragments:
            assert fragment.commit_index == 0 and fragment.event_offset == len(rebuilt)
            rebuilt.extend(fragment.events)
    assert rebuilt == raw
    assert content_hash(rebuilt) == commit.descriptor(0).events_sha256
    assert pages[-1].next_page_token is None
    assert all(page.next_page_token for page in pages[:-1])
    assert rebuilt[0]["data"]["balance"]["amount_minor"] == "9007199254740993"


@pytest.mark.parametrize(
    "limits,code",
    [
        (GroupReadLimits(page_bytes=1024), "event_too_large"),
        (GroupReadLimits(pages=1), "storage_limit"),
        (GroupReadLimits(session_bytes=MAX_PAGE_BYTES), "storage_limit"),
        (GroupReadLimits(events=1), "event_limit"),
    ],
)
def test_transport_limits_refuse_without_truncating_fields(limits, code):
    commit = project_commit(
        uid(10), [event(index=index, note="😀" * 2000) for index in range(200)], {uid(1)}
    )
    original = commit.events_json
    with pytest.raises(GroupReadError, match=code):
        list(iter_group_data_pages(uid(101), uid(102), [commit], limits=limits))
    assert commit.events_json == original


def test_fragment_bounds_and_trusted_limits_refuse_booleans_or_giant_controls():
    with pytest.raises(ValidationError):
        GroupFragment(commit_index=0, event_offset=199, events=[event(), event(index=1)])
    for changes in (
        {"step_seconds": 6},
        {"scopes": 1001},
        {"retained_sessions": True},
        {"page_bytes": MAX_PAGE_BYTES + 1},
    ):
        with pytest.raises(ValueError, match="group_limits_invalid"):
            GroupReadLimits(**changes)


def test_three_new_tables_compile_without_mutating_old_pull_or_snapshot_shapes():
    from flowtrace_server.persistence import registry  # noqa: F401
    from flowtrace_server.sync.group_models import GroupPullPage, GroupPullSession, GroupPullUnit
    from flowtrace_server.sync.models import PullPage, PullSession, SnapshotPage
    from flowtrace_server.sync.responses import PullResponse

    before = [
        tuple(model.__table__.columns.keys()) for model in (PullSession, PullPage, SnapshotPage)
    ]
    for model in (GroupPullSession, GroupPullUnit, GroupPullPage):
        table = model.__table__
        ddl = str(CreateTable(table).compile(dialect=postgresql.dialect()))
        assert "CREATE TABLE group_pull_" in ddl
        for index in table.indexes:
            str(CreateIndex(index).compile(dialect=postgresql.dialect()))
    assert before == [
        tuple(model.__table__.columns.keys()) for model in (PullSession, PullPage, SnapshotPage)
    ]
    assert set(PullResponse.model_fields) == {
        "sync_epoch",
        "commits",
        "next_page_token",
        "checkpoint",
    }


def test_closed_golden_page_preserves_exact_hash_and_legacy_missing_defaults():
    path = Path(__file__).with_name("group-data-golden.json")
    literal = json.loads(path.read_text(encoding="utf-8"))
    validated = GroupDataPage.model_validate(literal)
    assert canonical_bytes(validated.model_dump(mode="json")) == canonical_bytes(literal)
    assert "archived" not in validated.fragments[0].events[0]["data"]["payload"]
    changed = deepcopy(literal)
    changed["fragments"][0]["events"][0]["data"]["payload"]["archived"] = False
    with pytest.raises(ValidationError, match="hash_invalid"):
        GroupDataPage.model_validate(changed)


def test_ready_hierarchical_golden_binds_every_page_and_unit_to_one_pull():
    literal = json.loads(
        Path(__file__).with_name("group-ready-golden.json").read_text(encoding="utf-8")
    )
    status = GroupPullStatus.model_validate(literal["status"])
    index = GroupUnitIndexPage.model_validate(literal["index_page"])
    metadata = GroupUnitManifestPage.model_validate(literal["unit_manifest_page"])
    data = GroupDataPage.model_validate(literal["data_page"])
    assert status.manifest.index_pages[0].sha256 == index.page_sha256
    assert index.units[0].manifest_parts[0].sha256 == metadata.page_sha256
    assert metadata.data_pages[0].sha256 == data.page_sha256
    assert metadata.commits[0].events_sha256 == content_hash(data.fragments[0].events)
    bad = deepcopy(literal["index_page"])
    bad["units"][0]["end_cursors"][str(uid(1))] = "99"
    # Even recomputing the outer page checksum cannot forge the unit chain.
    bad["page_sha256"] = content_hash(page_hash_payload(bad))
    with pytest.raises(ValidationError, match="unit_manifest_invalid"):
        GroupUnitIndexPage.model_validate(bad)


def test_publication_metadata_must_agree_with_per_scope_order():
    positions = [CommitPosition(uid(1), ((uid(9), 1),)), CommitPosition(uid(2), ((uid(9), 2),))]
    with pytest.raises(GroupReadError, match="publication_order_invalid"):
        order_atomic_units(positions, {uid(900): (uid(2), uid(1))}, {})
    with pytest.raises(GroupReadError, match="scope_limit"):
        order_atomic_units([positions[0]], {}, {uid(8): 0}, limits=GroupReadLimits(scopes=1))


def test_new_projection_rejects_live_null_payload_or_overflowed_entity_revision():
    live_null = event()
    live_null["deleted"] = False
    overflow = event()
    overflow["revision"] = "9223372036854775808"
    for raw in (live_null, overflow):
        with pytest.raises(ValueError):
            project_commit(uid(9), [raw], {uid(1)})
