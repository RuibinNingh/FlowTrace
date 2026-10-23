"""Owned loopback group-sync fixture; no migration, reset, browser or phone.

Credentials, images and SQLite stay in ignored work/flowtrace-group/live/UUID.
Default preparation never starts HTTP/Flutter. --seed starts only an owned
short-lived API. --run-flutter additionally requires the team's SDK window.
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
from uuid import UUID, uuid4

ROOT = Path(__file__).resolve().parents[3]
PRIVATE = ROOT / "work/flowtrace-group/live"
HOST, PORT, PG_PORT = "127.0.0.1", 18093, 55432
sys.path.insert(0, str(ROOT / "server/src"))
sys.path.insert(1, str(Path(__file__).resolve().parent))

import httpx
import uvicorn
from flowtrace_server.attachments.models import Attachment
from flowtrace_server.auth.models import User, UserSession
from flowtrace_server.auth.service import create_user, now
from flowtrace_server.books.models import BookMembership, SyncScope
from flowtrace_server.config import Settings
from flowtrace_server.imports.staging_models import (
    ImportPublication,
    ImportPublicationChunk,
    ImportStage,
)
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.main import create_app
from flowtrace_server.persistence.database import build_engine
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.persistence.testing import require_isolated_database
from flowtrace_server.sync.group_models import GroupPullSession
from flowtrace_server.sync.models import LedgerEntry, SyncEntity, SyncReceipt
from flowtrace_server.worker.runtime import Worker
from PIL import Image
from sqlalchemy import func, select, text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import Session


def write_json(path, value):
    if path.exists():
        raise RuntimeError("existing_receipt_preserved")
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write("\n")


def configure(env_file, run, expected_head):
    env_file = env_file.resolve(strict=True)
    trusted = (ROOT / "work/flowtrace-dev/postgresql").resolve()
    if not env_file.is_relative_to(trusted) or not re.fullmatch(
        r"server-p5-restore-[0-9a-f]{32}\.env", env_file.name
    ):
        raise RuntimeError("private_new_uuid_environment_required")
    if not run.resolve().is_relative_to(PRIVATE.resolve()) or run.is_symlink():
        raise RuntimeError("private_run_directory_required")
    values = {}
    for line in env_file.read_text("utf-8-sig").splitlines():
        if line.strip() and not line.lstrip().startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip("\"'")
    url = make_url(values["FLOWTRACE_DATABASE_URL"])
    require_isolated_database(str(url.render_as_string(hide_password=False)), "test")
    if (
        (url.drivername, url.host, url.port, url.username)
        != ("postgresql+psycopg", HOST, PG_PORT, "flowtrace_dev")
        or url.query
        or not url.password
        or not re.fullmatch(r"flowtrace_test_p5_jobs_[0-9a-f]{16}", url.database or "")
        or make_url(values["FLOWTRACE_TEST_DATABASE_URL"]) != url
    ):
        raise RuntimeError("dedicated_database_guard_failed")
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url=values["FLOWTRACE_DATABASE_URL"],
        data_directory=run / "server-data",
        diagnostics_enabled=False,
        allowed_hosts=[HOST],
    )
    engine = build_engine(settings)
    with engine.connect() as connection:
        actual = connection.execute(
            text(
                "SELECT current_database(),host(inet_server_addr()),inet_server_port(),current_user"
            )
        ).one()
        if tuple(actual) != (url.database, HOST, PG_PORT, "flowtrace_dev"):
            raise RuntimeError("actual_database_guard_failed")
        if (
            connection.scalar(text("SELECT version_num FROM alembic_version"))
            != expected_head
        ):
            raise RuntimeError("explicit_database_head_required_no_automatic_migration")
    return settings, engine, url.database


def request(client, method, path, *, token=None, expected=200, **kwargs):
    headers = dict(kwargs.pop("headers", {}))
    if token:
        headers["authorization"] = "Bearer " + token
    response = client.request(method, "/api/v1" + path, headers=headers, **kwargs)
    if response.status_code != expected:
        # Native exception/response bodies can contain private context.
        raise RuntimeError("fixture_http_status_" + str(response.status_code))
    return {} if response.status_code == 204 else response.json()


def login(client, account):
    client_id = str(uuid4())
    result = request(
        client,
        "POST",
        "/auth/login",
        json={
            "username": account["username"],
            "password": account["password"],
            "client_id": client_id,
            "client_kind": "native",
            "device_name": "group-harness-owned",
        },
    )
    return {**result, "harness_client_id": client_id}


def fixture_accounts(engine):
    accounts = {}
    with Session(engine, expire_on_commit=False) as session:
        if session.scalar(select(func.count()).select_from(User)):
            raise RuntimeError("fresh_database_with_no_users_required")
        for role in ("owner", "viewer"):
            password = secrets.token_urlsafe(32)
            username = "group_live_" + role + "_" + uuid4().hex[:12]
            user = create_user(session, username, password)
            book_id = session.scalar(
                select(BookMembership.book_id).where(
                    BookMembership.user_id == user.id, BookMembership.role == "owner"
                )
            )
            accounts[role] = {
                "id": str(user.id),
                "book_id": str(book_id),
                "username": username,
                "password": password,
            }
        session.add(
            BookMembership(
                book_id=UUID(accounts["owner"]["book_id"]),
                user_id=UUID(accounts["viewer"]["id"]),
                role="viewer",
                active=True,
            )
        )
        session.get(SyncScope, UUID(accounts["viewer"]["id"])).permission_version += 1
        session.get(
            SyncScope, UUID(accounts["owner"]["book_id"])
        ).permission_version += 1
        identity = session.get(ServerState, 1)
        info = {
            "instance_id": str(identity.instance_id),
            "sync_epoch": str(identity.sync_epoch),
        }
        session.commit()
    return accounts, info


def run_job(worker, engine, identifier):
    for _ in range(10):
        with Session(engine) as session:
            job = session.get(BackgroundJob, UUID(identifier))
            if job.status == "succeeded":
                return job.result
            if job.status in {"failed", "cancelled"}:
                raise RuntimeError("fixture_production_job_failed")
        if not worker.run_once():
            sleep(0.05)
    raise RuntimeError("fixture_production_job_not_completed")


def seed(client, engine, worker, run, database):
    accounts, identity = fixture_accounts(engine)
    owner, viewer = accounts["owner"], accounts["viewer"]
    tokens = login(client, owner)
    access = tokens["access_token"]
    try:
        cash_id, operation_id = str(uuid4()), str(uuid4())
        client_id = tokens["harness_client_id"]
        result = request(
            client,
            "POST",
            "/sync/push",
            token=access,
            json={
                "protocol_version": 1,
                "client_id": client_id,
                "sync_epoch": identity["sync_epoch"],
                "operations": [
                    {
                        "operation_id": operation_id,
                        "scope_id": owner["id"],
                        "entity_type": "account",
                        "entity_id": cash_id,
                        "action": "create",
                        "base_revision": "0",
                        "depends_on": None,
                        "payload": {
                            "name": "组同步私有现金",
                            "kind": "cash",
                            "opening": {
                                "currency": "CNY",
                                "currency_scale": 2,
                                "amount_minor": "9007199254740993",
                            },
                            "include_in_net_assets": True,
                            "hidden": False,
                        },
                    }
                ],
            },
        )
        if result["results"][0]["status"] != "applied":
            raise RuntimeError("fixture_private_account_not_applied")
        image = io.BytesIO()
        Image.new("RGB", (3, 2), (34, 121, 215)).save(image, format="PNG")
        raw, attachment_id = image.getvalue(), str(uuid4())
        uploaded = request(
            client,
            "POST",
            "/attachments/uploads",
            token=access,
            expected=201,
            json={
                "attachment_id": attachment_id,
                "scope_id": owner["id"],
                "sha256": hashlib.sha256(raw).hexdigest(),
                "size_bytes": len(raw),
                "media_type": "image/png",
            },
        )
        request(
            client,
            "PUT",
            "/attachments/uploads/" + uploaded["upload_id"] + "/content",
            token=access,
            content=raw,
            headers={"content-type": "application/octet-stream"},
        )
        request(
            client,
            "POST",
            "/attachments/uploads/" + uploaded["upload_id"] + "/complete",
            token=access,
        )
        original = client.get(
            "/api/v1/attachments/" + attachment_id + "/content",
            headers={"authorization": "Bearer " + access},
        )
        if original.status_code != 200 or original.content != raw:
            raise RuntimeError("owner_original_download_failed")
        viewer_access = login(client, viewer)["access_token"]
        try:
            request(
                client,
                "GET",
                "/attachments/" + attachment_id,
                token=viewer_access,
                expected=403,
            )
        finally:
            request(
                client,
                "POST",
                "/auth/logout",
                token=viewer_access,
                json={},
                expected=204,
            )
        rows = [
            {
                "source_id": str(uuid4()),
                "entity_type": "bill",
                "scope_id": owner["book_id"],
                "payload": {
                    "bill_type": "expense",
                    "book_id": owner["book_id"],
                    "account_id": cash_id,
                    "money": {
                        "currency": "CNY",
                        "currency_scale": 2,
                        "amount_minor": "125",
                    },
                    "business_date": "2026-10-23",
                    "business_timezone": "Asia/Shanghai",
                    "occurred_at": "2026-10-23T01:02:03.123456+08:00",
                    "note": "真实组行" + str(index),
                },
            }
            for index in range(201)
        ]
        source = json.dumps(
            {
                "format": "flowtrace-data-v1",
                "source_namespace": "group-live-" + uuid4().hex,
                "rows": rows,
            },
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode()
        (run / "source.json").write_bytes(source)
        source_hash = hashlib.sha256(source).hexdigest()
        stage_prefix = "/data-tools/import-stages"
        stage = request(
            client,
            "POST",
            stage_prefix,
            token=access,
            json={
                "stage_id": str(uuid4()),
                "client_id": client_id,
                "sync_epoch": identity["sync_epoch"],
                "format": "flowtrace_json",
                "expected_bytes": len(source),
                "source_sha256": source_hash,
                "mapping": {},
            },
        )
        path = stage_prefix + "/" + stage["stage_id"]
        for index, offset in enumerate(range(0, len(source), 524288)):
            piece = source[offset : offset + 524288]
            request(
                client,
                "PUT",
                path + "/chunks/" + str(index),
                token=access,
                params={"stage_version": 1},
                content=piece,
                headers={
                    "content-type": "application/octet-stream",
                    "x-chunk-sha256": hashlib.sha256(piece).hexdigest(),
                },
            )
        parsed = request(
            client,
            "POST",
            path + "/seal",
            token=access,
            json={
                "stage_version": 1,
                "total_bytes": len(source),
                "source_sha256": source_hash,
            },
        )
        parse_result = run_job(worker, engine, parsed["job_id"])
        preview = request(
            client, "POST", path + "/preview", token=access, json={"stage_version": 1}
        )
        run_job(worker, engine, preview["job_id"])
        ready = request(client, "GET", path, token=access)
        applied = request(
            client,
            "POST",
            path + "/apply",
            token=access,
            json={
                "stage_version": 1,
                "batch_id": stage["batch_id"],
                "preview_hash": ready["preview_hash"],
            },
        )
        applied_result = run_job(worker, engine, applied["job_id"])
        if applied_result != {"code": "import_stage_applied", "created_count": 201}:
            raise RuntimeError("fixture_production_stage_count_wrong")
        return {
            "version": 1,
            "server": f"http://{HOST}:{PORT}",
            "database": database,
            "run_directory": str(run),
            "receipt": str(run / "client-receipt.json"),
            "accounts": accounts,
            **identity,
            "book_id": owner["book_id"],
            "cash_id": cash_id,
            "initial_balance_minor": "9007199254740993",
            "balance_minor": str(9007199254740993 - 201 * 125),
            "bill_count": 201,
            "expense_minor": str(201 * 125),
            "stage_id": stage["stage_id"],
            "source_sha256": source_hash,
            "seed_operation_id": operation_id,
            "private_image": {
                "attachment_id": attachment_id,
                "sha256": hashlib.sha256(raw).hexdigest(),
                "base64": base64.b64encode(raw).decode(),
            },
            "parse_result": parse_result,
        }
    finally:
        request(client, "POST", "/auth/logout", token=access, json={}, expected=204)


def verify(engine, fixture, *, require_logged_out):
    with Session(engine) as session:
        state = session.get(ServerState, 1)
        if (str(state.instance_id), str(state.sync_epoch)) != (
            fixture["instance_id"],
            fixture["sync_epoch"],
        ):
            raise RuntimeError("fixture_server_identity_changed")
        publication = session.get(ImportPublication, UUID(fixture["stage_id"]))
        chunks = session.scalars(
            select(ImportPublicationChunk).where(
                ImportPublicationChunk.publication_id == publication.id
            )
        ).all()
        if publication.chunk_count != len(chunks) or len(chunks) < 2:
            raise RuntimeError("fixture_real_multichunk_required")
        if session.get(SyncEntity, UUID(fixture["cash_id"])).balance_minor != int(
            fixture["balance_minor"]
        ):
            raise RuntimeError("server_balance_changed")
        bill_count = session.scalar(
            select(func.count())
            .select_from(SyncEntity)
            .where(
                SyncEntity.scope_id == UUID(fixture["book_id"]),
                SyncEntity.entity_type == "bill",
                SyncEntity.deleted.is_(False),
            )
        )
        if bill_count != 201:
            raise RuntimeError("server_bill_count_changed")
        if session.scalar(select(func.count()).select_from(SyncReceipt)) != 1:
            raise RuntimeError("unexpected_client_push")
        users = [UUID(account["id"]) for account in fixture["accounts"].values()]
        active = session.scalar(
            select(func.count())
            .select_from(UserSession)
            .where(UserSession.user_id.in_(users), UserSession.revoked_at.is_(None))
        )
        if require_logged_out and active:
            raise RuntimeError("owned_synthetic_sessions_not_logged_out")
        image = session.get(Attachment, UUID(fixture["private_image"]["attachment_id"]))
        if (
            image.scope_id != UUID(fixture["accounts"]["owner"]["id"])
            or image.status != "ready"
        ):
            raise RuntimeError("private_original_scope_changed")
        stage = session.get(ImportStage, publication.stage_id)
        if stage.status != "applied" or stage.source_sha256 != fixture["source_sha256"]:
            raise RuntimeError("formal_stage_state_changed")
        if session.scalar(select(func.count()).select_from(LedgerEntry)) != 201:
            raise RuntimeError("server_posting_count_changed")
    return {
        "formal_publication_chunks": len(chunks),
        "bills": 201,
        "sync_push_receipts": 1,
        "balance_minor": fixture["balance_minor"],
        "active_owned_sessions": active,
        "private_original_preserved": True,
    }


def cleanup(client, engine, fixture, *, groups_available):
    collected = 0
    for account in fixture["accounts"].values():
        tokens = login(client, account)
        try:
            if groups_available:
                listing = request(
                    client, "GET", "/sync/group-pulls", token=tokens["access_token"]
                )
                for row in listing["pulls"]:
                    request(
                        client,
                        "POST",
                        "/sync/group-pulls/" + row["pull_id"] + "/discard",
                        token=tokens["access_token"],
                        json={"client_id": tokens["harness_client_id"]},
                    )
                    collected += 1
        finally:
            request(
                client,
                "POST",
                "/auth/logout",
                token=tokens["access_token"],
                expected=204,
                json={},
            )
    # Failure cleanup may revoke only sessions of the two newly created fixture
    # users. A nonzero count is recorded and never called a normal client logout.
    with Session(engine) as session:
        users = [UUID(value["id"]) for value in fixture["accounts"].values()]
        active = session.scalars(
            select(UserSession)
            .where(UserSession.user_id.in_(users), UserSession.revoked_at.is_(None))
            .with_for_update()
        ).all()
        forced = len(active)
        for row in active:
            row.revoked_at = now()
        session.commit()
        remaining = session.scalar(
            select(func.count())
            .select_from(GroupPullSession)
            .where(
                GroupPullSession.user_id.in_(users),
                GroupPullSession.build_state.contains({"collected": True}).is_not(True),
            )
        )
        if remaining:
            raise RuntimeError("owned_group_handles_not_collected")
    return {
        "handles_collected_during_final_cleanup": collected,
        "forced_owned_session_revocations": forced,
    }


def run_flutter(executable, run, fixture_file):
    from recovery_harness import spawn_owned

    if not executable.is_file():
        raise RuntimeError("explicit_flutter_executable_required")
    environment = dict(os.environ, FLOWTRACE_GROUP_QA_FILE=str(fixture_file))
    child = None
    try:
        with (run / "flutter.log").open("xb") as output:
            child = spawn_owned(
                [
                    str(executable),
                    "--no-version-check",
                    "test",
                    "--no-pub",
                    "test/live/group_http_test.dart",
                    "--reporter=expanded",
                ],
                cwd=ROOT / "apps/flowtrace",
                env=environment,
                stdout=output,
                stderr=output,
            )
            child.wait(timeout=300)
        if child.returncode:
            raise RuntimeError("flutter_group_assertions_failed_private_log_retained")
        receipt = json.loads((run / "client-receipt.json").read_text("utf-8"))
        if receipt.get("verified") is not True:
            raise RuntimeError("verified_client_receipt_required")
        return receipt
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", required=True, type=Path)
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--seed", action="store_true")
    parser.add_argument("--test-group-router", action="store_true")
    parser.add_argument("--run-flutter", action="store_true")
    parser.add_argument(
        "--flutter-path",
        type=Path,
        default=Path("C:/Ruibin_Ningh/app/FlutterSDK/flutter/bin/flutter.bat"),
    )
    parser.add_argument("--fixture", type=Path)
    args = parser.parse_args()
    if args.run_flutter and not (args.seed or args.fixture):
        raise RuntimeError("explicit_seed_or_existing_fixture_required_for_sdk")
    fixture = None
    if args.fixture:
        if args.seed or not args.run_flutter:
            raise RuntimeError("existing_fixture_only_for_explicit_live_run")
        source = args.fixture.resolve(strict=True)
        if (
            not source.is_relative_to(PRIVATE.resolve())
            or source.name != "client-config.json"
        ):
            raise RuntimeError("owned_fixture_path_required")
        fixture = json.loads(source.read_text("utf-8"))
        run = source.parent
        if any((run / role).exists() for role in ("owner", "viewer")):
            raise RuntimeError("prior_native_client_data_preserved_use_fresh_fixture")
    else:
        run = PRIVATE / uuid4().hex
        run.mkdir(parents=True)
    settings, engine, database = configure(args.env_file, run, args.expected_head)
    if not args.seed and not args.run_flutter:
        write_json(
            run / "prepare-receipt.json",
            {
                "database": database,
                "expected_head": args.expected_head,
                "http_started": False,
                "flutter_started": False,
                "migrated": False,
            },
        )
        engine.dispose()
        print("group_harness_prepared_no_server_or_sdk")
        return
    with socket.socket() as probe:
        if probe.connect_ex((HOST, PORT)) == 0:
            raise RuntimeError("owned_port_already_occupied")
    app = create_app(settings)
    # FastAPI may retain included routers lazily; their top-level route wrappers
    # have no path. The actual exported operation map resolves those routers.
    paths = set(app.openapi()["paths"])
    group_main_mounted = "/api/v1/sync/group-pulls" in paths
    if not group_main_mounted and args.test_group_router:
        from flowtrace_server.sync.group_router import router

        app.include_router(router)
    stage_test_only = "/api/v1/data-tools/import-stages" not in paths
    if stage_test_only:
        from flowtrace_server.imports.staging_router import router

        app.include_router(router)
    logging.getLogger("flowtrace").disabled = True
    worker = Worker(engine, settings)
    server = uvicorn.Server(
        uvicorn.Config(
            app, host=HOST, port=PORT, access_log=False, log_level="critical"
        )
    )
    thread = Thread(target=server.run, daemon=True)
    public_receipt = None
    try:
        thread.start()
        deadline = monotonic() + 15
        while not server.started and thread.is_alive() and monotonic() < deadline:
            sleep(0.02)
        if not server.started:
            raise RuntimeError("owned_server_start_failed")
        logging.getLogger("flowtrace").disabled = True
        with httpx.Client(base_url=f"http://{HOST}:{PORT}", timeout=8) as client:
            if fixture is None:
                fixture = seed(client, engine, worker, run, database)
            elif (
                fixture["database"] != database
                or fixture["expected_head"] != args.expected_head
            ):
                raise RuntimeError("exact_fixture_environment_required")
        fixture.update(
            group_main_mounted=group_main_mounted,
            stage_test_only=stage_test_only,
            environment_file=str(args.env_file.resolve()),
            expected_head=args.expected_head,
        )
        fixture_file = run / (
            "client-config-live-" + uuid4().hex + ".json"
            if args.fixture
            else "client-config.json"
        )
        write_json(fixture_file, fixture)
        if args.seed:
            write_json(
                run / "server-seed-receipt.json",
                verify(engine, fixture, require_logged_out=True),
            )
        if args.run_flutter:
            with httpx.Client(base_url=f"http://{HOST}:{PORT}", timeout=8) as client:
                info = request(client, "GET", "/server-info")
            if not group_main_mounted or "group-sync-v1" not in info["capabilities"]:
                raise RuntimeError("genuine_production_main_group_capability_required")
            received = run_flutter(args.flutter_path, run, fixture_file)
            public_receipt = {
                "client": received,
                "postgresql": verify(engine, fixture, require_logged_out=True),
            }
        else:
            print("group_harness_real_stage_seed_verified_no_sdk")
    finally:
        try:
            if fixture is not None and server.started:
                with httpx.Client(
                    base_url=f"http://{HOST}:{PORT}", timeout=8
                ) as client:
                    cleaning = cleanup(
                        client,
                        engine,
                        fixture,
                        groups_available=group_main_mounted or args.test_group_router,
                    )
                if public_receipt is not None:
                    public_receipt["cleanup"] = cleaning
                    if cleaning["forced_owned_session_revocations"]:
                        raise RuntimeError(
                            "client_did_not_normally_logout_own_sessions"
                        )
        finally:
            server.should_exit = True
            thread.join(15)
            if thread.is_alive():
                server.force_exit = True
                thread.join(5)
            worker.close()
            engine.dispose()
            if thread.is_alive():
                raise RuntimeError("owned_server_not_closed")
    if public_receipt is not None:
        public_receipt["owned_server_thread_stopped"] = True
        write_json(run / "public-receipt.json", public_receipt)
        print("group_harness_real_clients_verified_and_owned_service_stopped")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # noqa: BLE001 - keep native errors/DSN/response out of public output
        code = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        if not re.fullmatch(r"[A-Za-z0-9_]+", code):
            code = "private_failure"
        print("group_harness_stopped_" + code, file=sys.stderr)
        raise SystemExit(1) from None
