"""Shared/exclusive cross-process leases for fixed backup UUIDs.

Only private control lock files are created. This module never opens, moves or
deletes a backup package, and never accepts a database Session or public path.
"""

import math
import os
from contextlib import ExitStack, contextmanager
from functools import lru_cache
from time import monotonic, sleep
from uuid import UUID

import portalocker

from flowtrace_server.persistence.private_files import (
    UnsafeFilePath,
    private_directory,
    private_open,
    regular_file,
)


class BackupLeaseError(RuntimeError):
    def __init__(self, code="backup_lease_unavailable", *, transient=False):
        super().__init__(code)
        self.code, self.transient = code, transient


@lru_cache(maxsize=1)
def _windows_api():
    import ctypes
    from ctypes import wintypes

    class Overlapped(ctypes.Structure):
        _fields_ = [
            ("Internal", ctypes.c_size_t),
            ("InternalHigh", ctypes.c_size_t),
            ("Offset", wintypes.DWORD),
            ("OffsetHigh", wintypes.DWORD),
            ("hEvent", wintypes.HANDLE),
        ]

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    lock = kernel.LockFileEx
    lock.argtypes = [
        wintypes.HANDLE,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.DWORD,
        ctypes.POINTER(Overlapped),
    ]
    lock.restype = wintypes.BOOL
    unlock = kernel.UnlockFileEx
    unlock.argtypes = [
        wintypes.HANDLE,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.DWORD,
        ctypes.POINTER(Overlapped),
    ]
    unlock.restype = wintypes.BOOL
    return Overlapped, lock, unlock


def _try_lock(stream, shared):
    if os.name != "nt":
        try:
            portalocker.lock(
                stream,
                (portalocker.LOCK_SH if shared else portalocker.LOCK_EX) | portalocker.LOCK_NB,
            )
            return None
        except portalocker.LockException:
            return False
    import ctypes
    import msvcrt

    overlapped_type, lock, _ = _windows_api()
    overlapped = overlapped_type()  # Offset/OffsetHigh/hEvent are all zero.
    handle = msvcrt.get_osfhandle(stream.fileno())
    # FAIL_IMMEDIATELY=1; EXCLUSIVE_LOCK=2. Omit bit2 for a true shared lock.
    if lock(handle, 1 | (0 if shared else 2), 0, 1, 0, ctypes.byref(overlapped)):
        return overlapped
    if ctypes.get_last_error() == 33:  # ERROR_LOCK_VIOLATION on synchronous handles.
        return False
    raise BackupLeaseError()


def _unlock(stream, token):
    if os.name != "nt":
        portalocker.unlock(stream)
        return
    import ctypes
    import msvcrt

    _, _, unlock = _windows_api()
    if not unlock(msvcrt.get_osfhandle(stream.fileno()), 0, 1, 0, ctypes.byref(token)):
        raise BackupLeaseError()


def _identities(identities):
    values = tuple(identities)
    if (
        not 1 <= len(values) <= 20
        or any(not isinstance(value, UUID) for value in values)
        or len(set(values)) != len(values)
    ):
        raise BackupLeaseError("backup_lease_input_invalid")
    return tuple(sorted(values, key=str))


def _deadline(seconds):
    if type(seconds) not in {int, float} or not math.isfinite(seconds) or not 0 <= seconds <= 5:
        raise BackupLeaseError("backup_lease_input_invalid")
    return monotonic() + seconds


def _root(settings, backup_id):
    source = settings.data_directory.absolute()
    for part in (source, *source.parents):
        if part.is_symlink() or part.is_junction():
            raise UnsafeFilePath
    return private_directory(source / "backup-controls" / str(backup_id))


@contextmanager
def _locked(settings, backup_id, *, shared, deadline, check_budget):
    try:
        root = _root(settings, backup_id)
        path = root / "package.lock"
        try:
            with private_open(path, root, create=True):
                pass
        except FileExistsError:
            regular_file(path, root)
        with private_open(path, root, append=True) as stream:
            while True:
                if check_budget is not None:
                    check_budget()
                token = _try_lock(stream, shared)
                if token is not False:
                    break
                if monotonic() >= deadline:
                    raise BackupLeaseError("backup_busy", transient=True) from None
                sleep(min(0.01, max(0, deadline - monotonic())))
            try:
                if check_budget is not None:
                    check_budget()
                yield
            finally:
                _unlock(stream, token)
    except BackupLeaseError:
        raise
    except (OSError, portalocker.LockException):
        raise BackupLeaseError() from None


@contextmanager
def backup_read_lease(settings, backup_id, *, timeout_seconds=2.0, check_budget=None):
    identities = _identities((backup_id,))
    with _locked(
        settings,
        identities[0],
        shared=True,
        deadline=_deadline(timeout_seconds),
        check_budget=check_budget,
    ):
        yield identities


@contextmanager
def backup_exclusive_lease(settings, backup_ids, *, timeout_seconds=2.0, check_budget=None):
    identities, deadline = _identities(backup_ids), _deadline(timeout_seconds)
    with ExitStack() as stack:
        for identity in identities:
            stack.enter_context(
                _locked(
                    settings, identity, shared=False, deadline=deadline, check_budget=check_budget
                )
            )
        yield identities
