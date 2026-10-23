import asyncio
import json
import threading
from contextlib import contextmanager
from contextvars import copy_context
from types import SimpleNamespace
from uuid import uuid4

import anyio
import pytest
from pydantic import SecretStr

from flowtrace_server.diagnostics import LOGGER, StoreHandler, configure_logging, event
from flowtrace_server.diagnostics.policy import (
    DiagnosticPolicy,
    RuntimeDiagnosticReader,
    bind_diagnostics,
    collect,
    current_policy,
)
from flowtrace_server.diagnostics.store import DiagnosticStore


def records(directory):
    return [
        json.loads(line)
        for path in directory.glob("flowtrace-*.jsonl")
        for line in path.read_bytes().splitlines()
    ]


def test_os_hard_off_never_calls_reader_constructs_store_or_creates_directory(tmp_path):
    directory = tmp_path / str(uuid4())

    def forbidden(*args):
        pytest.fail("OS disabled collector called a dependency")

    policy = DiagnosticPolicy(
        directory, os_enabled=False, runtime_reader=forbidden, store_factory=forbidden
    )
    with bind_diagnostics(policy):
        assert not policy.enabled() and not collect({"event": "safe"})
    assert not directory.exists()


@pytest.mark.parametrize("value", [None, False, 1, "true", {}, []])
def test_missing_or_non_boolean_runtime_setting_is_off(tmp_path, value):
    directory = tmp_path / str(uuid4())
    policy = DiagnosticPolicy(directory, os_enabled=True, runtime_reader=lambda: value)
    with bind_diagnostics(policy):
        assert not collect({"event": "safe"})
    assert not directory.exists()


def test_runtime_disable_stops_next_record_and_preserves_existing_files(tmp_path):
    directory = tmp_path / str(uuid4())
    state = {"enabled": True}
    policy = DiagnosticPolicy(directory, os_enabled=True, runtime_reader=lambda: state["enabled"])
    with bind_diagnostics(policy):
        assert collect({"event": "safe", "operation_id": str(uuid4())})
        before = {p.name: p.read_bytes() for p in directory.iterdir() if p.suffix == ".jsonl"}
        state["enabled"] = False
        assert not collect({"event": "safe", "operation_id": str(uuid4())})
    assert before == {p.name: p.read_bytes() for p in directory.iterdir() if p.suffix == ".jsonl"}


def test_reader_failure_has_no_native_message_and_never_escapes_business_result(tmp_path, capsys):
    def failed():
        raise RuntimeError("SECRET_DSN_OR_NATIVE_QUERY")

    policy = DiagnosticPolicy(tmp_path / str(uuid4()), os_enabled=True, runtime_reader=failed)
    with bind_diagnostics(policy):
        result = {"business_committed": True}
        assert not collect({"event": "safe"})
    assert result == {"business_committed": True}
    assert "SECRET_DSN" not in capsys.readouterr().err


def test_file_lock_queue_rechecks_policy_after_acquisition(tmp_path):
    directory = tmp_path / str(uuid4())
    state = {"enabled": True}
    store = DiagnosticStore(directory)
    policy = DiagnosticPolicy(
        directory,
        os_enabled=True,
        runtime_reader=lambda: state["enabled"],
        store_factory=lambda _: store,
    )
    assert policy.append({"event": "safe"})
    started = threading.Event()
    output = []

    def queued():
        started.set()
        output.append(policy.append({"event": "safe"}))

    with store.locked():
        thread = threading.Thread(target=queued)
        thread.start()
        assert started.wait(1)
        state["enabled"] = False
    thread.join(2)
    assert not thread.is_alive() and output == [False]
    assert len(records(directory)) == 1


def test_nested_scope_and_exception_restore_the_previous_app(tmp_path):
    first = DiagnosticPolicy(tmp_path / str(uuid4()), os_enabled=True, runtime_reader=lambda: True)
    second = DiagnosticPolicy(tmp_path / str(uuid4()), os_enabled=True, runtime_reader=lambda: True)
    assert current_policy() is None and not collect({"event": "safe"})
    with bind_diagnostics(first):
        assert current_policy() is first
        with pytest.raises(RuntimeError), bind_diagnostics(second):
            assert current_policy() is second
            raise RuntimeError("scope fixture")
        assert current_policy() is first
        with bind_diagnostics(None):
            assert not collect({"event": "safe"})
        assert current_policy() is first
    assert current_policy() is None


def test_plain_thread_is_off_and_explicit_context_copy_keeps_only_its_app(tmp_path):
    policy = DiagnosticPolicy(tmp_path / str(uuid4()), os_enabled=True, runtime_reader=lambda: True)
    output = []
    with bind_diagnostics(policy):
        plain = threading.Thread(target=lambda: output.append(collect({"event": "safe"})))
        plain.start()
        plain.join(2)
        copied = copy_context()
        explicit = threading.Thread(
            target=lambda: copied.run(lambda: output.append(collect({"event": "safe"})))
        )
        explicit.start()
        explicit.join(2)
    assert output == [False, True]
    assert len(records(policy.directory)) == 1


