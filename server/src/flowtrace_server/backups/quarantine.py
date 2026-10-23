"""Internal bounded quarantine I/O; no route, job kind or database authority.

Trusted callers must establish current authority/reservations before execution,
recheck it in the required callback, and hold this context through final DB
commit. This module never deletes, overwrites, copies or restores a package.
"""

import ctypes
import errno
import hashlib
import os
import stat
import sys
from contextlib import ExitStack
from dataclasses import dataclass
from pathlib import Path
from time import monotonic
from types import SimpleNamespace
from uuid import UUID

from flowtrace_server.auth.service import now
from flowtrace_server.imports.parsers import canonical
from flowtrace_server.persistence.private_files import (
    contained,
    private_directory,
    private_open,
)

from . import retention
from .leases import backup_exclusive_lease, backup_read_lease
from .quarantine_schemas import QuarantinePlan, QuarantineReceipt
from .retention_schemas import PackageStamp

_TRUST = object()
MAX_RECORD_BYTES = 32768


class QuarantineError(RuntimeError):
    def __init__(self, code="backup_quarantine_partial", *, transient=False):
        super().__init__(code)
        self.code, self.transient = code, transient


@dataclass
class _LeaseState:
    active: bool = True


@dataclass(frozen=True)
class _PreparedBinding:
    plan_sha256: str
    witness_sha256: str
    lock_ids: tuple[UUID, ...]
    settings_key: str
    guard_identity: int
    state: _LeaseState


@dataclass
class PreparedQuarantine:
    plan: QuarantinePlan
    witness: PackageStamp
    settings_key: str
    settings: object
    guard: ExitStack
    trust: object
    _binding: _PreparedBinding
    closed: bool = False

    def close(self):
        if not self.closed:
            self.closed = True
            self.guard.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


@dataclass(frozen=True)
class QuarantineResult:
    intent_id: UUID
    receipts: tuple[QuarantineReceipt, ...]
    sha256: str


def _hash(value):
    return hashlib.sha256(canonical(value.model_dump(mode="json"))).hexdigest()


def _read_record(path, root, model):
    try:
        with private_open(path, root) as stream:
            raw = stream.read(MAX_RECORD_BYTES + 1)
        if len(raw) > MAX_RECORD_BYTES:
            raise ValueError
        return model.model_validate_json(raw)
    except Exception:
        raise QuarantineError() from None


def _write_record(path, root, value):
    raw = canonical(value.model_dump(mode="json"))
    if len(raw) > MAX_RECORD_BYTES:
        raise QuarantineError("backup_quarantine_record_too_large")
    try:
        with private_open(path, root, create=True) as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        _sync_directory(root)
    except OSError:
        # A partial immutable record remains for explicit review, never rewrite.
        raise QuarantineError() from None


def _sync_directory(path):
    if os.name == "posix":
        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def _directory_exists(path, root):
    contained(path, root)
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    if not stat.S_ISDIR(info.st_mode):
        raise QuarantineError()
    return True


def _io_root(settings):
    value = os.path.abspath(settings.data_directory)
    if os.name == "nt" and not value.startswith("\\\\?\\"):
        # Adding the fixed quarantine layout can push an otherwise readable
        # object beyond MAX_PATH. Keep all private-file/link checks, but pass
        # one consistent extended root to Windows I/O and no-replace rename.
        value = "\\\\?\\UNC\\" + value[2:] if value.startswith("\\\\") else "\\\\?\\" + value
    return Path(value)


def _paths(settings, plan):
    base = private_directory(_io_root(settings))
    source = base / "backups"
    contained(source, base)
    destination = private_directory(base / "backup-quarantine" / str(plan.intent_id))
    target = private_directory(destination / "backups")
    receipts = private_directory(destination / "receipts")
    expected = {str(item.backup_id) for item in plan.packages}
    for directory, allowed in (
        (destination, {"backups", "receipts", "intent.json"}),
        (target, expected),
        (receipts, {name + ".json" for name in expected}),
    ):
        with os.scandir(directory) as entries:
            for index, entry in enumerate(entries):
                if (
                    index > 20
                    or entry.name not in allowed
                    or entry.is_symlink()
                    or Path(entry.path).is_junction()
                ):
                    raise QuarantineError()
    return source, destination, target, receipts


