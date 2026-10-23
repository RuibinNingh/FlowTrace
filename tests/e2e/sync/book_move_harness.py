"""Run the real Flutter book-move client against one dedicated installed wheel.

Only the pre-created flowtrace_test_book_move_local database and loopback 18084
are allowed. No reset/drop, live 18080, browser, phone or Docker operation is
performed. Credentials and image/local-database files stay below ignored work/.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import logging
import os
import re
import secrets
import socket
import sys
from pathlib import Path
from threading import Thread
from time import monotonic, sleep
from urllib.request import urlopen
from uuid import UUID, uuid4
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[3]
PRIVATE = ROOT / "work/flowtrace-book-move"
LIBRARY = ROOT / "server/.wheel-move-venv/Lib/site-packages"
WHEEL = ROOT / "server/dist/move/flowtrace_server-0.1.0-py3-none-any.whl"
ENV_FILE = ROOT / "work/flowtrace-dev/postgresql/server-book-move.env"
HOST, PG_PORT, PORT = "127.0.0.1", 55432, 18084
DATABASE = "flowtrace_test_book_move_local"
FLUTTER = Path("C:/Ruibin_Ningh/app/FlutterSDK/flutter/bin/flutter.bat")

# -I -S prevents an editable source checkout or user site from replacing the
# production wheel. The second path only reuses the owned-process Job helper.
sys.path.insert(0, str(LIBRARY))
sys.path.insert(1, str(Path(__file__).resolve().parent))

import flowtrace_server  # noqa: E402
import uvicorn  # noqa: E402
from alembic import command  # noqa: E402
from flowtrace_server.auth.service import create_user  # noqa: E402
from flowtrace_server.config import Settings  # noqa: E402
from flowtrace_server.persistence.database import (  # noqa: E402
    build_engine,
    migration_config,
)
from flowtrace_server.persistence.testing import require_isolated_database  # noqa: E402
from PIL import Image  # noqa: E402
from recovery_harness import spawn_owned  # noqa: E402
from sqlalchemy import func, select, text  # noqa: E402
from sqlalchemy.engine import make_url  # noqa: E402
from sqlalchemy.orm import Session  # noqa: E402


def write_json(path: Path, data: dict) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(path)


def configure(run_dir: Path):
    if not run_dir.resolve().is_relative_to(PRIVATE.resolve()):
        raise RuntimeError("private_directory_guard_failed")
    if not Path(flowtrace_server.__file__).resolve().is_relative_to(LIBRARY.resolve()):
        raise RuntimeError("installed_wheel_guard_failed")
    direct = json.loads(
        next(LIBRARY.glob("flowtrace_server-*.dist-info/direct_url.json")).read_text()
    )
    checksum = hashlib.sha256(WHEEL.read_bytes()).hexdigest()
    archive = direct.get("archive_info")
    if direct.get("dir_info", {}).get("editable") is True or not isinstance(archive, dict):
        raise RuntimeError("noneditable_wheel_hash_guard_failed")
    recorded_hash = archive.get("hashes", {}).get("sha256")
    if recorded_hash is not None and recorded_hash != checksum:
        raise RuntimeError("noneditable_wheel_hash_guard_failed")
    # uv may write an empty archive_info. Prove every installed package/resource
    # byte against the fixed wheel instead of treating missing metadata as a hash.
    with ZipFile(WHEEL) as package:
        for member in package.namelist():
            if not member.startswith("flowtrace_server/") or member.endswith("/"):
                continue
            installed = (LIBRARY / member).resolve()
            if (
                not installed.is_relative_to(LIBRARY.resolve())
                or not installed.is_file()
                or installed.read_bytes() != package.read(member)
            ):
                raise RuntimeError("installed_package_resource_mismatch")
    values = {}
    for line in ENV_FILE.read_text(encoding="utf-8-sig").splitlines():
        if line.strip() and not line.lstrip().startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip("\"'")
    url = make_url(values["FLOWTRACE_DATABASE_URL"])
    if (
        values.get("FLOWTRACE_ENVIRONMENT") not in {"test", "development"}
        or url.drivername != "postgresql+psycopg"
        or (url.host, url.port, url.database, url.username)
        != (HOST, PG_PORT, DATABASE, "flowtrace_dev")
        or url.query
        or not url.password
        or make_url(values["FLOWTRACE_TEST_DATABASE_URL"]) != url
    ):
        raise RuntimeError("dedicated_database_guard_failed")
    require_isolated_database(url.render_as_string(hide_password=False), "test")
    # The copied local env can say development. Override only this process
    # after proving both URLs target the single explicitly named test database.
    values["FLOWTRACE_ENVIRONMENT"] = "test"
    os.environ.update(values)
    os.environ["FLOWTRACE_DATA_DIRECTORY"] = str(run_dir / "server-data")
    settings = Settings(_env_file=None, diagnostics_enabled=False)
    engine = build_engine(settings)
    with engine.connect() as connection:
        actual = connection.execute(
            text("SELECT current_database(),host(inet_server_addr()),inet_server_port()")
        ).one()
        if tuple(actual) != (DATABASE, HOST, PG_PORT):
            raise RuntimeError("connected_database_guard_failed")
    command.upgrade(migration_config(), "head")
    return settings, engine, checksum


def images() -> list[dict]:
    result = []
    for color in [(34, 121, 215), (242, 190, 89)]:
        encoded = io.BytesIO()
        Image.new("RGB", (3, 2), color).save(encoded, format="PNG")
        raw = encoded.getvalue()
        result.append(
            {
                "base64": base64.b64encode(raw).decode("ascii"),
                "sha256": hashlib.sha256(raw).hexdigest(),
                "size_bytes": len(raw),
            }
        )
    return result


def fixture(engine, run_dir: Path):
    accounts = {}
    with Session(engine) as session:
        for role in ["owner", "actor", "viewer"]:
            username = f"move_http_{role}_{uuid4().hex[:12]}"
            password = secrets.token_urlsafe(32)
            user = create_user(session, username, password)
            accounts[role] = {"username": username, "password": password, "id": str(user.id)}
        session.commit()
    config = {
        "version": 1,
        "server": f"http://{HOST}:{PORT}",
        "database": DATABASE,
        "run_directory": str(run_dir),
        "receipt": str(run_dir / "client-receipt.json"),
        "accounts": accounts,
        "images": images(),
    }
    write_json(run_dir / "client-config.json", config)


def verify_database(engine, receipt: dict, run_dir: Path):
    from flowtrace_server.attachments.models import Attachment, AttachmentRef
    from flowtrace_server.auth.models import UserSession
    from flowtrace_server.sync.models import LedgerEntry, SyncEntity, SyncReceipt

    bill_id = UUID(receipt["bill_id"])
    with Session(engine) as session:
        bill = session.get(SyncEntity, bill_id)
        account = session.get(SyncEntity, UUID(receipt["account_id"]))
        blocked = session.get(SyncEntity, UUID(receipt["blocked_bill_id"]))
        assert bill.scope_id == UUID(receipt["target_book_id"]) and bill.revision == 2
        assert bill.payload["book_id"] == receipt["target_book_id"]
        assert bill.payload["occurred_at"] == "2026-10-20T16:00:00.123456Z"
        assert str(account.balance_minor) == receipt["final_balance_minor"] == "9850"
        assert blocked.scope_id == UUID(receipt["source_book_id"]) and blocked.revision == 1
        entries = list(session.scalars(select(LedgerEntry).where(LedgerEntry.bill_id == bill_id)))
        assert len(entries) == 1 and {row.amount_minor for row in entries} == {-125}
        assert all(row.book_id == bill.scope_id for row in entries)
        assert (
            session.scalar(
                select(func.count())
                .select_from(SyncReceipt)
                .where(SyncReceipt.operation_id == UUID(receipt["operation_id"]))
            )
            == 1
        )
        actual = set(
            session.scalars(
                select(AttachmentRef.attachment_id).where(AttachmentRef.bill_id == bill_id)
            )
        )
        assert actual == {UUID(value) for value in receipt["target_attachment_ids"]}
        for source, target in zip(
            receipt["source_attachment_ids"], receipt["target_attachment_ids"], strict=True
        ):
            old, new = session.get(Attachment, UUID(source)), session.get(Attachment, UUID(target))
            assert old.scope_id == UUID(receipt["source_book_id"])
            assert new.scope_id == UUID(receipt["target_book_id"])
            assert (old.sha256, old.size_bytes, old.media_type) == (
                new.sha256,
                new.size_bytes,
                new.media_type,
            )
            assert new.status == "ready"
        config = json.loads((run_dir / "client-config.json").read_text("utf-8"))
        users = [UUID(row["id"]) for row in config["accounts"].values()]
        active_sessions = session.scalar(
            select(func.count())
            .select_from(UserSession)
            .where(UserSession.user_id.in_(users), UserSession.revoked_at.is_(None))
        )
        assert active_sessions == 0
    return {
        "single_bill_uuid": True,
        "single_move_receipt": True,
        "signed_entries_and_book": True,
        "exact_timestamp": True,
        "attachment_refs_and_hashes": True,
        "revoked_prepared_move_not_applied": True,
        "account_balance_minor": "9850",
        "active_synthetic_sessions": 0,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    run_dir = PRIVATE / uuid4().hex
    run_dir.mkdir(parents=True)
    settings, engine, wheel_hash = configure(run_dir)
    if args.prepare_only:
        engine.dispose()
        print("book_move_database_prepared")
        return
    with socket.socket() as probe:
        probe.settimeout(0.5)
        if probe.connect_ex((HOST, PORT)) == 0:
            raise RuntimeError("dedicated_port_already_occupied")
    fixture(engine, run_dir)
    from flowtrace_server.main import create_app

    app = create_app(settings)
    logging.getLogger("flowtrace").disabled = True
    server = uvicorn.Server(
        uvicorn.Config(app, host=HOST, port=PORT, access_log=False, log_level="critical")
    )
    thread = Thread(target=server.run, daemon=True)
    child = None
    public_receipt = None
    try:
        thread.start()
        deadline = monotonic() + 15
        while not server.started and thread.is_alive() and monotonic() < deadline:
            sleep(0.02)
        if not server.started:
            raise RuntimeError("isolated_service_start_failed")
        # Uvicorn's logging configuration can re-enable existing loggers.
        # Suppress only this private process's optional metadata stream.
        logging.getLogger("flowtrace").disabled = True
        with urlopen(f"http://{HOST}:{PORT}/health/ready", timeout=5) as response:
            assert response.status == 200
        with urlopen(f"http://{HOST}:{PORT}/api/v1/server-info", timeout=5) as response:
            assert "bill-move-v1" in json.load(response)["capabilities"]
        env = dict(os.environ, FLOWTRACE_BOOK_MOVE_QA_FILE=str(run_dir / "client-config.json"))
        with (run_dir / "flutter.log").open("wb") as output:
            child = spawn_owned(
                [
                    str(FLUTTER),
                    "--no-version-check",
                    "test",
                    "--no-pub",
                    "test/live/book_move_http_test.dart",
                    "--reporter=expanded",
                ],
                cwd=ROOT / "apps/flowtrace",
                env=env,
                stdout=output,
                stderr=output,
            )
            child.wait(timeout=360)
        if child.returncode != 0:
            raise RuntimeError("book_move_flutter_assertion_failed")
        client_receipt = json.loads((run_dir / "client-receipt.json").read_text("utf-8"))
        database_receipt = verify_database(engine, client_receipt, run_dir)
        public_receipt = {
            "passed": True,
            "platform": "Windows Flutter VM / file SQLite / native attachment files",
            "server": f"http://{HOST}:{PORT}",
            "database": DATABASE,
            "wheel_sha256": wheel_hash,
            "client": client_receipt,
            "postgresql": database_receipt,
            "synthetic_fixture_retained_in_dedicated_database": True,
            "harness_changed_live_18080": False,
        }
    finally:
        if child is not None:
            job = getattr(child, "_flowtrace_owned_job", None)
            if child.poll() is None:
                if job is not None:
                    job.terminate()
                else:
                    child.terminate()
                child.wait(timeout=15)
            if job is not None:
                job.close()
        server.should_exit = True
        thread.join(timeout=15)
        engine.dispose()
        if thread.is_alive():
            raise RuntimeError("owned_service_did_not_stop")
    # Publish success only after the owned process, service and database handles
    # have all closed. A cleanup failure must not leave a fresh passed receipt.
    assert public_receipt is not None
    public_receipt["owned_service_thread_stopped"] = True
    public_receipt["client_process_exit_code"] = child.returncode
    output = ROOT / "outputs/validation/P3/book-move-http-receipt.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    write_json(output, public_receipt)
    print("book_move_client_http_passed")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # SQL URLs and synthetic login bodies must never enter public output.
        code = str(error) if re.fullmatch(r"[a-z_]{1,100}", str(error)) else type(error).__name__
        print(f"book_move_harness_failed:{code}; inspect ignored run logs")
        raise SystemExit(1) from None