def test_anyio_threadpool_and_overlapping_app_tasks_keep_request_policy_isolated(tmp_path):
    first_id, second_id = str(uuid4()), str(uuid4())
    first = DiagnosticPolicy(tmp_path / str(uuid4()), os_enabled=True, runtime_reader=lambda: True)
    second = DiagnosticPolicy(tmp_path / str(uuid4()), os_enabled=True, runtime_reader=lambda: True)

    async def request(policy, operation_id):
        with bind_diagnostics(policy):
            await asyncio.sleep(0)
            assert await anyio.to_thread.run_sync(
                lambda: collect({"event": "safe", "operation_id": operation_id})
            )
            await asyncio.sleep(0)
            assert current_policy() is policy

    async def run():
        await asyncio.gather(
            *(request(first, first_id) if i % 2 else request(second, second_id) for i in range(20))
        )

    anyio.run(run)
    assert len(records(first.directory)) == len(records(second.directory)) == 10
    assert {r["operation_id"] for r in records(first.directory)} == {first_id}
    assert {r["operation_id"] for r in records(second.directory)} == {second_id}
    assert current_policy() is None


def test_process_handler_is_singleton_and_second_app_threshold_does_not_replace_first_directory(
    tmp_path,
):
    first = configure_logging("INFO", tmp_path / str(uuid4()), runtime_reader=lambda: True)
    second = configure_logging("ERROR", tmp_path / str(uuid4()), runtime_reader=lambda: True)
    assert len([handler for handler in LOGGER.handlers if isinstance(handler, StoreHandler)]) == 1
    with bind_diagnostics(first):
        event("safe")
    with bind_diagnostics(second):
        event("safe")
    assert len(records(first.directory)) == 1 and not second.directory.exists()
    first.close()
    with bind_diagnostics(first):
        event("safe")
    assert len(records(first.directory)) == 1
    with bind_diagnostics(second):
        assert second.append({"event": "safe"}, level=40)
    assert len(records(second.directory)) == 1
    second.close()
    configure_logging("INFO")


def test_unbound_legacy_directory_is_not_an_implicit_global_destination(tmp_path):
    policy = configure_logging("INFO", tmp_path / str(uuid4()), runtime_reader=lambda: True)
    event("safe")
    assert not policy.directory.exists()
    with bind_diagnostics(policy):
        event("safe")
    assert len(records(policy.directory)) == 1
    policy.close()


def test_slow_probe_in_one_app_does_not_hold_a_global_file_handler_lock(tmp_path):
    entered, release, other_finished = threading.Event(), threading.Event(), threading.Event()

    def delayed():
        entered.set()
        assert release.wait(2)
        return False

    first = DiagnosticPolicy(tmp_path / str(uuid4()), os_enabled=True, runtime_reader=delayed)
    second = DiagnosticPolicy(tmp_path / str(uuid4()), os_enabled=True, runtime_reader=lambda: True)
    configure_logging("INFO")

    def emit(policy, finished=None):
        with bind_diagnostics(policy):
            event("safe")
        if finished is not None:
            finished.set()

    slow = threading.Thread(target=emit, args=(first,))
    other = threading.Thread(target=emit, args=(second, other_finished))
    slow.start()
    try:
        assert entered.wait(1)
        other.start()
        assert other_finished.wait(1)
    finally:
        release.set()
        slow.join(2)
        other.join(2)
    assert not first.directory.exists() and len(records(second.directory)) == 1


def test_runtime_reader_allows_one_probe_and_drops_concurrent_probe_without_queue(monkeypatch):
    from flowtrace_server.configuration.schemas import INITIAL_PUBLIC_VALUES

    reader = RuntimeDiagnosticReader(
        SimpleNamespace(
            database_url=SecretStr(
                "postgresql+psycopg://fixture:fixture@127.0.0.1/flowtrace_test_policy_fixture"
            )
        )
    )
    entered, release = threading.Event(), threading.Event()
    output = []

    class Engine:
        @contextmanager
        def connect(self):
            entered.set()
            assert release.wait(2)
            yield self

        def execute(self, statement):
            assert str(statement) == "SELECT public_values FROM service_configuration WHERE id=1"
            return self

        def scalar_one_or_none(self):
            return dict(INITIAL_PUBLIC_VALUES)

        def dispose(self):
            return

    reader._engine.dispose()
    monkeypatch.setattr(reader, "_engine", Engine())
    first = threading.Thread(target=lambda: output.append(reader()))
    first.start()
    try:
        assert entered.wait(1)
        assert reader() is False
    finally:
        release.set()
        first.join(2)
    assert output == [True]
    reader.close()
