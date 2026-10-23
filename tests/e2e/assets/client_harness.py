"""Real Flutter VM assets client, one installed wheel and an isolated database.

Only loopback18085/flowtrace_test_assets_local are accepted. No reset/drop,
live18080, browser, phone or Docker action is performed. All credentials and
native SQLite/image files remain beneath the ignored per-run work directory.
"""

from __future__ import annotations

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
from datetime import UTC, datetime, timedelta, timezone
from pathlib import Path
from threading import Thread
from time import monotonic, sleep
from urllib.request import urlopen
from uuid import UUID, uuid4
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[3]
LIBRARY = ROOT / "server/.wheel-assets-venv/Lib/site-packages"
WHEEL = ROOT / "server/dist/assets/flowtrace_server-0.1.0-py3-none-any.whl"
WHEEL_SHA256 = "473a0a4289e6635f8e9047dba24910ea8131109fd87f21551a1ff2c5d2345e1c"
PRIVATE = ROOT / "work/flowtrace-assets/live"
ENV = ROOT / "work/flowtrace-dev/postgresql/server-assets.env"
HOST, PG_PORT, PORT, DATABASE = "127.0.0.1", 55432, 18085, "flowtrace_test_assets_local"
FLUTTER = Path("C:/Ruibin_Ningh/app/FlutterSDK/flutter/bin/flutter.bat")
sys.path.insert(0, str(LIBRARY))
sys.path.insert(1, str(ROOT / "tests/e2e/sync"))

import flowtrace_server
import uvicorn
from alembic import command
from flowtrace_server.assets.models import AssetConfigReceipt, AssetConfigState
from flowtrace_server.attachments.models import AttachmentRef
from flowtrace_server.auth.models import UserSession
from flowtrace_server.auth.service import create_user
from flowtrace_server.books.models import BookMembership
from flowtrace_server.config import Settings
from flowtrace_server.main import create_app
from flowtrace_server.persistence.database import build_engine, migration_config
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.persistence.testing import require_isolated_database
from flowtrace_server.sync.models import LedgerEntry, SyncEntity
from PIL import Image
from recovery_harness import spawn_owned
from sqlalchemy import func, select, text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import Session


def write_json(path, value):
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def configure(run, *, migrate=True, require_free_port=True):
    if hashlib.sha256(WHEEL.read_bytes()).hexdigest() != WHEEL_SHA256:
        raise RuntimeError("fixed_wheel_hash_required")
    if not run.resolve().is_relative_to(PRIVATE.resolve()):
        raise RuntimeError("private_directory_guard_failed")
    if not Path(flowtrace_server.__file__).resolve().is_relative_to(LIBRARY.resolve()):
        raise RuntimeError("installed_wheel_required")
    direct = json.loads(
        next(LIBRARY.glob("flowtrace_server-*.dist-info/direct_url.json")).read_text()
    )
    if direct.get("dir_info", {}).get("editable") or "archive_info" not in direct:
        raise RuntimeError("noneditable_wheel_required")
    with ZipFile(WHEEL) as archive:
        for name in archive.namelist():
            if name.startswith("flowtrace_server/") and not name.endswith("/"):
                assert (LIBRARY / name).read_bytes() == archive.read(name)
    values = {}
    for line in ENV.read_text(encoding="utf-8-sig").splitlines():
        if line.strip() and not line.lstrip().startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip("\"'")
    url = require_isolated_database(values["FLOWTRACE_DATABASE_URL"], "test")
    if (
        (url.host, url.port, url.database, url.username)
        != (HOST, PG_PORT, DATABASE, "flowtrace_dev")
        or url.query
        or not url.password
        or make_url(values["FLOWTRACE_TEST_DATABASE_URL"]) != url
    ):
        raise RuntimeError("dedicated_database_guard_failed")
    if require_free_port:
        with socket.socket() as probe:
            if probe.connect_ex((HOST, PORT)) == 0:
                raise RuntimeError("dedicated_port_in_use")
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url=values["FLOWTRACE_DATABASE_URL"],
        data_directory=run / "server-data",
        diagnostics_enabled=False,
        allowed_hosts=[HOST],
        cors_origins=["http://127.0.0.1:18185"],
    )
    engine = build_engine(settings)
    with engine.begin() as connection:
        actual = connection.execute(
            text(
                "SELECT current_database(),host(inet_server_addr()),inet_server_port(),current_user"
            )
        ).one()
        if tuple(actual) != (DATABASE, HOST, PG_PORT, "flowtrace_dev"):
            raise RuntimeError("actual_database_guard_failed")
        if (
            connection.scalar(
                text(
                    "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname=current_database()"
                )
            )
            != "flowtrace_dev"
        ):
            raise RuntimeError("dedicated_database_owner_guard_failed")
        if migrate:
            config = migration_config()
            config.attributes["connection"] = connection
            command.upgrade(config, "head")
        assert connection.scalar(text("SELECT version_num FROM alembic_version")) == (
            "0006_assets_currencies"
        )
    return settings, engine


