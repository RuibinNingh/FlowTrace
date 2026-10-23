"""Actual PostgreSQL transactions exercise ownership, contention and lost leases."""

from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from threading import Barrier, Event
from uuid import uuid4

import pytest
from pydantic import ValidationError
from sqlalchemy import func, select, update
from sqlalchemy.exc import OperationalError
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.auth.models import User
from flowtrace_server.jobs import store
from flowtrace_server.jobs.models import BackgroundJob, JobAttempt, WorkerState
from flowtrace_server.persistence.models import ServerState


def job_snapshot(case, job_id):
    with Session(case.engine) as session:
        return store.metadata(session.get(BackgroundJob, job_id))


def effect_count(case):
    with Session(case.engine) as session:
        return session.scalar(
            select(func.count()).select_from(AdminAudit).where(AdminAudit.actor_id == case.owner_id)
        )


def force_available(case, job_id):
    with Session(case.engine) as session, session.begin():
        session.execute(
            update(BackgroundJob)
            .where(BackgroundJob.id == job_id)
            .values(available_at=store.stamp(session) - timedelta(seconds=1))
        )


@pytest.mark.parametrize(
    "kind,seconds",
    [
        ("backup_verify", 60),
        ("import_preview", 300),
        ("import_apply", 900),
        ("backup_create", 300),
        ("restore_rehearsal", 900),
        ("backup_quarantine", 900),
    ],
)
def test_fixed_kind_budget_is_used_by_claim_and_renew(queue_case, kind, seconds):
    case = queue_case
    job_id = case.enqueue(kind=kind)
    lease = case.claim({kind})
    assert lease.job_id == job_id
    with Session(case.engine) as session, session.begin():
        job = session.get(BackgroundJob, job_id)
        assert seconds <= (job.lease_until - job.updated_at).total_seconds() < seconds + 1
        before = store.stamp(session)
        store.renew(session, lease)
        assert seconds <= (job.lease_until - before).total_seconds() < seconds + 2


def test_same_occurrence_is_immutable_and_caller_rollback_is_atomic(queue_case):
    case = queue_case
    original = {"nested": {"a": 1, "b": [True, None]}}
    job_id = case.enqueue(payload=original)
    original["nested"]["a"] = 999
    with Session(case.engine) as session, session.begin():
        repeated = store.enqueue(
            session,
            kind="export",
            occurrence_key=f"{case.prefix}:one",
            owner_user_id=case.owner_id,
            payload={"nested": {"b": [True, None], "a": 1}},
        )
        assert repeated.id == job_id
        assert repeated.payload["nested"]["a"] == 1
        with pytest.raises(store.JobConflict, match="job_occurrence_conflict"):
            store.enqueue(
                session,
                kind="export",
                occurrence_key=f"{case.prefix}:one",
                owner_user_id=case.owner_id,
                payload={"nested": {"a": 2}},
            )
    with Session(case.engine) as session:
        rolled_back = store.enqueue(
            session,
            kind="export",
            occurrence_key=f"{case.prefix}:rollback",
            owner_user_id=case.owner_id,
            payload={},
        ).id
        session.rollback()
    with Session(case.engine) as session:
        assert session.get(BackgroundJob, rolled_back) is None


def test_two_connections_enqueue_one_occurrence(queue_case):
    case = queue_case
    together = Barrier(2)

    def enqueue():
        with Session(case.engine) as session, session.begin():
            together.wait(timeout=5)
            record = store.enqueue(
                session,
                kind="export",
                occurrence_key=f"{case.prefix}:race",
                owner_user_id=case.owner_id,
                payload={"one": 1},
            )
            return record.id

    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(enqueue) for _ in range(2)]
        assert futures[0].result(timeout=10) == futures[1].result(timeout=10)
    with Session(case.engine) as session:
        assert (
            session.scalar(
                select(func.count())
                .select_from(BackgroundJob)
                .where(BackgroundJob.owner_user_id == case.owner_id)
            )
            == 1
        )


