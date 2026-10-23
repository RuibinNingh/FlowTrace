from copy import deepcopy
from datetime import timedelta
from uuid import UUID

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import now
from flowtrace_server.sync import reader
from flowtrace_server.sync.canonical import content_hash
from flowtrace_server.sync.models import SyncSnapshot
from flowtrace_server.sync.reader import create_snapshot, pull, snapshot_page, snapshot_status
from flowtrace_server.sync.responses import PullResponse, SnapshotPageResponse, SnapshotStatus
from flowtrace_server.sync.schemas import PullRequest, SnapshotPageRequest, SnapshotRequest

from .helpers import actor, epoch, expense, operation, push, revoke, share

pytestmark = pytest.mark.postgres


def snapshot_body(engine, actor):
    return SnapshotRequest.model_validate(
        {
            "protocol_version": 1,
            "client_id": str(actor.principal.client_id),
            "sync_epoch": epoch(engine),
            "scope_ids": [str(actor.book_id)],
        }
    )


def page_body(actor, token):
    return SnapshotPageRequest.model_validate(
        {"client_id": str(actor.principal.client_id), "page_token": token}
    )


def test_pull_immutable_pages_final_checkpoint_and_permission_binding(actors, postgres_engine):
    alice, bob, _ = actors
    share(postgres_engine, alice, bob)
    for index in range(3):
        assert (
            push(
                postgres_engine,
                alice,
                operation(alice.book_id, "bill", expense(alice.book_id, amount=str(index + 1))),
            )[0]["status"]
            == "applied"
        )
    body = PullRequest.model_validate(
        {"sync_epoch": epoch(postgres_engine), "cursors": {}, "limit": 1, "page_token": None}
    )
    with Session(postgres_engine) as session:
        first = pull(session, bob.principal, body)
    PullResponse.model_validate(first)
    assert first["checkpoint"] is None and first["next_page_token"]
    continuation = body.model_copy(update={"page_token": first["next_page_token"]})
    with Session(postgres_engine) as session:
        second = pull(session, bob.principal, continuation)
        assert pull(session, bob.principal, continuation) == second
    push(
        postgres_engine, alice, operation(alice.book_id, "bill", expense(alice.book_id, amount="9"))
    )
    with Session(postgres_engine) as session:
        assert pull(session, bob.principal, continuation) == second
        with pytest.raises(ApiError) as error:
            pull(session, bob.principal, continuation.model_copy(update={"limit": 2}))
        assert error.value.code == "pull_intent_mismatch"
    revoke(postgres_engine, alice, bob)
    with Session(postgres_engine) as session:
        with pytest.raises(ApiError):
            pull(session, bob.principal, continuation)


def test_snapshot_manifest_pages_are_complete_frozen_and_hashable(actors, postgres_engine):
    alice, _, _ = actors
    commands = [
        operation(alice.book_id, "tag", {"name": "合成标签" + str(index), "color": "#12AB34"})
        for index in range(201)
    ]
    for offset in range(0, len(commands), 100):
        assert all(
            item["status"] == "applied"
            for item in push(postgres_engine, alice, commands[offset : offset + 100])
        )
    with Session(postgres_engine) as session:
        snapshot = create_snapshot(session, alice.principal, snapshot_body(postgres_engine, alice))
    SnapshotStatus.model_validate(snapshot)
    manifest = snapshot["manifest"]
    assert snapshot["manifest_sha256"] == content_hash(manifest)
    assert len(manifest["pages"]) == 2
    assert [page["page_index"] for page in manifest["pages"]] == [0, 1]
    token, received, original_page = snapshot["first_page_token"], [], None
    for expected in manifest["pages"]:
        with Session(postgres_engine) as session:
            page = snapshot_page(
                session, alice.principal, UUID(snapshot["snapshot_id"]), page_body(alice, token)
            )
        SnapshotPageResponse.model_validate(page)
        assert content_hash(page["items"]) == expected["sha256"] == page["page_sha256"]
        assert len(page["items"]) == expected["item_count"]
        assert page["page_index"] == expected["page_index"]
        if original_page is None:
            original_page = deepcopy(page)
        received.extend(page["items"])
        token = page["next_page_token"]
    assert token is None
    assert len(received) == 202  # The book itself plus every tag.
    assert (
        len({(item["scope_id"], item["entity_type"], item["entity_id"]) for item in received})
        == 202
    )
    push(
        postgres_engine,
        alice,
        operation(alice.book_id, "tag", {"name": "快照之后", "color": "#123456"}),
    )
    with Session(postgres_engine) as session:
        assert (
            snapshot_page(
                session,
                alice.principal,
                UUID(snapshot["snapshot_id"]),
                page_body(alice, snapshot["first_page_token"]),
            )
            == original_page
        )
        assert (
            snapshot_status(session, alice.principal, UUID(snapshot["snapshot_id"]))[
                "manifest_sha256"
            ]
            == snapshot["manifest_sha256"]
        )