def fixture(engine, run):
    accounts = {}
    with Session(engine) as session:
        for role in ["owner", "actor"]:
            username = f"assets_live_{role}_{uuid4().hex[:12]}"
            password = secrets.token_urlsafe(32)
            user = create_user(session, username, password)
            book = session.scalar(
                select(BookMembership.book_id).where(
                    BookMembership.user_id == user.id, BookMembership.role == "owner"
                )
            )
            accounts[role] = {
                "id": str(user.id),
                "username": username,
                "password": password,
                "book_id": str(book),
            }
        state = session.get(ServerState, 1)
        info = {
            "instance_id": str(state.instance_id),
            "sync_epoch": str(state.sync_epoch),
        }
        session.commit()
    buffer = io.BytesIO()
    Image.new("RGB", (3, 2), (34, 121, 215)).save(buffer, format="PNG")
    raw = buffer.getvalue()
    config = {
        "version": 1,
        "server": f"http://{HOST}:{PORT}",
        "database": DATABASE,
        "run_directory": str(run),
        "receipt": str(run / "client-receipt.json"),
        "accounts": accounts,
        **info,
        "image": {
            "base64": base64.b64encode(raw).decode(),
            "sha256": hashlib.sha256(raw).hexdigest(),
        },
    }
    write_json(run / "client-config.json", config)
    return config


def verify(engine, client):
    actor = UUID(client["actor_id"])
    with Session(engine) as session:
        for key in ["lost_operation_id", "held_operation_id"]:
            assert (
                session.scalar(
                    select(func.count())
                    .select_from(AssetConfigReceipt)
                    .where(
                        AssetConfigReceipt.user_id == actor,
                        AssetConfigReceipt.operation_id == UUID(client[key]),
                    )
                )
                == 1
            )
        assert session.get(AssetConfigState, actor).revision == 11
        transfer = session.get(SyncEntity, UUID(client["transfer_id"]))
        assert transfer.deleted and transfer.payload["money"]["amount_minor"] == "10000"
        assert transfer.payload["target_money"]["amount_minor"] == "1250"
        assert transfer.payload["transfer_fx"] == {
            "rate": "0.125",
            "rate_date": "2026-10-21",
            "rate_source": "manual",
        }
        assert transfer.payload["fee"]["money"]["amount_minor"] == "25"
        ids = [
            UUID(client[key])
            for key in ("transfer_id", "repayment_id", "expense_id", "shared_bill_id")
        ]
        assert (
            session.scalar(
                select(func.count())
                .select_from(LedgerEntry)
                .where(LedgerEntry.bill_id.in_(ids))
            )
            == 0
        )
        assert (
            session.scalar(
                select(func.count())
                .select_from(AttachmentRef)
                .where(AttachmentRef.bill_id.in_(ids))
            )
            == 0
        )
        for key, balance in [("bank_id", 100000), ("eur_id", 0), ("card_id", -10000)]:
            account = session.get(SyncEntity, UUID(client[key]))
            assert account.deleted and account.balance_minor == balance
        assert session.get(SyncEntity, UUID(client["shared_book_id"])).deleted
    return {
        "unique_config_receipts": True,
        "config_revision": "11",
        "tombstones": True,
        "original_fx_and_both_money_preserved": True,
        "fee_minor": "25",
        "funding_entries_after_normal_deletes": 0,
        "attachment_refs_after_normal_deletes": 0,
        "original_balances_restored": True,
    }


