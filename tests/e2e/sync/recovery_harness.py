"""Real isolated PostgreSQL rollback with the Flutter VM recovery client.

Only 127.0.0.1:55432/flowtrace_test_recovery_local and the child service on
127.0.0.1:18083 are allowed. Credentials, dumps and process logs stay in work/;
the public receipt contains only synthetic identifiers and assertions. This is
a protocol exercise, not a production/Linux or attachment backup implementation.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import secrets
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import UTC, datetime
from pathlib import Path
from uuid import UUID, uuid4

import psycopg
from flowtrace_server.auth.service import create_user
from flowtrace_server.books.models import BookMembership
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.persistence.registry import Base  # noqa: F401
from psycopg import sql
from sqlalchemy import create_engine, select, text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import Session
from sqlalchemy.pool import NullPool

ROOT = Path(__file__).resolve().parents[3]
PRIVATE = ROOT / "work" / "flowtrace-recovery"
PG_DIR = ROOT / "work" / "flowtrace-dev" / "postgresql"
DATABASE = "flowtrace_test_recovery_local"
HOST, PG_PORT, HTTP_PORT = "127.0.0.1", 55432, 18083
SERVER = f"http://{HOST}:{HTTP_PORT}"
FLUTTER = Path("C:/Ruibin_Ningh/app/FlutterSDK/flutter/bin/flutter.bat")
NO_WINDOW = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


class WindowsOwnedJob:
    """One private kill-on-close job, containing only a newly suspended child."""

    def __init__(self):
        from ctypes import wintypes

        class Limits(ctypes.Structure):
            _fields_ = [
                ("process_time", ctypes.c_longlong),
                ("job_time", ctypes.c_longlong),
                ("flags", wintypes.DWORD),
                ("minimum_working_set", ctypes.c_size_t),
                ("maximum_working_set", ctypes.c_size_t),
                ("active_process_limit", wintypes.DWORD),
                ("affinity", ctypes.c_size_t),
                ("priority", wintypes.DWORD),
                ("scheduling", wintypes.DWORD),
            ]

        class Counters(ctypes.Structure):
            _fields_ = [
                (name, ctypes.c_ulonglong)
                for name in [
                    "read_ops",
                    "write_ops",
                    "other_ops",
                    "read_bytes",
                    "write_bytes",
                    "other_bytes",
                ]
            ]

        class ExtendedLimits(ctypes.Structure):
            _fields_ = [
                ("basic", Limits),
                ("io", Counters),
                ("process_memory", ctypes.c_size_t),
                ("job_memory", ctypes.c_size_t),
                ("peak_process_memory", ctypes.c_size_t),
                ("peak_job_memory", ctypes.c_size_t),
            ]

        self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        self.api.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        self.api.CreateJobObjectW.restype = wintypes.HANDLE
        self.api.SetInformationJobObject.argtypes = [
            wintypes.HANDLE,
            ctypes.c_int,
            ctypes.c_void_p,
            wintypes.DWORD,
        ]
        self.api.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        self.api.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
        self.api.CloseHandle.argtypes = [wintypes.HANDLE]
        self.handle = self.api.CreateJobObjectW(None, None)
        if not self.handle:
            raise RuntimeError("private_process_job_creation_failed")
        limits = ExtendedLimits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.api.SetInformationJobObject(
            self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)
        ):
            self.close()
            raise RuntimeError("private_process_job_limit_failed")

    def assign_and_resume(self, process: subprocess.Popen):
        from ctypes import wintypes

        if not self.api.AssignProcessToJobObject(self.handle, int(process._handle)):
            raise RuntimeError("private_process_job_assignment_failed")

        class ThreadEntry(ctypes.Structure):
            _fields_ = [
                ("size", wintypes.DWORD),
                ("usage", wintypes.DWORD),
                ("thread_id", wintypes.DWORD),
                ("owner_pid", wintypes.DWORD),
                ("base_priority", wintypes.LONG),
                ("delta_priority", wintypes.LONG),
                ("flags", wintypes.DWORD),
            ]

        self.api.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
        self.api.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
        self.api.Thread32First.argtypes = [wintypes.HANDLE, ctypes.POINTER(ThreadEntry)]
        self.api.Thread32Next.argtypes = [wintypes.HANDLE, ctypes.POINTER(ThreadEntry)]
        self.api.OpenThread.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.api.OpenThread.restype = wintypes.HANDLE
        self.api.ResumeThread.argtypes = [wintypes.HANDLE]
        self.api.ResumeThread.restype = wintypes.DWORD
        snapshot = self.api.CreateToolhelp32Snapshot(4, 0)  # TH32CS_SNAPTHREAD
        if snapshot in (None, ctypes.c_void_p(-1).value):
            raise RuntimeError("owned_suspended_thread_snapshot_failed")
        entry = ThreadEntry()
        entry.size = ctypes.sizeof(entry)
        resumed = 0
        try:
            present = self.api.Thread32First(snapshot, ctypes.byref(entry))
            while present:
                if entry.owner_pid == process.pid:
                    thread = self.api.OpenThread(2, False, entry.thread_id)
                    if not thread:
                        raise RuntimeError("owned_suspended_thread_open_failed")
                    try:
                        if self.api.ResumeThread(thread) == 0xFFFFFFFF:
                            raise RuntimeError("owned_suspended_thread_resume_failed")
                        resumed += 1
                    finally:
                        self.api.CloseHandle(thread)
                present = self.api.Thread32Next(snapshot, ctypes.byref(entry))
        finally:
            self.api.CloseHandle(snapshot)
        if not resumed:
            raise RuntimeError("owned_suspended_thread_missing")

    def terminate(self):
        if self.handle:
            self.api.TerminateJobObject(self.handle, 1)

    def close(self):
        if self.handle:
            self.api.CloseHandle(self.handle)
            self.handle = None


def spawn_owned(command: list[str], **kwargs) -> subprocess.Popen:
    if os.name != "nt":
        return subprocess.Popen(command, **kwargs)
    job = WindowsOwnedJob()
    process = None
    try:
        # Suspend before assignment so even venv/cmd redirector descendants can
        # never escape this job between Popen and AssignProcessToJobObject.
        process = subprocess.Popen(command, creationflags=NO_WINDOW | 4, **kwargs)
        process._flowtrace_owned_job = job
        job.assign_and_resume(process)
        return process
    except Exception:
        job.terminate()
        if process is not None:
            process.kill()
            process.wait(timeout=10)
        job.close()
        raise


def write_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    temporary.replace(path)


def safe_run_dir(path: Path) -> Path:
    resolved = path.resolve()
    if not resolved.is_relative_to(PRIVATE.resolve()) or resolved == PRIVATE.resolve():
        raise RuntimeError("run_directory_outside_recovery_workspace")
    return resolved


def ensure_port_free() -> None:
    with socket.socket() as probe:
        probe.settimeout(0.5)
        if probe.connect_ex((HOST, HTTP_PORT)) == 0:
            raise RuntimeError("dedicated_recovery_port_already_in_use")


def load_database_url():
    values = {}
    for line in (
        (PG_DIR / "server-local.env").read_text(encoding="utf-8-sig").splitlines()
    ):
        if line.strip() and not line.lstrip().startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip("\"'")
    source = make_url(values["FLOWTRACE_DATABASE_URL"])
    if (
        source.drivername != "postgresql+psycopg"
        or source.host != HOST
        or source.port != PG_PORT
        or source.username != "flowtrace_dev"
        or not source.password
        or source.query
    ):
        raise RuntimeError("database_configuration_guard_failed")
    target = source.set(database=DATABASE)
    if target.database != DATABASE:
        raise RuntimeError("database_name_guard_failed")
    return target


def engine_for(url):
    if url.host != HOST or url.port != PG_PORT or url.database != DATABASE:
        raise RuntimeError("database_target_guard_failed")
    return create_engine(url, poolclass=NullPool, hide_parameters=True)


def check_connection(connection) -> None:
    actual = connection.execute(
        text("SELECT current_database(), host(inet_server_addr()), inet_server_port()")
    ).one()
    if tuple(actual) != (DATABASE, HOST, PG_PORT):
        raise RuntimeError("connected_database_guard_failed")


def create_database(url, *, reset: bool) -> None:
    ensure_port_free()
    admin = json.loads((PG_DIR / "local-credentials.json").read_text(encoding="utf-8"))
    with psycopg.connect(
        host=HOST,
        port=PG_PORT,
        dbname="postgres",
        user="flowtrace_admin",
        password=admin["admin_password"],
        autocommit=True,
        connect_timeout=3,
    ) as connection:
        actual = connection.execute(
            "SELECT host(inet_server_addr()), inet_server_port()"
        ).fetchone()
        if actual != (HOST, PG_PORT):
            raise RuntimeError("administrator_host_guard_failed")
        exists = connection.execute(
            "SELECT 1 FROM pg_database WHERE datname = %s", (DATABASE,)
        ).fetchone()
        if not exists:
            connection.execute(
                sql.SQL("CREATE DATABASE {} OWNER {}").format(
                    sql.Identifier(DATABASE), sql.Identifier(url.username)
                )
            )
    engine = engine_for(url)
    try:
        with engine.begin() as connection:
            check_connection(connection)
            populated = connection.scalar(
                text(
                    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'"
                )
            )
            if populated and not reset:
                raise RuntimeError(
                    "dedicated_database_exists_use_explicit_reset_isolated"
                )
            if populated:
                # This connection is checked immediately above. No cross-database
                # session termination, inferred path deletion or shell SQL exists.
                connection.execute(text("DROP SCHEMA public CASCADE"))
                connection.execute(text("CREATE SCHEMA public"))
    finally:
        engine.dispose()


def service_environment(url, run_dir: Path) -> dict[str, str]:
    env = dict(os.environ)
    env.update(
        FLOWTRACE_ENVIRONMENT="test",
        FLOWTRACE_DATABASE_URL=url.render_as_string(hide_password=False),
        FLOWTRACE_TEST_DATABASE_URL=url.render_as_string(hide_password=False),
        FLOWTRACE_DATA_DIRECTORY=str(run_dir / "server-data"),
        FLOWTRACE_ALLOWED_HOSTS=json.dumps([HOST]),
        FLOWTRACE_CORS_ORIGINS="[]",
        PYTHONUTF8="1",
    )
    return env


def checked_command(command: list[str], env: dict[str, str], log: Path) -> None:
    with log.open("ab") as output:
        process = spawn_owned(
            command,
            cwd=ROOT / "server",
            env=env,
            stdout=output,
            stderr=subprocess.STDOUT,
        )
        try:
            code = process.wait(timeout=90)
        finally:
            stop_owned(process)
    if code:
        raise RuntimeError("isolated_child_command_failed")


def prepare(url, *, reset: bool) -> Path:
    create_database(url, reset=reset)
    run_dir = safe_run_dir(PRIVATE / uuid4().hex)
    run_dir.mkdir(parents=True, exist_ok=False)
    checked_command(
        [sys.executable, "-m", "flowtrace_server.tools.migrate", "upgrade"],
        service_environment(url, run_dir),
        run_dir / "migration.log",
    )
    username = "recovery_" + secrets.token_hex(8)
    password = "Synthetic-recovery-" + secrets.token_urlsafe(20)
    engine = engine_for(url)
    try:
        with Session(engine) as session:
            check_connection(session.connection())
            user = create_user(session, username, password)
            book_id = session.scalar(
                select(BookMembership.book_id).where(BookMembership.user_id == user.id)
            )
            state = session.get(ServerState, 1)
            identity = {
                "instance_id": str(state.instance_id),
                "epoch": str(state.sync_epoch),
            }
            user_id = str(user.id)
            session.commit()
    finally:
        engine.dispose()
    write_json(
        run_dir / "client-config.json",
        {
            "version": 1,
            "server": SERVER,
            "username": username,
            "password": password,
            "user_id": user_id,
            "book_id": str(book_id),
            "run_dir": str(run_dir),
            "run_id": run_dir.name,
        },
    )
    write_json(run_dir / "prepared.json", {"database": DATABASE, **identity})
    return run_dir


def stop_owned(process: subprocess.Popen | None) -> None:
    if process is None:
        return
    job = getattr(process, "_flowtrace_owned_job", None)
    if job is not None:
        job.terminate()
    if process.poll() is None:
        # terminate() uses our retained process handle, never a searched PID.
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
    if job is not None:
        job.close()


class RecoveryRun:
    def __init__(self, url, run_dir: Path):
        self.url, self.run_dir = url, safe_run_dir(run_dir)
        self.env = service_environment(url, run_dir)
        self.service = None
        self.client = None
        self._server_log = None
        self.evidence = {"database": DATABASE, "server": SERVER, "phases": {}}
        self.dump_path = run_dir / "baseline.dump"

    def start_service(self):
        ensure_port_free()
        self._server_log = (self.run_dir / "server.log").open("ab")
        self.service = spawn_owned(
            [
                sys.executable,
                "-m",
                "uvicorn",
                "flowtrace_server.main:app",
                "--host",
                HOST,
                "--port",
                str(HTTP_PORT),
                "--no-access-log",
                "--log-level",
                "warning",
            ],
            cwd=ROOT / "server",
            env=self.env,
            stdout=self._server_log,
            stderr=subprocess.STDOUT,
        )
        write_json(
            self.run_dir / "owned-service.json",
            {
                "launcher_pid": self.service.pid,
                "port": HTTP_PORT,
                "created_at": datetime.now(UTC).isoformat(),
                "private_kill_on_close_job": os.name == "nt",
            },
        )
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.service.poll() is not None:
                raise RuntimeError("dedicated_service_exited_before_ready")
            try:
                with urllib.request.urlopen(
                    SERVER + "/health/ready", timeout=1
                ) as response:
                    if response.status == 200:
                        return
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(0.2)
        raise RuntimeError("dedicated_service_ready_timeout")

    def stop_service(self):
        was_owned = self.service is not None
        stop_owned(self.service)
        self.service = None
        if self._server_log is not None:
            self._server_log.close()
            self._server_log = None
        if was_owned:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                with socket.socket() as probe:
                    probe.settimeout(0.1)
                    if probe.connect_ex((HOST, HTTP_PORT)) != 0:
                        return
                time.sleep(0.05)
            raise RuntimeError("owned_service_listener_did_not_close")

    def database_check(self, request: dict, *, before_restore: bool) -> dict:
        account_id = UUID(request["account_id"])
        bill_id = UUID(request["bill_id"]) if "bill_id" in request else None
        tag_id = UUID(request["tag_id"]) if "tag_id" in request else None
        engine = engine_for(self.url)
        try:
            with engine.connect() as connection:
                check_connection(connection)
                balance = connection.scalar(
                    text(
                        "SELECT balance_minor FROM sync_entities WHERE id=:id AND NOT deleted"
                    ),
                    {"id": account_id},
                )
                if balance != (87500 if before_restore else 100000):
                    raise RuntimeError("unexpected_baseline_or_expense_balance")
                for identifier, expected in [
                    (bill_id, int(before_restore)),
                    (tag_id, 0),
                ]:
                    if identifier is None:
                        continue
                    actual = connection.scalar(
                        text("SELECT count(*) FROM sync_entities WHERE id=:id"),
                        {"id": identifier},
                    )
                    if actual != expected:
                        raise RuntimeError("unexpected_recovery_entity_count")
                state = connection.execute(
                    text(
                        "SELECT instance_id,sync_epoch FROM server_state WHERE singleton_id=1"
                    )
                ).one()
                return {
                    "instance_id": str(state.instance_id),
                    "epoch": str(state.sync_epoch),
                }
        finally:
            engine.dispose()

    def pg_command(self, executable: str, extra: list[str]):
        if (
            self.url.database != DATABASE
            or self.url.host != HOST
            or self.url.port != PG_PORT
        ):
            raise RuntimeError("postgres_command_guard_failed")
        env = dict(self.env, PGPASSWORD=self.url.password, PGCONNECT_TIMEOUT="3")
        checked_command(
            [
                str(PG_DIR / "pgsql" / "bin" / (executable + ".exe")),
                "--host",
                HOST,
                "--port",
                str(PG_PORT),
                "--username",
                self.url.username,
                "--dbname",
                DATABASE,
                *extra,
            ],
            env,
            self.run_dir / "postgres-tools.log",
        )

    def handle(self, action: str, request: dict) -> dict:
        if request.get("run_id") != self.run_dir.name:
            raise RuntimeError("handshake_run_guard_failed")
        phases = self.evidence["phases"]
        if action == "dump":
            if phases:
                raise RuntimeError("dump_handshake_out_of_order")
            state = self.database_check(request, before_restore=False)
            engine = engine_for(self.url)
            try:
                with engine.connect() as connection:
                    check_connection(connection)
                    if not connection.scalar(
                        text(
                            "SELECT count(*) FROM sessions WHERE id=:id AND revoked_at IS NULL"
                        ),
                        {"id": UUID(request["session_id"])},
                    ):
                        raise RuntimeError("baseline_session_missing")
            finally:
                engine.dispose()
            self.pg_command(
                "pg_dump", ["--format=custom", "--file", str(self.dump_path)]
            )
            phases[action] = {
                "passed": True,
                **state,
                "dump_bytes": self.dump_path.stat().st_size,
            }
        elif action == "restore":
            if set(phases) != {"dump"} or not self.dump_path.is_file():
                raise RuntimeError("restore_handshake_out_of_order")
            original = self.database_check(request, before_restore=True)
            self.stop_service()
            ensure_port_free()
            self.pg_command(
                "pg_restore",
                [
                    "--clean",
                    "--if-exists",
                    "--exit-on-error",
                    "--no-owner",
                    "--no-privileges",
                    str(self.dump_path),
                ],
            )
            restored = self.database_check(request, before_restore=False)
            if restored != original or restored != {
                "instance_id": phases["dump"]["instance_id"],
                "epoch": phases["dump"]["epoch"],
            }:
                raise RuntimeError("dump_identity_was_not_restored")
            epoch = uuid4()
            engine = engine_for(self.url)
            try:
                with engine.begin() as connection:
                    check_connection(connection)
                    state = connection.execute(
                        text(
                            "SELECT instance_id,sync_epoch FROM server_state "
                            "WHERE singleton_id=1 FOR UPDATE"
                        )
                    ).one()
                    if str(state.instance_id) != original["instance_id"]:
                        raise RuntimeError("restore_instance_mismatch")
                    connection.execute(
                        text(
                            "UPDATE server_state SET sync_epoch=:epoch WHERE singleton_id=1"
                        ),
                        {"epoch": epoch},
                    )
            finally:
                engine.dispose()
            self.start_service()
            phases[action] = {
                "passed": True,
                "instance_id": original["instance_id"],
                "old_epoch": original["epoch"],
                "new_epoch": str(epoch),
                "account_balance_minor": "100000",
                "acknowledged_expense_absent": True,
                "unsent_tag_absent": True,
            }
        elif action == "verify":
            if set(phases) != {"dump", "restore"}:
                raise RuntimeError("verification_handshake_out_of_order")
            state = self.database_check(request, before_restore=False)
            engine = engine_for(self.url)
            try:
                with engine.connect() as connection:
                    check_connection(connection)
                    for operation_id in request["old_operation_ids"]:
                        if connection.scalar(
                            text(
                                "SELECT count(*) FROM sync_receipts WHERE operation_id=:id"
                            ),
                            {"id": UUID(operation_id)},
                        ):
                            raise RuntimeError("old_operation_was_replayed")
            finally:
                engine.dispose()
            phases[action] = {"passed": True, **state, "old_operations_replayed": 0}
        else:
            raise RuntimeError("unknown_handshake_action")
        write_json(self.run_dir / "server-evidence.json", self.evidence)
        return {"ok": True, **phases[action]}

    def run(self):
        self.start_service()
        env = dict(
            self.env,
            FLOWTRACE_RECOVERY_QA_FILE=str(self.run_dir / "client-config.json"),
        )
        command = [
            str(FLUTTER),
            "--no-version-check",
            "test",
            "--no-pub",
            "test/live/recovery_http_test.dart",
            "--reporter=expanded",
        ]
        with (self.run_dir / "flutter.log").open("wb") as output:
            self.client = spawn_owned(
                command,
                cwd=ROOT / "apps" / "flowtrace",
                env=env,
                stdout=output,
                stderr=subprocess.STDOUT,
            )
            deadline = time.monotonic() + 300
            while self.client.poll() is None:
                if time.monotonic() > deadline:
                    raise RuntimeError("flutter_recovery_timeout")
                for action in ["dump", "restore", "verify"]:
                    request = self.run_dir / f"{action}.request.json"
                    response = self.run_dir / f"{action}.response.json"
                    if request.is_file() and not response.is_file():
                        try:
                            result = self.handle(
                                action, json.loads(request.read_text("utf-8"))
                            )
                        except Exception:
                            write_json(
                                response,
                                {"ok": False, "code": "isolated_recovery_failed"},
                            )
                            raise
                        write_json(response, result)
                        print(f"recovery_phase_{action}_passed", flush=True)
                time.sleep(0.1)
        if self.client.returncode != 0:
            raise RuntimeError("flutter_recovery_assertion_failed_see_private_log")
        if set(self.evidence["phases"]) != {"dump", "restore", "verify"}:
            raise RuntimeError("recovery_phases_incomplete")
        client_receipt = json.loads(
            (self.run_dir / "client-evidence.json").read_text("utf-8")
        )
        with self.dump_path.open("rb") as dump:
            dump_sha256 = hashlib.file_digest(dump, "sha256").hexdigest()
        self.evidence.update(
            status="passed",
            completed_at=datetime.now(UTC).isoformat(),
            client=client_receipt,
            dump_sha256=dump_sha256,
            scope="Dedicated PostgreSQL rollback, manual epoch rotation, Flutter VM HTTP recovery",
            excluded=[
                "production",
                "Linux deployment",
                "attachment bytes",
                "native secure vault",
            ],
        )
        receipt = ROOT / "outputs" / "validation" / "P2" / "recovery-http-receipt.json"
        receipt.parent.mkdir(parents=True, exist_ok=True)
        write_json(receipt, self.evidence)
        print("recovery_http_passed", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--reset-isolated", action="store_true")
    parser.add_argument("--resume-prepared", type=Path)
    args = parser.parse_args()
    run = None
    try:
        url = load_database_url()
        ensure_port_free()
        if args.resume_prepared:
            if args.reset_isolated:
                raise RuntimeError("resume_must_not_reset_database")
            run_dir = safe_run_dir(args.resume_prepared)
            config = json.loads((run_dir / "client-config.json").read_text("utf-8"))
            prepared = json.loads((run_dir / "prepared.json").read_text("utf-8"))
            if config["server"] != SERVER or prepared["database"] != DATABASE:
                raise RuntimeError("resume_configuration_guard_failed")
            if any(run_dir.glob("*.request.json")):
                raise RuntimeError("resume_requires_unused_prepared_run")
        else:
            run_dir = prepare(url, reset=args.reset_isolated)
        print("recovery_prepared " + str(run_dir), flush=True)
        if not args.prepare_only:
            run = RecoveryRun(url, run_dir)
            run.run()
        return 0
    except KeyboardInterrupt:
        print("recovery_interrupted_children_stopping", flush=True)
        return 130
    except Exception as error:  # noqa: BLE001 -- sanitize credential-bearing failures
        # Never print DSNs, arbitrary subprocess output or exception arguments.
        code = str(error) if type(error) is RuntimeError else type(error).__name__
        print("recovery_failed " + code, flush=True)
        return 1
    finally:
        if run:
            stop_owned(run.client)
            run.stop_service()


if __name__ == "__main__":
    raise SystemExit(main())
