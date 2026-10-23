"""Server-only atomic publication; no persistent-stage or client-group claim."""

from dataclasses import replace
from uuid import UUID, uuid4, uuid5

import pytest
from pydantic import ValidationError
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from sync.helpers import account, actor, epoch, expense, revoke, share

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.books.models import SyncScope
from flowtrace_server.imports.models import ImportBatch
from flowtrace_server.imports.parsers import digest
from flowtrace_server.imports.publication import (
    PublicationStageSnapshot,
    apply_publication,
    apply_publication_in_transaction,
    request_from_stage,
    undo_publication,
)
from flowtrace_server.imports.schemas import ImportDocument, ImportRow, UndoRequest
from flowtrace_server.imports.service import undo_import
from flowtrace_server.sync.models import SyncChange, SyncEntity
from flowtrace_server.sync.reader import pull
from flowtrace_server.sync.schemas import PullRequest

from .test_import_transactions import state

pytestmark = pytest.mark.postgres


def staged_snapshot(engine, owner, cash, *, expense_count=201):
    namespace = "publication-" + uuid4().hex
    sources = sorted(
        (str(uuid4()) for _ in range(expense_count + 1)),
        key=lambda value: uuid5(owner.principal.user_id, namespace + ":" + value).hex,
    )
    expenses = [
        ImportRow(
            source_id=source,
            entity_type="bill",
            scope_id=str(owner.book_id),
            payload=expense(owner.book_id, cash, "100"),
        )
        for source in sources[:-1]
    ]
    refund = expense(
        owner.book_id,
        cash,
        "1",
        bill_type="refund",
        allocations=[
            {"source_bill_id": sources[0], "source_amount_minor": "1", "receipt_amount_minor": "1"}
        ],
    )
    # A dependent receipt intentionally comes first in the staged file.
    rows = (
        ImportRow(
            source_id=sources[-1], entity_type="bill", scope_id=str(owner.book_id), payload=refund
        ),
        *expenses,
    )
    return PublicationStageSnapshot(
        stage_id=uuid4(),
        batch_id=uuid4(),
        user_id=owner.principal.user_id,
        client_id=owner.principal.client_id,
        sync_epoch=UUID(epoch(engine)),
        version=1,
        source_sha256=digest([row.model_dump() for row in rows]),
        source_namespace=namespace,
        rows=rows,
    )


def cursors(engine, owner):
    with Session(engine) as session:
        return {
            str(scope.id): str(scope.revision)
            for scope in session.scalars(
                select(SyncScope).where(SyncScope.id.in_([owner.principal.user_id, owner.book_id]))
            )
        }


def complete_pull(engine, owner, snapshot, initial):
    token, commits, seen = None, [], set()
    for _ in range(30):
        with Session(engine) as session:
            response = pull(
                session,
                owner.principal,
                PullRequest(
                    sync_epoch=str(snapshot.sync_epoch),
                    cursors=initial,
                    limit=100,
                    page_token=token,
                ),
            )
        for commit in response["commits"]:
            assert commit["commit_id"] not in seen
            assert 1 <= len(commit["events"]) <= 200
            seen.add(commit["commit_id"])
            commits.append(commit)
        token = response["next_page_token"]
        if token is None:
            return commits, response["checkpoint"]
        assert response["checkpoint"] is None
    raise AssertionError("publication pull did not terminate")


def test_large_server_publication_replays_pulls_complete_chunks_and_undoes(postgres_engine):
    owner = actor(postgres_engine)
    cash = account(postgres_engine, owner, opening="1000000")
    snapshot = staged_snapshot(postgres_engine, owner, cash)
    initial = cursors(postgres_engine, owner)
    old = state(postgres_engine, owner)
    observed = []

    def while_uncommitted(index):
        # Another connection cannot observe even the first published chunk.
        assert state(postgres_engine, owner) == old
        observed.append(index)

    with Session(postgres_engine) as session:
        result = apply_publication(
            session, owner.principal, snapshot, before_chunk=while_uncommitted
        )
    assert len(result.created) == 202 and len(result.commit_ids) == 3
    assert observed == [0, 1, 2] and result.commit_id is None
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, cash).balance_minor == 979901
        stored = session.get(ImportBatch, snapshot.batch_id)
        assert stored.result["commit_ids"] == result.commit_ids
        assert stored.result["publication_id"] == str(snapshot.stage_id)
    committed = state(postgres_engine, owner)
    with Session(postgres_engine) as session:
        replay = apply_publication(session, owner.principal, snapshot)
    assert replay.replayed and replay.commit_ids == result.commit_ids
    assert state(postgres_engine, owner) == committed
    commits, checkpoint = complete_pull(postgres_engine, owner, snapshot, initial)
    assert {commit["commit_id"] for commit in commits} == set(result.commit_ids)
    source = str(
        uuid5(owner.principal.user_id, snapshot.source_namespace + ":" + snapshot.rows[1].source_id)
    )
    refund = str(
        uuid5(owner.principal.user_id, snapshot.source_namespace + ":" + snapshot.rows[0].source_id)
    )
    public = {
        event["entity_id"]: (commit["commit_id"], event)
        for commit in commits
        for event in commit["events"]
        if event["scope_id"] == str(owner.book_id)
    }
    assert public[source][0] != public[refund][0]
    assert public[source][1]["data"]["source_summary"]["remaining_source_minor"] == "99"
    assert public[refund][1]["data"]["payload"]["allocations"][0]["source_bill_id"] == source
    assert all(checkpoint[key] == value for key, value in result.scope_revisions.items())
    # The ordinary public undo never serializes an internal multi-commit receipt.
    with Session(postgres_engine) as session, pytest.raises(ApiError) as error:
        undo_import(
            session,
            owner.principal,
            snapshot.batch_id,
            UndoRequest(client_id=str(snapshot.client_id), sync_epoch=str(snapshot.sync_epoch)),
        )
    assert error.value.code == "import_publication_context_required"
    with Session(postgres_engine) as session:
        undone = undo_publication(session, owner.principal, snapshot)
    assert len(undone.commit_ids) == 3 and not set(undone.commit_ids) & set(result.commit_ids)
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, cash).balance_minor == 1000000
    reverse, _ = complete_pull(postgres_engine, owner, snapshot, checkpoint)
    assert {commit["commit_id"] for commit in reverse} == set(undone.commit_ids)
    assert all(
        event["deleted"]
        for commit in reverse
        for event in commit["events"]
        if event["entity_id"] in result.created
    )
    with Session(postgres_engine) as session:
        replayed = undo_publication(session, owner.principal, snapshot)
    assert replayed.replayed and not replayed.commit_ids and not replayed.scope_revisions