def test_skip_locked_claims_another_job_without_waiting(queue_case):
    case = queue_case
    first = case.enqueue(key="first")
    second = case.enqueue(key="second")
    locked, release = Event(), Event()

    def hold_first_claim():
        with Session(case.engine) as session, session.begin():
            lease = store.claim(session, case.worker_id(), {"export"})
            assert lease.job_id == first
            locked.set()
            assert release.wait(timeout=8)
            return lease

    with ThreadPoolExecutor(max_workers=1) as executor:
        future = executor.submit(hold_first_claim)
        try:
            assert locked.wait(timeout=5)
            with Session(case.engine) as session, session.begin():
                session.connection().exec_driver_sql("SET LOCAL lock_timeout='1500ms'")
                other = store.claim(session, case.worker_id(), {"export"})
                assert other.job_id == second
                assert store.claim(session, case.worker_id(), {"export"}) is None
        finally:
            release.set()
        assert future.result(timeout=5).generation == 1
    assert job_snapshot(case, first)["status"] == "running"
    assert job_snapshot(case, second)["status"] == "running"


def test_expired_generation_cannot_renew_fail_or_apply_effect(queue_case):
    case = queue_case
    job_id = case.enqueue()
    old = case.claim()
    with Session(case.engine) as session, session.begin():
        session.execute(
            update(BackgroundJob)
            .where(BackgroundJob.id == job_id)
            .values(lease_until=store.stamp(session) - timedelta(seconds=1))
        )
    current = case.claim()
    assert current.generation == old.generation + 1
    for operation in (
        lambda session: store.renew(session, old),
        lambda session: store.fail(session, old, "fixture_failure", transient=False),
        lambda session: store.complete(session, old, case.effect),
    ):
        with Session(case.engine) as session, session.begin():
            with pytest.raises(store.LeaseLost):
                operation(session)
    assert effect_count(case) == 0
    with Session(case.engine) as session, session.begin():
        assert store.complete(session, current, case.effect)["created_count"] == 1
    assert effect_count(case) == 1
    with Session(case.engine) as session:
        attempts = list(
            session.scalars(
                select(JobAttempt)
                .where(JobAttempt.job_id == job_id)
                .order_by(JobAttempt.generation)
            )
        )
        assert [item.status for item in attempts] == ["lease_expired", "succeeded"]
        assert all(item.finished_at is not None for item in attempts)


@pytest.mark.parametrize("invalidate", ["lease", "owner", "epoch", "result"])
def test_effect_is_rolled_back_when_final_fence_or_result_fails(queue_case, invalidate):
    case = queue_case
    job_id = case.enqueue()
    lease = case.claim()

    def partial_effect(session, job):
        result = case.effect(session, job)
        if invalidate == "lease":
            job.lease_until = store.stamp(session) - timedelta(seconds=1)
        elif invalidate == "owner":
            session.get(User, case.owner_id).enabled = False
        elif invalidate == "epoch":
            session.get(ServerState, 1).sync_epoch = uuid4()
        else:
            result["private_error"] = "not_allowed_in_result"
        session.flush()
        return result

    with Session(case.engine) as session, session.begin():
        with pytest.raises(ValidationError if invalidate == "result" else store.LeaseLost):
            store.complete(session, lease, partial_effect)
        assert session.get(User, case.owner_id).enabled
        assert store.leased_job(session, lease).status == "running"
    assert effect_count(case) == 0
    assert job_snapshot(case, job_id)["status"] == "running"


def test_five_attempts_backoff_manual_retry_and_cancel_are_fenced(queue_case):
    case = queue_case
    job_id = case.enqueue()
    old_leases = []
    for number in range(1, 6):
        lease = case.claim()
        old_leases.append(lease)
        with Session(case.engine) as session, session.begin():
            before = store.stamp(session)
            store.fail(session, lease, "fixture_transient", transient=True)
            job = session.get(BackgroundJob, job_id)
            assert job.attempt == number
            if number < 5:
                assert job.status == "retry_wait"
                assert (
                    store.BACKOFF[number - 1]
                    <= (job.available_at - before).total_seconds()
                    < store.BACKOFF[number - 1] + 2
                )
                assert store.claim(session, case.worker_id(), {"export"}) is None
            else:
                assert job.status == "failed"
        if number < 5:
            force_available(case, job_id)
    with Session(case.engine) as session, session.begin():
        retried = store.retry(session, job_id)
        assert retried.attempt == 0 and retried.manual_retries == 1
    active = case.claim()
    assert active.generation == 6
    with Session(case.engine) as session, session.begin():
        store.cancel(session, job_id)
        store.cancel(session, job_id)
        with pytest.raises(store.JobConflict, match="job_not_retryable"):
            store.retry(session, job_id)
        for lease in [*old_leases, active]:
            with pytest.raises(store.LeaseLost):
                store.complete(session, lease, case.effect)
    assert job_snapshot(case, job_id)["status"] == "cancelled"
    assert effect_count(case) == 0


