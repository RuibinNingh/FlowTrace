"""Per-application private collection policy, independent of business Sessions.

The file collector is optional. It must never become a transaction receipt or
borrow a caller's Session. The trusted reader returns a current committed bool;
exceptions, malformed values and absent configuration all disable collection.
"""

import logging
import threading
from contextlib import contextmanager
from contextvars import ContextVar
from pathlib import Path
from typing import Callable

from .store import DiagnosticStore


class DiagnosticPolicy:
    def __init__(
        self,
        directory: Path,
        *,
        os_enabled: bool,
        runtime_reader: Callable[[], bool] | None = None,
        store_factory=DiagnosticStore,
        minimum_level: str = "INFO",
    ):
        self.directory = directory
        self._os_enabled = os_enabled is True
        self._reader = runtime_reader
        self._factory = store_factory
        self._store = None
        self._closed = False
        self._minimum_level = logging.getLevelNamesMapping()[minimum_level]
        self._initialization_lock = threading.Lock()

    def enabled(self) -> bool:
        if self._closed or not self._os_enabled or self._reader is None:
            return False
        try:
            return self._reader() is True and not self._closed
        except Exception:
            # Never send a DSN/native exception through logging, including the
            # same collector whose policy lookup just failed.
            return False

    def append(self, fields: dict, *, level: int = logging.INFO) -> bool:
        if self._closed or not self._os_enabled or level < self._minimum_level:
            return False

        try:
            if self._store is None:
                if not self.enabled():
                    return False
                with self._initialization_lock:
                    if self._store is None:
                        self._store = self._factory(self.directory)
            # The callback is checked after the cross-process file lock, so a
            # queued append cannot rely on a stale pre-lock true decision.
            return self._store.append(fields, guard=self.enabled)
        except Exception:
            DiagnosticStore.notice_failure()
            return False

    def close(self):
        """Release only this policy's reader resources, never a global handler."""
        self._closed = True
        close = getattr(self._reader, "close", None)
        if close is not None:
            try:
                close()
            except Exception:
                pass


_policy_context: ContextVar[DiagnosticPolicy | None] = ContextVar(
    "flowtrace_diagnostic_policy", default=None
)


@contextmanager
def bind_diagnostics(policy: DiagnosticPolicy | None):
    """Explicit HTTP/worker/CLI scope; AnyIO copies this to its worker threads.

    A new ordinary thread has no inherited policy and cannot accidentally write
    to another app's directory. Trusted callers may explicitly copy_context.
    """
    if policy is not None and not isinstance(policy, DiagnosticPolicy):
        raise TypeError("diagnostic_policy_required")
    token = _policy_context.set(policy)
    try:
        yield
    finally:
        _policy_context.reset(token)


def current_policy() -> DiagnosticPolicy | None:
    return _policy_context.get()


def collect(fields: dict, *, level: int = logging.INFO) -> bool:
    policy = current_policy()
    return policy.append(fields, level=level) if policy is not None else False


class RuntimeDiagnosticReader:
    """Fresh committed MVCC read, with no business Session or advisory fence.

    NullPool never borrows the API's possibly exhausted transaction pool. The
    fixed read uses no row locks, including while this caller holds the head
    row's write lock. Connect/DNS OS behavior is not an absolute wall deadline.
    """

    def __init__(self, settings):
        from sqlalchemy import create_engine
        from sqlalchemy.pool import NullPool

        self._engine = create_engine(
            settings.database_url.get_secret_value(),
            poolclass=NullPool,
            isolation_level="AUTOCOMMIT",
            hide_parameters=True,
            connect_args={
                "connect_timeout": 1,
                "options": "-c default_transaction_read_only=on "
                "-c statement_timeout=100ms -c lock_timeout=50ms",
            },
        )
        self._probe_slot = threading.BoundedSemaphore(1)

    def __call__(self) -> bool:
        from sqlalchemy import text

        from flowtrace_server.configuration.schemas import (
            INITIAL_PUBLIC_VALUES,
            PublicConfiguration,
        )

        if not self._probe_slot.acquire(blocking=False):
            return False
        try:
            with self._engine.connect() as connection:
                values = connection.execute(
                    text("SELECT public_values FROM service_configuration WHERE id=1")
                ).scalar_one_or_none()
            if not isinstance(values, dict) or set(values) != set(INITIAL_PUBLIC_VALUES):
                return False
            return PublicConfiguration.model_validate(values).diagnostics_enabled is True
        except Exception:
            return False
        finally:
            self._probe_slot.release()

    def close(self):
        self._engine.dispose()


def build_diagnostic_policy(settings) -> DiagnosticPolicy:
    reader = None
    if settings.diagnostics_enabled and settings.database_url is not None:
        reader = RuntimeDiagnosticReader(settings)
    return DiagnosticPolicy(
        settings.data_directory / "diagnostics",
        os_enabled=settings.diagnostics_enabled,
        runtime_reader=reader,
        minimum_level=settings.log_level,
    )
