"""Real database fences protect a consistent backup from new and legacy writes."""

import os
from concurrent.futures import ThreadPoolExecutor

import psycopg
import pytest
from sqlalchemy import text
from sqlalchemy.engine import make_url

from flowtrace_server.api.errors import ServiceUnavailable
from flowtrace_server.config import Settings
from flowtrace_server.persistence.maintenance import MaintenanceLease

pytestmark = pytest.mark.postgres


def settings():
    return Settings(
        _env_file=None, environment="test", database_url=os.environ["FLOWTRACE_TEST_DATABASE_URL"]
    )


def test_backup_fence_rejects_new_engine_transactions_then_recovers(postgres_engine):
    with MaintenanceLease(settings()) as lease:
        assert lease.connection.execute("SELECT count(*) FROM users").fetchone()[0] >= 0
        with pytest.raises(ServiceUnavailable):
            with postgres_engine.connect() as connection:
                connection.execute(text("SELECT 1"))
    with postgres_engine.connect() as connection:
        assert connection.execute(text("SELECT 1")).scalar_one() == 1


def test_maintenance_waits_for_inflight_transaction_and_legacy_dml_is_blocked(postgres_engine):
    entered = __import__("threading").Event()
    release = __import__("threading").Event()

    def hold():
        with MaintenanceLease(settings(), timeout_seconds=10):
            entered.set()
            assert release.wait(timeout=10)

    with ThreadPoolExecutor(max_workers=1) as pool:
        with postgres_engine.connect() as connection:
            connection.execute(text("SELECT 1"))
            future = pool.submit(hold)
            assert not entered.wait(timeout=0.15)
            connection.rollback()
        assert entered.wait(timeout=5)
        url = make_url(settings().database_url.get_secret_value())
        try:
            # This client bypasses build_engine and its advisory fence, as an
            # old binary would. SHARE table locks still block its DML.
            with psycopg.connect(
                host=url.host,
                port=url.port,
                dbname=url.database,
                user=url.username,
                password=url.password,
            ) as legacy:
                legacy.execute("SET LOCAL lock_timeout='100ms'")
                with pytest.raises(psycopg.errors.LockNotAvailable):
                    legacy.execute("UPDATE admin_control SET id=id WHERE id=1")
        finally:
            release.set()
        future.result(timeout=5)


def test_failed_window_does_not_leak_a_lease(postgres_engine):
    with pytest.raises(RuntimeError, match="synthetic_failure"):
        with MaintenanceLease(settings()):
            raise RuntimeError("synthetic_failure")
    with postgres_engine.connect() as connection:
        assert connection.execute(text("SELECT 1")).scalar_one() == 1
