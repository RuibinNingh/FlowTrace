"""Known-abort retry over real PostgreSQL; no file or financial effects."""

from threading import Event, Thread, current_thread
from time import monotonic, sleep
from uuid import UUID, uuid4

import pytest
from sqlalchemy import event, func, select, text
from sqlalchemy.orm import Session
from sync.helpers import actor, epoch

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import User
from flowtrace_server.sync.common import require_current_client
from flowtrace_server.sync.group_models import GroupPullSession
from flowtrace_server.sync.group_schemas import GroupPullCreate
from flowtrace_server.sync.group_service import create_group_pull
from flowtrace_server.sync.models import LedgerEntry, SyncEntity, SyncReceipt

pytestmark = pytest.mark.postgres


def _create_racing_current_client(engine, *, disable_user=False):
    owner = actor(engine)
    body = GroupPullCreate(
        protocol_version=1,
        request_id=str(uuid4()),
        client_id=str(owner.principal.client_id),
        sync_epoch=epoch(engine),
        cursors={},
    )
    with Session(engine) as session:
        require_current_client(session, owner.principal, body.sync_epoch, body.client_id)
        session.commit()
    name = "group-create-race-" + uuid4().hex
    selected = Event()
    reader_pid, sqlstates, results, errors = [], [], [], []

    def first_authority_query(connection, cursor, statement, parameters, context, executemany):
        if (
            current_thread().name == name
            and not reader_pid
            and statement.startswith("SELECT users.")
            and "FOR UPDATE" in statement
        ):
            # The PID is driver metadata, not another SQL snapshot.
            reader_pid.append(connection.connection.driver_connection.info.backend_pid)
            selected.set()

    def database_error(context):
        if current_thread().name == name:
            sqlstates.append(getattr(context.original_exception, "sqlstate", None))

    def read():
        try:
            with Session(engine) as session:
                results.append(create_group_pull(session, owner.principal, body))
        except ApiError as error:
            errors.append((error.code, error.status))
        except Exception as error:
            # A pytest thread cannot print private driver parameters.
            errors.append((type(error).__name__, None))

    observed_wait = False
    worker = Thread(target=read, name=name)
    event.listen(engine, "before_cursor_execute", first_authority_query)
    event.listen(engine, "handle_error", database_error)
    try:
        with Session(engine) as writer:
            # Real production authentication/lease update, holding User first.
            require_current_client(writer, owner.principal, body.sync_epoch, body.client_id)
            if disable_user:
                writer.get(User, owner.principal.user_id).enabled = False
            writer.flush()
            writer_pid = writer.connection().connection.driver_connection.info.backend_pid
            try:
                worker.start()
                assert selected.wait(3), "reader never attempted the current authority lock"
                deadline = monotonic() + 3
                with engine.connect() as observer:
                    while monotonic() < deadline:
                        waiting = observer.execute(
                            text(
                                "SELECT wait_event_type,pg_blocking_pids(pid) "
                                "FROM pg_stat_activity WHERE pid=:pid"
                            ),
                            {"pid": reader_pid[0]},
                        ).one()
                        if waiting[0] == "Lock" and writer_pid in waiting[1]:
                            observed_wait = True
                            break
                        sleep(0.01)
                assert observed_wait, "RR first SELECT did not really block on the writer"
                # Reader already took its first RR snapshot, while the same
                # client's new last_seen and optional revocation are uncommitted.
                writer.commit()
            finally:
                writer.rollback()
                if worker.ident is not None:
                    worker.join(10)
        assert not worker.is_alive(), "controlled group reader did not finish"
    finally:
        event.remove(engine, "before_cursor_execute", first_authority_query)
        event.remove(engine, "handle_error", database_error)
    assert observed_wait and sqlstates == ["40001"]
    return owner, body, results, errors


def test_repeatable_create_retries_actual_blocked_snapshot_client_update(postgres_engine):
    owner, body, values, errors = _create_racing_current_client(postgres_engine)
    assert errors == []
    assert len(values) == 1 and values[0]["status"] == "planning"
    with Session(postgres_engine) as session:
        rows = list(
            session.scalars(
                select(GroupPullSession).where(
                    GroupPullSession.user_id == owner.principal.user_id,
                    GroupPullSession.request_id == UUID(body.request_id),
                )
            )
        )
        assert len(rows) == 1 and str(rows[0].id) == values[0]["pull_id"]
        assert rows[0].page_count == rows[0].unit_count == 0
        assert (
            session.scalar(
                select(func.count())
                .select_from(SyncEntity)
                .where(SyncEntity.scope_id == owner.book_id)
            )
            == 1
        )
        assert session.scalar(select(func.count()).select_from(LedgerEntry)) == 0
        assert session.scalar(select(func.count()).select_from(SyncReceipt)) == 0
    with Session(postgres_engine) as session:
        assert create_group_pull(session, owner.principal, body) == values[0]


def test_known_abort_retry_rechecks_current_disabled_owner(postgres_engine):
    owner, _, values, errors = _create_racing_current_client(postgres_engine, disable_user=True)
    assert values == []
    assert errors == [("session_invalid", 401)]
    with Session(postgres_engine) as session:
        assert (
            session.scalar(
                select(func.count())
                .select_from(GroupPullSession)
                .where(GroupPullSession.user_id == owner.principal.user_id)
            )
            == 0
        )