def test_snapshot_bound_to_device_expiry_permission_and_atomic_limit(
    actors, postgres_engine, monkeypatch
):
    alice, bob, _ = actors
    share(postgres_engine, alice, bob)
    second_device = actor(postgres_engine, bob.principal.user_id)
    body = SnapshotRequest.model_validate(
        {**snapshot_body(postgres_engine, bob).model_dump(), "scope_ids": [str(alice.book_id)]}
    )
    with Session(postgres_engine) as session:
        snapshot = create_snapshot(session, bob.principal, body)
    identifier = UUID(snapshot["snapshot_id"])
    with Session(postgres_engine) as session:
        with pytest.raises(ApiError) as denied:
            snapshot_status(session, second_device.principal, identifier)
        assert denied.value.status == 404
    monkeypatch.setattr(reader, "MAX_SNAPSHOT_ITEMS", 0)
    with Session(postgres_engine) as session:
        with pytest.raises(ApiError) as limit:
            create_snapshot(session, bob.principal, body)
        assert limit.value.status == 413
        assert (
            session.scalar(
                select(func.count())
                .select_from(SyncSnapshot)
                .where(SyncSnapshot.user_id == bob.principal.user_id)
            )
            == 1
        )
    revoke(postgres_engine, alice, bob)
    with Session(postgres_engine) as session:
        with pytest.raises(ApiError):
            snapshot_page(
                session, bob.principal, identifier, page_body(bob, snapshot["first_page_token"])
            )
    monkeypatch.setattr(reader, "MAX_SNAPSHOT_ITEMS", 200000)
    with Session(postgres_engine) as session:
        fresh = create_snapshot(session, alice.principal, snapshot_body(postgres_engine, alice))
        session.get(SyncSnapshot, UUID(fresh["snapshot_id"])).expires_at = now() - timedelta(
            seconds=1
        )
        session.commit()
        expired = snapshot_status(session, alice.principal, UUID(fresh["snapshot_id"]))
        assert expired["status"] == "expired" and expired["manifest"] is None
        with pytest.raises(ApiError) as expiry:
            snapshot_page(
                session,
                alice.principal,
                UUID(fresh["snapshot_id"]),
                page_body(alice, fresh["first_page_token"]),
            )
        assert expiry.value.status == 410


def test_pull_rejects_foreign_cursor_keys_and_out_of_range_highwater(actors, postgres_engine):
    alice, bob, _ = actors
    for cursors in [{str(bob.book_id): "0"}, {str(alice.book_id): "9223372036854775807"}]:
        with Session(postgres_engine) as session:
            with pytest.raises(ApiError):
                pull(
                    session,
                    alice.principal,
                    PullRequest.model_validate(
                        {
                            "sync_epoch": epoch(postgres_engine),
                            "cursors": cursors,
                            "limit": 100,
                            "page_token": None,
                        }
                    ),
                )