def _bind_plan(destination, plan):
    path = destination / "intent.json"
    if path.exists():
        if _read_record(path, destination, QuarantinePlan) != plan:
            raise QuarantineError("backup_quarantine_binding_changed")
    else:
        _write_record(path, destination, plan)


def _verify(settings, base, expected, check_budget):
    # The normal strict verifier uses <data>/backups/<id>. Only its I/O root is
    # adapted for the fixed quarantine layout; auth/source use real settings.
    context = (
        settings
        if base == Path(os.path.abspath(settings.data_directory)) / "backups"
        else (SimpleNamespace(data_directory=base.parent))
    )
    actual = retention._verify_stamp(context, expected.backup_id, check_budget=check_budget)
    if not retention._same_package(actual, expected):
        raise QuarantineError("backup_package_changed")


def _receipt(plan, expected, receipt):
    wanted = {
        "intent_id": plan.intent_id,
        "job_id": plan.job_id,
        "actor_id": plan.actor_id,
        "source_instance_id": plan.source_instance_id,
        "source_epoch": plan.source_epoch,
        "config_version": plan.config_version,
        "selection_sha256": plan.selection_sha256,
        "plan_sha256": _hash(plan),
        "package": expected,
    }
    if any(getattr(receipt, name) != value for name, value in wanted.items()):
        raise QuarantineError("backup_quarantine_binding_changed")
    return receipt


def _state(settings, plan, expected, roots, check_budget):
    source, _, target, receipts = roots
    identifier = str(expected.backup_id)
    source_exists = _directory_exists(source / identifier, source)
    target_exists = _directory_exists(target / identifier, target)
    path = receipts / f"{identifier}.json"
    if source_exists and not target_exists and not path.exists():
        _verify(settings, source, expected, check_budget)
        return None
    if not source_exists and target_exists and path.exists():
        receipt = _receipt(plan, expected, _read_record(path, receipts, QuarantineReceipt))
        _verify(settings, target, expected, check_budget)
        return receipt
    raise QuarantineError()


def prepare_quarantine(settings, *, plan, witness, check_budget=None):
    """Pure I/O. Caller must have committed precheck before waiting on locks."""
    if (
        not isinstance(plan, QuarantinePlan)
        or not isinstance(witness, PackageStamp)
        or witness.backup_id in {item.backup_id for item in plan.packages}
        or (witness.instance_id, witness.sync_epoch) != (plan.source_instance_id, plan.source_epoch)
    ):
        raise QuarantineError("backup_quarantine_input_invalid")
    guard = ExitStack()
    lease_state = _LeaseState()
    guard.callback(setattr, lease_state, "active", False)
    try:
        deadline = monotonic() + 2
        selected = {item.backup_id for item in plan.packages}
        for identifier in sorted((*selected, witness.backup_id), key=str):
            remaining = max(0, deadline - monotonic())
            lock = (
                backup_exclusive_lease(
                    settings, (identifier,), timeout_seconds=remaining, check_budget=check_budget
                )
                if identifier in selected
                else (
                    backup_read_lease(
                        settings, identifier, timeout_seconds=remaining, check_budget=check_budget
                    )
                )
            )
            guard.enter_context(lock)
        roots = _paths(settings, plan)
        _bind_plan(roots[1], plan)
        _verify(settings, roots[0], witness, check_budget)
        for expected in plan.packages:
            _state(settings, plan, expected, roots, check_budget)
        key = retention._settings_key(settings)
        binding = _PreparedBinding(
            _hash(plan),
            _hash(witness),
            tuple(sorted((*selected, witness.backup_id), key=str)),
            key,
            id(guard),
            lease_state,
        )
        return PreparedQuarantine(plan, witness, key, settings, guard, _TRUST, binding)
    except BaseException:
        guard.close()
        raise


