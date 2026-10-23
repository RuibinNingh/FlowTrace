"""A database maintenance fence shared by API/worker transactions and backup CLI."""

from contextlib import AbstractContextManager

import psycopg
from psycopg import sql
from sqlalchemy import event
from sqlalchemy.engine import Engine, make_url

from flowtrace_server.api.errors import ServiceUnavailable
from flowtrace_server.config import Settings

# A fixed application namespace, scoped by PostgreSQL to the current database.
MAINTENANCE_KEY = 0x465452414345


def install_transaction_fence(engine: Engine) -> None:
    """Every transaction reacquires the fence, including post-auth restarts."""

    @event.listens_for(engine, "begin")
    def begin(connection):
        available = connection.exec_driver_sql(
            "SELECT pg_try_advisory_xact_lock_shared(%s)", (MAINTENANCE_KEY,)
        ).scalar_one()
        if not available:
            raise ServiceUnavailable("maintenance_in_progress")


class MaintenanceLease(AbstractContextManager):
    """A trusted operator/worker maintenance window, never a direct HTTP command.

    The raw connection deliberately bypasses the shared engine hook. The lease
    owns its transaction: callers must not commit/rollback it. SHARE table locks
    also drain legacy writers that do not yet know the application fence.
    pg_dump ACCESS SHARE reads remain possible while domain writes cannot commit.
    """

    def __init__(self, settings: Settings, timeout_seconds: int = 30):
        if not 1 <= timeout_seconds <= 300 or settings.database_url is None:
            raise ValueError("maintenance_configuration_invalid")
        self._settings = settings
        self._timeout = timeout_seconds
        self.connection = None

    def __enter__(self):
        try:
            parsed = make_url(self._settings.database_url.get_secret_value())
            options = dict(parsed.query)
            allowed_options = {
                "sslmode",
                "sslrootcert",
                "sslcert",
                "sslkey",
                "sslcrl",
                "sslcrldir",
                "sslpassword",
                "channel_binding",
                "gssencmode",
                "target_session_attrs",
                "hostaddr",
                "sslnegotiation",
            }
            if any(
                key not in allowed_options or not isinstance(value, str)
                for key, value in options.items()
            ):
                raise ValueError("maintenance_connection_option_invalid")
            self.connection = psycopg.connect(
                host=parsed.host,
                port=parsed.port,
                dbname=parsed.database,
                user=parsed.username,
                password=parsed.password,
                connect_timeout=self._settings.database_connect_timeout,
                autocommit=True,
                **options,
            )
            self.connection.execute(
                "SELECT set_config('lock_timeout', %s, false)", (f"{self._timeout}s",)
            )
            self.connection.execute("SELECT pg_advisory_lock(%s)", (MAINTENANCE_KEY,))
            # The table lock may wait for a legacy writer to finish. Use fresh
            # READ COMMITTED statements after that drain, not a snapshot taken
            # before its commit. With all table SHARE locks held, rows are stable.
            self.connection.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
            tables = self.connection.execute(
                "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename"
            ).fetchall()
            if tables:
                self.connection.execute(
                    sql.SQL("LOCK TABLE {} IN SHARE MODE").format(
                        sql.SQL(", ").join(sql.Identifier("public", row[0]) for row in tables)
                    )
                )
            return self
        except Exception:
            try:
                self.__exit__(None, None, None)
            except Exception:
                pass
            # Keep DSNs, host/user names and native exception bodies private.
            raise RuntimeError("maintenance_window_unavailable") from None

    def __exit__(self, exc_type, exc, traceback):
        connection, self.connection = self.connection, None
        if connection is not None:
            try:
                connection.execute("ROLLBACK")
            finally:
                # Closing always releases session locks, also on failed entry.
                connection.close()
        return False
