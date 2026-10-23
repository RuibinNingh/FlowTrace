"""Committed UUID fixtures for cross-connection queue tests; no database reset."""

from dataclasses import dataclass, field
from uuid import UUID, uuid4

import pytest
from sqlalchemy import delete, or_, select, update
from sqlalchemy.orm import Session

from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.auth.models import AdminRole, RefreshToken, User, UserSession
from flowtrace_server.backups.retention_models import BackupHold, BackupPin, BackupRetentionIntent
from flowtrace_server.jobs import store
from flowtrace_server.jobs.models import BackgroundJob, JobAttempt, WorkerState


@dataclass
class QueueCase:
    engine: object
    owner_id: UUID
    prefix: str
    worker_ids: list[UUID] = field(default_factory=list)

    def worker_id(self):
        value = uuid4()
        self.worker_ids.append(value)
        return value

    def enqueue(self, *, kind="export", key="one", payload=None, **kwargs):
        with Session(self.engine) as session, session.begin():
            record = store.enqueue(
                session,
                kind=kind,
                occurrence_key=f"{self.prefix}:{key}",
                owner_user_id=self.owner_id,
                payload=payload or {"fixture": True},
                **kwargs,
            )
            return record.id

    def claim(self, kinds=("export",)):
        with Session(self.engine) as session, session.begin():
            return store.claim(session, self.worker_id(), kinds)

    def effect(self, session, job):
        session.add(
            AdminAudit(
                id=uuid4(),
                actor_id=self.owner_id,
                action="fixture.queue_effect",
                target_id=job.id,
                created_at=store.stamp(session),
                summary={"count": 1},
            )
        )
        session.flush()
        return {"code": "fixture_applied", "created_count": 1}


@pytest.fixture
def queue_case(postgres_engine):
    owner_id = uuid4()
    case = QueueCase(postgres_engine, owner_id, f"queue:{uuid4().hex}")
    with Session(postgres_engine) as session, session.begin():
        session.add(
            User(
                id=owner_id,
                username=f"queue_{owner_id.hex}",
                password_hash="not_an_authentication_fixture",
                enabled=True,
                created_at=store.stamp(session),
            )
        )
    try:
        yield case
    finally:
        # Only records owned by this test's newly created user are removed.
        with Session(postgres_engine) as session, session.begin():
            job_ids = select(BackgroundJob.id).where(BackgroundJob.owner_user_id == owner_id)
            session.execute(delete(WorkerState).where(WorkerState.id.in_(case.worker_ids)))
            protected = (
                session.scalar(select(BackupHold.id).where(or_(
                    BackupHold.job_id.in_(job_ids), BackupHold.owner_user_id == owner_id,
                )).limit(1))
                or session.scalar(select(BackupPin.id).where(or_(
                    BackupPin.created_by == owner_id, BackupPin.released_by == owner_id,
                )).limit(1))
                or session.scalar(select(BackupRetentionIntent.id).where(
                    BackupRetentionIntent.actor_id == owner_id
                ).limit(1))
            )
            if protected:
                # Immutable backup evidence keeps its real FK-bound actor/job.
                # Only this newly created case's live work/authority is ended.
                active = list(session.scalars(select(BackgroundJob.id).where(
                    BackgroundJob.owner_user_id == owner_id,
                    BackgroundJob.status.in_(("pending", "running", "retry_wait")),
                )))
                for identifier in active:
                    store.cancel(session, identifier)
                session.execute(delete(AdminRole).where(AdminRole.user_id == owner_id))
                session.execute(update(UserSession).where(
                    UserSession.user_id == owner_id, UserSession.revoked_at.is_(None),
                ).values(revoked_at=store.stamp(session)))
                return
            session.execute(delete(JobAttempt).where(JobAttempt.job_id.in_(job_ids)))
            session.execute(delete(BackgroundJob).where(BackgroundJob.owner_user_id == owner_id))
            session.execute(delete(AdminAudit).where(AdminAudit.actor_id == owner_id))
            session.execute(delete(AdminRole).where(AdminRole.user_id == owner_id))
            session_ids = select(UserSession.id).where(UserSession.user_id == owner_id)
            session.execute(delete(RefreshToken).where(RefreshToken.session_id.in_(session_ids)))
            session.execute(delete(UserSession).where(UserSession.user_id == owner_id))
            session.execute(delete(User).where(User.id == owner_id))