@pytest.mark.parametrize("changed", ["owner", "epoch"])
def test_claim_rejects_disabled_owner_or_previous_epoch(queue_case, changed):
    case = queue_case
    job_id = case.enqueue()
    with Session(case.engine) as session:
        if changed == "owner":
            session.get(User, case.owner_id).enabled = False
        else:
            session.get(ServerState, 1).sync_epoch = uuid4()
        session.flush()
        assert store.claim(session, case.worker_id(), {"export"}) is None
        job = session.get(BackgroundJob, job_id)
        assert job.status == "cancelled"
        assert job.error_code == ("owner_disabled" if changed == "owner" else "epoch_changed")
        session.rollback()


def test_disabled_owner_after_claim_cannot_complete(queue_case):
    case = queue_case
    case.enqueue()
    lease = case.claim()
    with Session(case.engine) as session, session.begin():
        session.get(User, case.owner_id).enabled = False
    with Session(case.engine) as session, session.begin():
        with pytest.raises(store.LeaseLost, match="job_owner_changed"):
            store.complete(session, lease, case.effect)
    assert effect_count(case) == 0


def test_completion_holds_owner_lock_through_effect_and_commit(queue_case):
    case = queue_case
    case.enqueue()
    lease = case.claim()

    def try_disabling_owner():
        with Session(case.engine) as session, session.begin():
            session.connection().exec_driver_sql("SET LOCAL lock_timeout='150ms'")
            with pytest.raises(OperationalError) as error:
                session.execute(update(User).where(User.id == case.owner_id).values(enabled=False))
            assert error.value.orig.sqlstate == "55P03"
            session.rollback()

    def effect_with_competing_revocation(session, job):
        with ThreadPoolExecutor(max_workers=1) as executor:
            executor.submit(try_disabling_owner).result(timeout=5)
        return case.effect(session, job)

    with Session(case.engine) as session, session.begin():
        store.complete(session, lease, effect_with_competing_revocation)
        # The owner lock also remains after complete's inner savepoint returns.
        with ThreadPoolExecutor(max_workers=1) as executor:
            executor.submit(try_disabling_owner).result(timeout=5)
    assert effect_count(case) == 1


def test_renew_heartbeat_and_public_metadata_exclude_payload(queue_case):
    case = queue_case
    sentinel = "fixture_private_payload_not_public"
    job_id = case.enqueue(payload={"private": sentinel, "path": "C:/fixture/private"})
    lease = case.claim()
    with Session(case.engine) as session, session.begin():
        job = session.get(BackgroundJob, job_id)
        before = job.lease_until
        store.renew(session, lease)
        assert job.lease_until >= before
        first = store.heartbeat(
            session,
            lease.worker_id,
            version="0.1.0",
            supported_kinds={"export"},
            active_job_id=job_id,
        )
        started = first.started_at
        store.heartbeat(session, lease.worker_id, version="0.1.1", supported_kinds={"export"})
        assert first.started_at == started and first.active_job_id is None
        assert first.heartbeat_at >= started
        public = store.metadata(job)
        assert set(public) == {
            "job_id",
            "kind",
            "status",
            "owner_user_id",
            "attempt",
            "manual_retries",
            "generation",
            "available_at",
            "created_at",
            "updated_at",
            "lease_until",
            "error_code",
            "result",
        }
        assert sentinel not in str(public) and "C:/fixture" not in str(public)
        assert session.get(WorkerState, lease.worker_id).version == "0.1.1"
