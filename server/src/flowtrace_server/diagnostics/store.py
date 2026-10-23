"""Bounded, process-serialized diagnostic files; never a business receipt."""

import json
import re
import sys
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

import portalocker

from flowtrace_server.persistence.private_files import (
    prepare_file,
    private_directory,
    private_open,
    private_unlink,
    regular_file,
)

NAME = re.compile(r"flowtrace-([0-9]{4}-[0-9]{2}-[0-9]{2})\.jsonl(?:\.([1-3]))?\Z")


class DiagnosticUnavailable(OSError):
    def __init__(self):
        super().__init__("diagnostic_unavailable")


@dataclass(frozen=True)
class Limits:
    file_bytes: int = 1024 * 1024
    total_bytes: int = 8 * 1024 * 1024
    retention_days: int = 7
    backups: int = 3
    record_bytes: int = 2048
    export_bytes: int = 1024 * 1024
    lock_seconds: float = 2.0

    def __post_init__(self):
        if not (
            256 <= self.record_bytes <= self.file_bytes <= self.total_bytes <= 64 * 1024 * 1024
            and 1 <= self.retention_days <= 30
            and 0 <= self.backups <= 3
            and 256 <= self.export_bytes <= 8 * 1024 * 1024
            and 0 < self.lock_seconds <= 2
        ):
            raise ValueError("diagnostic_limits_invalid")


class DiagnosticStore:
    _last_notice = float("-inf")
    _notice_lock = threading.Lock()

    def __init__(self, root: Path, limits: Limits | None = None):
        self.root = private_directory(root)
        self.limits = limits or Limits()
        self._thread_lock = threading.Lock()

    @staticmethod
    def notice_failure() -> None:
        with DiagnosticStore._notice_lock:
            stamp = time.monotonic()
            if stamp - DiagnosticStore._last_notice < 60:
                return
            DiagnosticStore._last_notice = stamp
        try:
            sys.stderr.write('{"event":"diagnostic_unavailable"}\n')
        except Exception:
            pass

    @contextmanager
    def locked(self):
        deadline = time.monotonic() + self.limits.lock_seconds
        if not self._thread_lock.acquire(timeout=self.limits.lock_seconds):
            raise DiagnosticUnavailable
        try:
            lock = self.root / ".diagnostics.lock"
            prepare_file(lock, self.root)
            with private_open(lock, self.root, append=True) as stream:
                while True:
                    try:
                        portalocker.lock(stream, portalocker.LOCK_EX | portalocker.LOCK_NB)
                        break
                    except portalocker.LockException:
                        if time.monotonic() >= deadline:
                            raise DiagnosticUnavailable from None
                        time.sleep(min(0.02, max(0, deadline - time.monotonic())))
                try:
                    yield
                finally:
                    portalocker.unlock(stream)
        finally:
            self._thread_lock.release()

    def managed(self) -> list[tuple[date, Path, int]]:
        output = []
        for path in self.root.iterdir():
            match = NAME.fullmatch(path.name)
            if match is None:
                continue
            try:
                day = date.fromisoformat(match[1])
                info = regular_file(path, self.root)
            except (OSError, ValueError):
                continue  # Unfamiliar files/links are neither exported nor deleted.
            output.append((day, path, info.st_size))
        return sorted(output, key=lambda item: (item[0], item[1].name))

    def _clean(self, today: date, reserved: int = 0) -> None:
        oldest = today - timedelta(days=self.limits.retention_days - 1)
        files = self.managed()
        for day, path, _ in files:
            if day < oldest:
                private_unlink(path, self.root)
        files = self.managed()
        total = sum(size for _, _, size in files)
        for _, path, size in files:
            if total + reserved <= self.limits.total_bytes:
                break
            private_unlink(path, self.root)
            total -= size

    def append(self, fields: dict, timestamp: datetime | None = None, *, guard=None) -> bool:
        from . import safe_payload

        stamp = timestamp or datetime.now(UTC)
        if stamp.tzinfo is None:
            return False
        stamp = stamp.astimezone(UTC)
        payload = safe_payload(fields, stamp)
        encoded = (json.dumps(payload, separators=(",", ":"), ensure_ascii=True) + "\n").encode()
        if len(encoded) > self.limits.record_bytes:
            encoded = (
                json.dumps(
                    {"timestamp": stamp.isoformat(), "event": "record_omitted", "truncated": True}
                )
                + "\n"
            ).encode()
        try:
            with self.locked():
                if guard is not None:
                    try:
                        if guard() is not True:
                            return False
                    except Exception:
                        return False
                self._clean(stamp.date(), len(encoded))
                target = self.root / f"flowtrace-{stamp.date().isoformat()}.jsonl"
                if (
                    target.exists()
                    and regular_file(target, self.root).st_size + len(encoded)
                    > self.limits.file_bytes
                ):
                    for index in range(self.limits.backups, 0, -1):
                        destination = Path(str(target) + f".{index}")
                        origin = target if index == 1 else Path(str(target) + f".{index - 1}")
                        if destination.exists() or destination.is_symlink():
                            private_unlink(destination, self.root)
                        if origin.exists():
                            regular_file(origin, self.root)
                            origin.replace(destination)
                    if self.limits.backups == 0:
                        private_unlink(target, self.root)
                prepare_file(target, self.root)
                with private_open(target, self.root, append=True) as stream:
                    stream.write(encoded)
                    stream.flush()
            return True
        except (OSError, portalocker.LockException):
            self.notice_failure()
            return False

    def export(self) -> bytes:
        from . import safe_payload

        output = bytearray(
            b'{"format":"flowtrace-diagnostics-v1","sanitized":true,"bounded":true}\n'
        )
        footer = b'{"export_truncated":true}\n'
        with self.locked():
            for _, path, size in self.managed():
                if size > self.limits.file_bytes:
                    continue
                with private_open(path, self.root) as stream:
                    while line := stream.readline(self.limits.record_bytes + 1):
                        if len(line) > self.limits.record_bytes or not line.endswith(b"\n"):
                            break
                        try:
                            original = json.loads(line)
                            stamp = datetime.fromisoformat(original["timestamp"])
                            if stamp.tzinfo is None:
                                continue
                            sanitized = safe_payload(original, stamp)
                        except (ValueError, TypeError, KeyError):
                            continue
                        encoded = (json.dumps(sanitized, separators=(",", ":")) + "\n").encode()
                        if len(output) + len(encoded) + len(footer) > self.limits.export_bytes:
                            return bytes(output) + footer
                        output.extend(encoded)
        return bytes(output)