@pytest.mark.parametrize("failure", ["last_domain_row", "last_sync_chunk"])
def test_late_failure_leaves_no_financial_or_publication_partial_result(postgres_engine, failure):
    owner = actor(postgres_engine)
    cash = account(postgres_engine, owner, opening="1000000")
    snapshot = staged_snapshot(postgres_engine, owner, cash)
    if failure == "last_domain_row":
        last = snapshot.rows[-1].model_dump()
        last["payload"]["account_id"] = str(uuid4())
        snapshot = replace(snapshot, rows=(*snapshot.rows[:-1], ImportRow.model_validate(last)))
    before = state(postgres_engine, owner)
    reached = []

    def crash(index):
        reached.append(index)
        if index == 2:
            raise RuntimeError("synthetic_last_chunk")

    expected = ApiError if failure == "last_domain_row" else RuntimeError
    with Session(postgres_engine) as session, pytest.raises(expected):
        apply_publication(session, owner.principal, snapshot, before_chunk=crash)
    assert state(postgres_engine, owner) == before
    assert reached == ([] if failure == "last_domain_row" else [0, 1, 2])
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, cash).balance_minor == 1000000


def test_publication_effect_uses_callers_outer_transaction_and_current_authority(postgres_engine):
    owner, member = actor(postgres_engine), actor(postgres_engine)
    cash = account(postgres_engine, owner, opening="10000")
    snapshot = staged_snapshot(postgres_engine, owner, cash, expense_count=2)
    before = state(postgres_engine, owner)
    with Session(postgres_engine) as session:
        session.begin()
        result = apply_publication_in_transaction(session, owner.principal, snapshot)
        assert result.created
        session.rollback()
    assert state(postgres_engine, owner) == before
    with pytest.raises(ValidationError):
        ImportDocument.model_validate(
            {
                "format": "flowtrace-data-v1",
                "source_namespace": "unchanged-http-limit",
                "rows": [snapshot.rows[1].model_dump() for _ in range(51)],
            }
        )
    with pytest.raises(ApiError):
        request_from_stage({}, owner.principal)
    share(postgres_engine, owner, member)
    other = replace(
        snapshot, user_id=member.principal.user_id, client_id=member.principal.client_id
    )
    revoke(postgres_engine, owner, member)
    before = state(postgres_engine, owner)
    with Session(postgres_engine) as session, pytest.raises(ApiError):
        apply_publication(session, member.principal, other)
    assert state(postgres_engine, owner) == before


def test_late_reverse_chunk_failure_keeps_applied_publication_and_balances(postgres_engine):
    owner = actor(postgres_engine)
    cash = account(postgres_engine, owner, opening="1000000")
    snapshot = staged_snapshot(postgres_engine, owner, cash)
    with Session(postgres_engine) as session:
        result = apply_publication(session, owner.principal, snapshot)
    before = state(postgres_engine, owner)

    def fail(index):
        if index == 2:
            raise RuntimeError("synthetic_undo_last_chunk")

    with Session(postgres_engine) as session, pytest.raises(RuntimeError):
        undo_publication(session, owner.principal, snapshot, before_chunk=fail)
    assert state(postgres_engine, owner) == before
    with Session(postgres_engine) as session:
        assert session.get(ImportBatch, snapshot.batch_id).status == "applied"
        assert session.get(SyncEntity, cash).balance_minor == 979901
        assert (
            session.scalar(
                select(func.count())
                .select_from(SyncChange)
                .where(SyncChange.commit_id.in_([UUID(i) for i in result.commit_ids]))
            )
            > 200
        )