def main():
    stamp = datetime.now(UTC).astimezone(timezone(timedelta(hours=8)))
    run = PRIVATE / (stamp.strftime("%Y%m%d-%H%M%S-") + uuid4().hex[:8])
    run.mkdir(parents=True, exist_ok=False)
    settings, engine = configure(run)
    seeded = fixture(engine, run)
    server = uvicorn.Server(
        uvicorn.Config(
            create_app(settings),
            host=HOST,
            port=PORT,
            access_log=False,
            log_level="error",
        )
    )
    thread = Thread(
        target=server.run, name="flowtrace-owned-assets-client", daemon=True
    )
    child, public = None, None
    thread.start()
    try:
        deadline = monotonic() + 15
        while not server.started and thread.is_alive() and monotonic() < deadline:
            sleep(0.02)
        if not server.started:
            raise RuntimeError("owned_service_start_failed")
        logging.getLogger("flowtrace").disabled = True
        with urlopen(f"http://{HOST}:{PORT}/api/v1/server-info", timeout=5) as response:
            info = json.load(response)
            assert (info["instance_id"], info["sync_epoch"]) == (
                seeded["instance_id"],
                seeded["sync_epoch"],
            )
            assert {"assets-v1", "currencies-v1"}.issubset(info["capabilities"])
        env = dict(os.environ, FLOWTRACE_ASSETS_QA_FILE=str(run / "client-config.json"))
        with (run / "flutter.log").open("wb") as output:
            child = spawn_owned(
                [
                    str(FLUTTER),
                    "--no-version-check",
                    "test",
                    "--no-pub",
                    "test/live/assets_http_test.dart",
                    "--reporter=expanded",
                ],
                cwd=ROOT / "apps/flowtrace",
                env=env,
                stdout=output,
                stderr=output,
            )
            child.wait(timeout=360)
        if child.returncode != 0:
            raise RuntimeError("assets_flutter_assertion_failed")
        client = json.loads((run / "client-receipt.json").read_text("utf-8"))
        database = verify(engine, client)
        with Session(engine) as session:
            active = session.scalar(
                select(func.count())
                .select_from(UserSession)
                .where(
                    UserSession.user_id.in_(
                        [UUID(row["id"]) for row in seeded["accounts"].values()]
                    ),
                    UserSession.revoked_at.is_(None),
                )
            )
        assert active == 0
        public = {
            "passed": True,
            "date": stamp.date().isoformat(),
            "platform": "Windows Flutter VM / file SQLite / native attachment files",
            "server": f"http://{HOST}:{PORT}",
            "database": DATABASE,
            "wheel_sha256": hashlib.sha256(WHEEL.read_bytes()).hexdigest(),
            "client": client,
            "postgresql": database,
            "active_synthetic_sessions": active,
            "harness_changed_live_18080": False,
            "synthetic_fixture_retained_in_dedicated_database": True,
        }
    finally:
        try:
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
            with engine.begin() as connection:
                connection.execute(
                    UserSession.__table__.update()
                    .where(
                        UserSession.user_id.in_(
                            [UUID(row["id"]) for row in seeded["accounts"].values()]
                        ),
                        UserSession.revoked_at.is_(None),
                    )
                    .values(revoked_at=datetime.now(UTC))
                )
        finally:
            server.should_exit = True
            thread.join(timeout=15)
            engine.dispose()
        if thread.is_alive():
            raise RuntimeError("owned_service_did_not_stop")
    assert public is not None
    public["owned_service_thread_stopped"] = True
    public["client_process_exit_code"] = child.returncode
    destination = ROOT / "outputs/validation/P4/assets-client-http-receipt.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    write_json(destination, public)
    print(json.dumps({"passed": True, "client_tests": 1, "service_stopped": True}))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # noqa: BLE001 -- sanitize all errors before public output
        code = (
            str(error)
            if re.fullmatch(r"[a-z_]{1,100}", str(error))
            else type(error).__name__
        )
        print(f"assets_client_harness_failed:{code}; inspect ignored run log")
        raise SystemExit(1) from None