def _rename_noreplace(source, target):
    """Same-volume atomic no-replace only. Unsupported OS/FS safely refuses."""
    if source.parent.stat().st_dev != target.parent.stat().st_dev:
        raise QuarantineError("backup_quarantine_cross_device")
    if os.name == "nt":
        from ctypes import wintypes

        function = ctypes.WinDLL("kernel32", use_last_error=True).MoveFileExW
        function.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD]
        function.restype = wintypes.BOOL
        # WRITE_THROUGH only: never REPLACE_EXISTING, COPY_ALLOWED or DELAY.
        if not function(str(source), str(target), 8):
            raise QuarantineError()
    elif sys.platform.startswith("linux"):
        library = ctypes.CDLL(None, use_errno=True)
        function = getattr(library, "renameat2", None)
        if function is None:
            raise QuarantineError("backup_quarantine_platform_unavailable")
        function.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        function.restype = ctypes.c_int
        source_fd = os.open(source.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            target_fd = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                if (
                    function(
                        source_fd, os.fsencode(source.name), target_fd, os.fsencode(target.name), 1
                    )
                    != 0
                ):  # RENAME_NOREPLACE
                    code = ctypes.get_errno()
                    unavailable = code in {errno.ENOSYS, errno.EINVAL, errno.EOPNOTSUPP}
                    raise QuarantineError(
                        "backup_quarantine_platform_unavailable"
                        if unavailable
                        else "backup_quarantine_partial"
                    )
            finally:
                os.close(target_fd)
        finally:
            os.close(source_fd)
    else:
        raise QuarantineError("backup_quarantine_platform_unavailable")
    _sync_directory(source.parent)
    _sync_directory(target.parent)


def execute_quarantine(prepared, *, check_authority, check_budget=None):
    """Caller must close in finally after final fenced DB commit or failure.

    The required callback is trusted worker policy and must raise on lease,
    owner, permission, source/config or reservation changes. A false result also
    refuses execution. No financial/job success is recorded by this module.
    """
    if (
        not isinstance(prepared, PreparedQuarantine)
        or prepared.trust is not _TRUST
        or prepared.closed
        or not callable(check_authority)
        or prepared.settings_key != retention._settings_key(prepared.settings)
        or not _binding_matches(prepared)
    ):
        raise QuarantineError("backup_quarantine_input_invalid")

    def authority():
        if check_budget:
            check_budget()
        if check_authority() is False:
            raise QuarantineError("backup_quarantine_authority_changed")

    plan, settings = prepared.plan, prepared.settings
    roots = _paths(settings, plan)
    _bind_plan(roots[1], plan)
    authority()
    _verify(settings, roots[0], prepared.witness, check_budget)
    completed = []
    for expected in plan.packages:
        authority()
        receipt = _state(settings, plan, expected, roots, check_budget)
        if receipt is None:
            authority()
            identifier = str(expected.backup_id)
            # Recheck exact owned parents immediately before atomic no-replace.
            contained(roots[0] / identifier, roots[0])
            contained(roots[2] / identifier, roots[2])
            _rename_noreplace(roots[0] / identifier, roots[2] / identifier)
            _verify(settings, roots[2], expected, check_budget)
            authority()
            receipt = QuarantineReceipt(
                intent_id=plan.intent_id,
                job_id=plan.job_id,
                actor_id=plan.actor_id,
                source_instance_id=plan.source_instance_id,
                source_epoch=plan.source_epoch,
                config_version=plan.config_version,
                selection_sha256=plan.selection_sha256,
                plan_sha256=_hash(plan),
                package=expected,
                moved_at=now(),
            )
            _write_record(roots[3] / f"{identifier}.json", roots[3], receipt)
        completed.append(receipt)
    authority()
    digest = hashlib.sha256(
        canonical([receipt.model_dump(mode="json") for receipt in completed])
    ).hexdigest()
    return QuarantineResult(plan.intent_id, tuple(completed), digest)


def _binding_matches(prepared):
    # Defensive internal consistency, not an authorization capability. Replacing
    # a DTO must not redirect work outside the factory's actual held locks.
    try:
        binding = prepared._binding
        return (
            isinstance(binding, _PreparedBinding)
            and binding.state.active
            and isinstance(prepared.plan, QuarantinePlan)
            and isinstance(prepared.witness, PackageStamp)
            and binding.guard_identity == id(prepared.guard)
            and binding.settings_key == prepared.settings_key
            and binding.plan_sha256 == _hash(prepared.plan)
            and binding.witness_sha256 == _hash(prepared.witness)
            and binding.lock_ids
            == tuple(
                sorted(
                    (
                        *[item.backup_id for item in prepared.plan.packages],
                        prepared.witness.backup_id,
                    ),
                    key=str,
                )
            )
        )
    except Exception:
        return False
