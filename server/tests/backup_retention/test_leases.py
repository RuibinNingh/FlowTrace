import multiprocessing
import threading
from pathlib import Path
from time import monotonic
from types import SimpleNamespace
from uuid import uuid4

import pytest

from flowtrace_server.backups.leases import (
    BackupLeaseError,
    backup_exclusive_lease,
    backup_read_lease,
)


def hold_in_process(directory, identity, exclusive, ready, release):
    settings = SimpleNamespace(data_directory=Path(directory))
    manager = (
        backup_exclusive_lease(settings, (identity,))
        if exclusive
        else backup_read_lease(settings, identity)
    )
    with manager:
        ready.put("acquired")
        if not release.wait(5):
            raise RuntimeError("lease_test_parent_did_not_release")


def child_lease(tmp_path, identity, *, exclusive):
    context = multiprocessing.get_context("spawn")
    ready, release = context.Queue(), context.Event()
    child = context.Process(
        target=hold_in_process, args=(tmp_path, identity, exclusive, ready, release)
    )
    child.start()
    assert ready.get(timeout=3) == "acquired"
    return child, release


def finish(child, release):
    release.set()
    child.join(5)
    assert child.exitcode == 0


def test_shared_readers_cross_process_allow_read_and_exclude_cleaner(tmp_path):
    settings, identity = SimpleNamespace(data_directory=tmp_path / str(uuid4())), uuid4()
    child, release = child_lease(settings.data_directory, identity, exclusive=False)
    try:
        with backup_read_lease(settings, identity, timeout_seconds=0):
            pass
        with pytest.raises(BackupLeaseError) as caught:
            with backup_exclusive_lease(settings, (identity,), timeout_seconds=0):
                pytest.fail("exclusive overlapped shared reader")
        assert caught.value.code == "backup_busy" and caught.value.transient
    finally:
        finish(child, release)
    with backup_exclusive_lease(settings, (identity,), timeout_seconds=0):
        pass


def test_exclusive_owner_cross_process_excludes_reader_without_touching_package(tmp_path):
    settings, identity = SimpleNamespace(data_directory=tmp_path / str(uuid4())), uuid4()
    package = settings.data_directory / "backups" / str(identity) / "sentinel.bin"
    package.parent.mkdir(parents=True)
    package.write_bytes(b"untouched-backup-package")
    child, release = child_lease(settings.data_directory, identity, exclusive=True)
    try:
        with pytest.raises(BackupLeaseError):
            with backup_read_lease(settings, identity, timeout_seconds=0):
                pytest.fail("read overlapped exclusive owner")
    finally:
        finish(child, release)
    assert package.read_bytes() == b"untouched-backup-package"


def test_failed_batch_releases_earlier_lock_and_canonicalizes_uuid_order(tmp_path):
    settings = SimpleNamespace(data_directory=tmp_path / str(uuid4()))
    first, second = sorted((uuid4(), uuid4()), key=str)
    child, release = child_lease(settings.data_directory, second, exclusive=True)
    try:
        with pytest.raises(BackupLeaseError):
            with backup_exclusive_lease(settings, (second, first), timeout_seconds=0):
                pytest.fail("batch bypassed second owner")
        with backup_exclusive_lease(settings, (first,), timeout_seconds=0):
            pass
    finally:
        finish(child, release)
    with backup_exclusive_lease(settings, (second, first), timeout_seconds=0) as ordered:
        assert ordered == (first, second)


def test_trusted_budget_exception_after_acquire_releases_lease(tmp_path):
    settings, identity = SimpleNamespace(data_directory=tmp_path / str(uuid4())), uuid4()
    calls = []

    class Stopped(RuntimeError):
        pass

    def budget():
        calls.append(True)
        if len(calls) == 2:
            raise Stopped

    with pytest.raises(Stopped):
        with backup_read_lease(settings, identity, check_budget=budget):
            pytest.fail("expired budget continued")
    with backup_exclusive_lease(settings, (identity,), timeout_seconds=0):
        pass


def test_lock_file_hardlink_and_invalid_selection_are_rejected(tmp_path):
    settings, identity = SimpleNamespace(data_directory=tmp_path / str(uuid4())), uuid4()
    root = settings.data_directory / "backup-controls" / str(identity)
    root.mkdir(parents=True)
    outside = tmp_path / str(uuid4())
    outside.write_bytes(b"private-unrelated-data")
    (root / "package.lock").hardlink_to(outside)
    with pytest.raises(BackupLeaseError) as caught:
        with backup_read_lease(settings, identity):
            pytest.fail("linked lock accepted")
    assert caught.value.code == "backup_lease_unavailable"
    assert outside.read_bytes() == b"private-unrelated-data"
    for values in ((), (identity, identity), (str(identity),)):
        with pytest.raises(BackupLeaseError):
            with backup_exclusive_lease(settings, values):
                pytest.fail("invalid identities accepted")


@pytest.mark.parametrize("exclusive", [False, True])
def test_same_process_distinct_thread_handles_obey_shared_and_exclusive_modes(tmp_path, exclusive):
    settings, identity = SimpleNamespace(data_directory=tmp_path / str(uuid4())), uuid4()
    ready, release = threading.Event(), threading.Event()
    errors = []

    def owner():
        try:
            manager = (
                backup_exclusive_lease(settings, (identity,))
                if exclusive
                else backup_read_lease(settings, identity)
            )
            with manager:
                ready.set()
                assert release.wait(2)
        except Exception as error:
            errors.append(type(error).__name__)

    thread = threading.Thread(target=owner)
    thread.start()
    try:
        assert ready.wait(1)
        if exclusive:
            stamp = monotonic()
            with pytest.raises(BackupLeaseError) as caught:
                with backup_read_lease(settings, identity, timeout_seconds=0.05):
                    pytest.fail("thread read overlapped exclusive owner")
            assert caught.value.code == "backup_busy"
            assert 0.04 <= monotonic() - stamp < 0.8
        else:
            with backup_read_lease(settings, identity, timeout_seconds=0):
                pass
            with pytest.raises(BackupLeaseError):
                with backup_exclusive_lease(settings, (identity,), timeout_seconds=0):
                    pytest.fail("thread exclusive overlapped shared owner")
    finally:
        release.set()
        thread.join(2)
    assert not thread.is_alive() and errors == []
    with backup_exclusive_lease(settings, (identity,), timeout_seconds=0):
        pass
