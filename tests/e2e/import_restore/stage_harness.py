"""Fresh owned stage TCP fixtures; preparation never starts HTTP or Flutter.

Only an explicit --migrate-fresh upgrades an actually empty new UUID database.
The ordinary production main/capabilities and actual Worker are used. No router
is injected, personal data opened, old database reset or SDK invoked here.
"""

from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import io
import json
import logging
import re
import secrets
import socket
import sys
from pathlib import Path
from threading import Event, Thread
from time import monotonic, sleep
from uuid import UUID, uuid4, uuid5

ROOT = Path(__file__).resolve().parents[3]
PRIVATE = ROOT / "work/flowtrace-stage/live"
EVIDENCE = ROOT / "outputs/validation/P5/stage-http"
HOST, API_PORT, WEB_PORT = "127.0.0.1", 18094, 18194
HEAD = "0016_backup_quarantine"
PURPOSE = "flowtrace-stage-tcp-normal-client-synthetic-v1"
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAFElEQVR4nGPUaXnNAAZMEIqBgQEAHGMBn0OjIGsAAAAASUVORK5CYII="
)
sys.path.insert(0, str(ROOT / "server/src"))

import httpx
import uvicorn
from alembic import command
from alembic.script import ScriptDirectory
from flowtrace_server.auth.models import User, UserSession
from flowtrace_server.auth.service import create_user
from flowtrace_server.books.models import BookMembership
from flowtrace_server.config import Settings
from flowtrace_server.imports.models import ImportBatch, ImportItem
from flowtrace_server.imports.parsers import canonical
from flowtrace_server.imports.staging_models import (
    ImportPublication,
    ImportPublicationChunk,
    ImportStage,
    ImportStageRequirement,
    ImportStageRow,
    ImportStageSourceRelease,
    ImportStageUploadChunk,
)
from flowtrace_server.imports.staging_parsers import open_stage_source
from flowtrace_server.imports.staging_schemas import StageMapping
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.main import create_app
from flowtrace_server.persistence.database import build_engine, migration_config
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.persistence.testing import require_isolated_database
from flowtrace_server.sync.models import LedgerEntry, SyncEntity, SyncReceipt
from flowtrace_server.sync.schemas import AccountPayload, CategoryPayload
from flowtrace_server.worker.runtime import Worker
from sqlalchemy import func, inspect, select, text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import Session


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as output:
        json.dump(value, output, ensure_ascii=False, indent=2)
        output.write("\n")


def private_path(value, *, name=None):
    path = value.resolve(strict=True)
    if not path.is_relative_to(PRIVATE.resolve()) or (name and path.name != name):
        raise RuntimeError("owned_stage_fixture_path_required")
    return path


def free_ports(*ports):
    for port in ports:
        with socket.socket() as probe:
            if probe.connect_ex((HOST, port)) == 0:
                raise RuntimeError("owned_stage_port_occupied")


def configure(env_file, run, *, migrate_fresh=False):
    path = env_file.resolve(strict=True)
    trusted = (ROOT / "work/flowtrace-dev/postgresql").resolve()
    if not path.is_relative_to(trusted) or not re.fullmatch(
        r"server-p5-restore-[0-9a-f]{32}\.env", path.name
    ):
        raise RuntimeError("private_new_uuid_environment_required")
    values = {}
    for line in path.read_text("utf-8-sig").splitlines():
        if line.strip() and not line.lstrip().startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip("\"'")
    raw = values["FLOWTRACE_DATABASE_URL"]
    url = make_url(raw)
    require_isolated_database(raw, "test")
    if (
        (url.drivername, url.host, url.port, url.username)
        != ("postgresql+psycopg", HOST, 55432, "flowtrace_dev")
        or url.query
        or not url.password
        or not re.fullmatch(r"flowtrace_test_p5_jobs_[0-9a-f]{16}", url.database or "")
        or url.database[-16:] != path.stem.removeprefix("server-p5-restore-")[:16]
        or make_url(values["FLOWTRACE_TEST_DATABASE_URL"]) != url
    ):
        raise RuntimeError("dedicated_stage_database_guard_failed")
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url=raw,
        data_directory=run / "server-data",
        diagnostics_enabled=False,
        allowed_hosts=[HOST],
        cors_origins=[f"http://{HOST}:{WEB_PORT}"],
    )
    engine = build_engine(settings)
    try:
        with engine.connect() as connection:
            actual = connection.execute(
                text(
                    "SELECT current_database(),host(inet_server_addr()),inet_server_port(),current_user"
                )
            ).one()
            if tuple(actual) != (url.database, HOST, 55432, "flowtrace_dev"):
                raise RuntimeError("actual_stage_database_guard_failed")
            tables = inspect(connection).get_table_names(schema="public")
        config = migration_config()
        if ScriptDirectory.from_config(config).get_current_head() != HEAD:
            raise RuntimeError("fixed_source_head16_required")
        if migrate_fresh:
            if tables:
                raise RuntimeError("explicit_migration_requires_new_empty_database")
            with engine.begin() as connection:
                config.attributes["connection"] = connection
                command.upgrade(config, HEAD)
        with engine.connect() as connection:
            if (
                connection.scalar(text("SELECT version_num FROM alembic_version"))
                != HEAD
            ):
                raise RuntimeError("head16_required_no_automatic_upgrade")
        return settings, engine, url.database
    except BaseException:
        engine.dispose()
        raise


def fixture_files(run, run_id):
    directory = run / "inputs"
    directory.mkdir()
    ids = {name: str(uuid4()) for name in ("book", "cash", "source_user", "image")}
    marker, namespace = run_id[:8], "stage-native-" + run_id[:12]
    categories, bills, rows = [], [], []
    for index in range(101):
        category, bill = str(uuid4()), str(uuid4())
        categories.append(category)
        bills.append(bill)
        # Forward references force the real parser/topological writer path.
        rows.extend(
            [
                {
                    "source_id": bill,
                    "entity_type": "bill",
                    "scope_id": ids["book"],
                    "payload": {
                        "bill_type": "expense",
                        "book_id": ids["book"],
                        "account_id": ids["cash"],
                        "category_id": category,
                        "money": {
                            "currency": "CNY",
                            "currency_scale": 2,
                            "amount_minor": "125",
                        },
                        "business_date": "2026-10-23",
                        "business_timezone": "Asia/Shanghai",
                        "source": "import",
                        "note": f"合成跨分片支出-{marker}-{index}",
                        "attachment_ids": [ids["image"]] if index == 0 else [],
                    },
                },
                {
                    "source_id": category,
                    "entity_type": "category",
                    "scope_id": ids["book"],
                    "payload": {
                        "name": f"源餐饮-{marker}-{index}",
                        "kind": "expense",
                        "parent_id": None,
                        "icon": "restaurant",
                        "sort_order": index,
                    },
                },
            ]
        )
    names = {
        "book": "大迁移原账本-" + marker,
        "cash": "大迁移原现金-" + marker,
        "csv_cash": "CSV现金-" + marker,
        "csv_category": "CSV餐饮-" + marker,
    }
    rows.extend(
        [
            {
                "source_id": ids["book"],
                "entity_type": "book",
                "scope_id": ids["source_user"],
                "payload": {
                    "name": names["book"],
                    "currency": "CNY",
                    "timezone": "Asia/Shanghai",
                    "month_start_day": 15,
                },
            },
            {
                "source_id": ids["cash"],
                "entity_type": "account",
                "scope_id": ids["source_user"],
                "payload": {
                    "name": names["cash"],
                    "kind": "cash",
                    "include_in_net_assets": True,
                    "hidden": False,
                    "opening": {
                        "currency": "CNY",
                        "currency_scale": 2,
                        "amount_minor": "9007199254740993",
                    },
                },
            },
        ]
    )
    manifest = {
        "attachment_id": ids["image"],
        "sha256": hashlib.sha256(PNG).hexdigest(),
        "size_bytes": len(PNG),
        "media_type": "image/png",
        "href": f"/api/v1/attachments/{ids['image']}/content",
    }
    document = {
        "format": "flowtrace-data-v1",
        "source_namespace": namespace,
        "rows": rows,
    }
    content = canonical(
        {
            "format": "flowtrace-export-v1",
            "document": document,
            "attachments": [manifest],
        }
    )
    if len(content) >= 600 * 1024:
        raise RuntimeError("synthetic_payload_unexpectedly_large")
    # Valid trailing JSON whitespace changes only the original byte/hash/chunk
    # envelope. Financial fields and their genuine constraints remain intact.
    content += b"\n" + b" " * (600 * 1024 - len(content) - 1)
    with open_stage_source(
        content, "flowtrace_json", StageMapping(), check_budget=lambda: None
    ) as source:
        parsed = list(source.rows)
        if len(parsed) != 204 or any(row.errors or row.row is None for row in parsed):
            raise RuntimeError("actual_native_adapter_fixture_invalid")
    (directory / "native204.json").write_bytes(content)
    (directory / "original77.png").write_bytes(PNG)
    output = io.StringIO(newline="")
    writer = csv.writer(output)
    writer.writerow(["时间", "类型", "金额", "账户1", "分类", "账单图片", "备注"])
    image_name = "https://invalid.example/手选原图.png"
    for index in range(61):
        writer.writerow(
            [
                "2026-10-23 12:34",
                "支出",
                "1.25",
                names["csv_cash"],
                names["csv_category"],
                image_name if index == 0 else "",
                f"CSV合成支出-{marker}-{index}",
            ]
        )
    csv_content = output.getvalue().encode()
    (directory / "qianji61.csv").write_bytes(csv_content)
    return {
        "source_ids": ids,
        "category_source_ids": categories,
        "bill_source_ids": bills,
        "names": names,
        "native_namespace": namespace,
        "native": {
            "path": str(directory / "native204.json"),
            "format": "flowtrace_json",
            "sha256": hashlib.sha256(content).hexdigest(),
            "size_bytes": len(content),
            "chunks": 2,
            "row_count": 204,
            "category_count": 101,
            "bill_count": 101,
            "expense_minor": "12625",
            "initial_balance_minor": "9007199254740993",
            "balance_minor": "9007199254728368",
            "source_user_requirement": {
                "source_key": ids["source_user"],
                "first_line": 204,
            },
        },
        "qianji": {
            "path": str(directory / "qianji61.csv"),
            "format": "qianji_csv",
            "sha256": hashlib.sha256(csv_content).hexdigest(),
            "size_bytes": len(csv_content),
            "row_count": 61,
            "expense_minor": "7625",
            "image_name": image_name,
            "account_name": names["csv_cash"],
            "category_name": names["csv_category"],
        },
        "image": {
            "path": str(directory / "original77.png"),
            "source_id": ids["image"],
            "sha256": manifest["sha256"],
            "size_bytes": 77,
            "media_type": "image/png",
        },
    }


def request(client, method, path, *, token=None, expected=200, **kwargs):
    headers = dict(kwargs.pop("headers", {}))
    if token:
        headers["authorization"] = "Bearer " + token
    response = client.request(method, "/api/v1" + path, headers=headers, **kwargs)
    if response.status_code != expected:
        raise RuntimeError("stage_fixture_http_status_" + str(response.status_code))
    return {} if expected == 204 else response.json()


class Host:
    def __init__(self, settings, engine, *, workers=False):
        self.settings, self.engine, self.workers = settings, engine, workers
        self.stop = Event()
        self.worker = None
        self.worker_thread = None
        self.server = None
        self.thread = None
        self.worker_failed = False
        self.previous_logging_disabled = logging.getLogger("flowtrace").disabled

    def __enter__(self):
        try:
            return self.start()
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise

    def start(self):
        free_ports(API_PORT)
        app = create_app(self.settings)
        paths = app.openapi()["paths"]
        if not {
            "/api/v1/data-tools/import-stages",
            "/api/v1/sync/group-pulls",
        }.issubset(paths):
            raise RuntimeError("genuine_main_stage_and_group_routes_required")
        self.server = uvicorn.Server(
            uvicorn.Config(
                app, host=HOST, port=API_PORT, access_log=False, log_level="critical"
            )
        )
        self.thread = Thread(target=self.server.run, daemon=True)
        self.thread.start()
        deadline = monotonic() + 15
        while (
            not self.server.started
            and self.thread.is_alive()
            and monotonic() < deadline
        ):
            sleep(0.02)
        if not self.server.started:
            raise RuntimeError("owned_stage_server_start_failed")
        logging.getLogger("flowtrace").disabled = True
        with httpx.Client(base_url=f"http://{HOST}:{API_PORT}", timeout=8) as client:
            info = request(client, "GET", "/server-info")
        if not {"group-sync-v1", "import-stages-v1"}.issubset(info["capabilities"]):
            raise RuntimeError("genuine_main_capabilities_required")
        if self.workers:
            self.worker = Worker(self.engine, self.settings)
            self.worker_thread = Thread(target=self.work, daemon=True)
            self.worker_thread.start()
        return self

    def work(self):
        try:
            while not self.stop.is_set():
                if not self.worker.run_once():
                    self.stop.wait(0.1)
        except Exception:  # noqa: BLE001 - never print private SQL/token tracebacks.
            self.worker_failed = True
            self.stop.set()

    def __exit__(self, *args):
        self.stop.set()
        failed = []
        if self.worker_thread:
            self.worker_thread.join(20)
            if self.worker_thread.is_alive():
                failed.append("owned_stage_worker_not_closed")
        try:
            if self.worker and not failed:
                self.worker.close()
        finally:
            if self.server:
                self.server.should_exit = True
            if self.thread:
                self.thread.join(15)
                if self.thread.is_alive():
                    self.server.force_exit = True
                    self.thread.join(5)
                if self.thread.is_alive():
                    failed.append("owned_stage_host_not_closed")
            logging.getLogger("flowtrace").disabled = self.previous_logging_disabled
        if failed and not (args and args[0]):
            raise RuntimeError(failed[0])


def seed(engine, settings, plan):
    run = private_path(Path(plan["run_directory"]))
    if (run / "client-config.json").exists():
        raise RuntimeError("existing_stage_fixture_preserved")
    with Session(engine, expire_on_commit=False) as session:
        if session.scalar(select(func.count()).select_from(User)):
            raise RuntimeError("fresh_stage_fixture_with_zero_users_required")
        username, password = "stage_live_" + uuid4().hex[:16], secrets.token_urlsafe(32)
        user = create_user(session, username, password)
        book = session.scalar(
            select(BookMembership.book_id).where(
                BookMembership.user_id == user.id, BookMembership.role == "owner"
            )
        )
        state = session.get(ServerState, 1)
        account = {
            "id": str(user.id),
            "book_id": str(book),
            "username": username,
            "password": password,
        }
        identity = {
            "instance_id": str(state.instance_id),
            "sync_epoch": str(state.sync_epoch),
        }
        # A failed/crashed seed preserves this private account recovery proof;
        # it never creates another account or resets an existing fixture.
        write(run / "account-private.json", dict(account=account, **identity))
        session.commit()
    with (
        Host(settings, engine),
        httpx.Client(base_url=plan["server"], timeout=8) as client,
    ):
        client_id = str(uuid4())
        logged = request(
            client,
            "POST",
            "/auth/login",
            json={
                "username": username,
                "password": password,
                "client_id": client_id,
                "client_kind": "native",
                "device_name": "stage-owned-fixture-seed",
            },
        )
        token = logged["access_token"]
        cash_id, category_id = str(uuid4()), str(uuid4())
        try:
            operations = [
                {
                    "operation_id": str(uuid4()),
                    "scope_id": account["id"],
                    "entity_type": "account",
                    "entity_id": cash_id,
                    "action": "create",
                    "base_revision": "0",
                    "depends_on": None,
                    "payload": {
                        "name": plan["inputs"]["names"]["csv_cash"],
                        "kind": "cash",
                        "opening": {
                            "currency": "CNY",
                            "currency_scale": 2,
                            "amount_minor": "10000",
                        },
                        "include_in_net_assets": True,
                        "hidden": False,
                    },
                },
                {
                    "operation_id": str(uuid4()),
                    "scope_id": account["book_id"],
                    "entity_type": "category",
                    "entity_id": category_id,
                    "action": "create",
                    "base_revision": "0",
                    "depends_on": None,
                    "payload": {
                        "name": plan["inputs"]["names"]["csv_category"],
                        "kind": "expense",
                        "parent_id": None,
                        "icon": "restaurant",
                        "sort_order": 0,
                    },
                },
            ]
            body = {
                "protocol_version": 1,
                "client_id": client_id,
                "sync_epoch": identity["sync_epoch"],
                "operations": operations,
            }
            write(run / "seed-command-private.json", body)
            result = request(
                client,
                "POST",
                "/sync/push",
                token=token,
                json=body,
            )
            write(run / "seed-result-private.json", result)
            if len(result["results"]) != 2 or any(
                item["status"] != "applied" for item in result["results"]
            ):
                raise RuntimeError("seed_ordinary_writer_rejected")
        finally:
            request(client, "POST", "/auth/logout", token=token, expected=204, json={})
    return finish_seed(plan, account, identity, cash_id, category_id, recovered=False)


def finish_seed(plan, account, identity, cash_id, category_id, *, recovered):
    run = private_path(Path(plan["run_directory"]))
    ids = plan["inputs"]["source_ids"]
    targets = {
        key: str(
            uuid5(UUID(account["id"]), plan["inputs"]["native_namespace"] + ":" + value)
        )
        for key, value in ids.items()
        if key in {"book", "cash"}
    }
    fixture = {
        **plan,
        **identity,
        "account": account,
        "csv_resources": {"cash_id": cash_id, "category_id": category_id},
        "native_targets": targets,
        "genuine_main_stage_and_group": True,
        "client_receipt": str(run / "client-receipt.json"),
    }
    write(run / "client-config.json", fixture)
    write(
        Path(plan["evidence_directory"]) / "seed-receipt.json",
        {
            "database": plan["database"],
            "synthetic_users": 1,
            "ordinary_seed_operations": 2,
            "ordinary_seed_receipt_status": "applied",
            "recovered_after_assertion_failure": recovered,
            "recovery_financial_writes": False,
            "original_seed_request_body_available": (
                run / "seed-command-private.json"
            ).exists(),
            "recovery_proof": "formal_receipts_and_full_normalized_entities"
            if recovered
            else "actual_http_response",
            "stage_batch_count": 0,
            "host_stopped": True,
            "sdk_started": False,
            "credentials_printed": False,
            "identity": identity,
            "native_targets": targets,
        },
    )
    return run / "client-config.json"


def resume_seed(engine, plan):
    """Recover configuration from already committed receipts, without HTTP/DML."""
    run = private_path(Path(plan["run_directory"]))
    if (run / "client-config.json").exists():
        raise RuntimeError("existing_stage_fixture_preserved")
    saved = json.loads((run / "account-private.json").read_text("utf-8"))
    account = saved["account"]
    owner, book = UUID(account["id"]), UUID(account["book_id"])
    with Session(engine) as session:
        user = session.get(User, owner)
        state = session.get(ServerState, 1)
        identity = {
            "instance_id": str(state.instance_id),
            "sync_epoch": str(state.sync_epoch),
        }
        if (
            session.scalar(select(func.count()).select_from(User)) != 1
            or user is None
            or not user.enabled
            or user.username != account["username"]
            or any(saved[key] != value for key, value in identity.items())
            or session.scalar(
                select(BookMembership.role).where(
                    BookMembership.book_id == book, BookMembership.user_id == owner
                )
            )
            != "owner"
        ):
            raise RuntimeError("owned_seed_identity_changed")
        if any(
            session.scalar(select(func.count()).select_from(model))
            for model in (ImportStage, ImportBatch, ImportPublication, LedgerEntry)
        ):
            raise RuntimeError("unconsumed_stage_seed_required")
        sessions = list(session.scalars(select(UserSession)))
        receipts = list(session.scalars(select(SyncReceipt)))
        entities = list(session.scalars(select(SyncEntity)))
        if (
            len(sessions) != 1
            or sessions[0].user_id != owner
            or sessions[0].revoked_at is None
            or sessions[0].purpose != "api_native"
            or sessions[0].device_name != "stage-owned-fixture-seed"
            or len(receipts) != 2
            or len(entities) != 3
            or {e.entity_type for e in entities} != {"book", "account", "category"}
            or not any(
                e.id == book
                and e.entity_type == "book"
                and not e.deleted
                and e.revision == 1
                for e in entities
            )
        ):
            raise RuntimeError("exact_closed_seed_state_required")
        expected = {
            "account": AccountPayload.model_validate(
                {
                    "name": plan["inputs"]["names"]["csv_cash"],
                    "kind": "cash",
                    "opening": {
                        "currency": "CNY",
                        "currency_scale": 2,
                        "amount_minor": "10000",
                    },
                    "include_in_net_assets": True,
                    "hidden": False,
                }
            ).model_dump(mode="json"),
            "category": CategoryPayload.model_validate(
                {
                    "name": plan["inputs"]["names"]["csv_category"],
                    "kind": "expense",
                    "parent_id": None,
                    "icon": "restaurant",
                    "sort_order": 0,
                }
            ).model_dump(mode="json"),
        }
        resources = {}
        for receipt in receipts:
            entity = next(
                (e for e in entities if str(e.id) == receipt.result.get("entity_id")),
                None,
            )
            if (
                receipt.user_id != owner
                or receipt.client_id != sessions[0].client_id
                or receipt.status != "applied"
                or receipt.result.get("status") != "applied"
                or receipt.result.get("revision") != "1"
                or str(receipt.operation_id) != receipt.result.get("operation_id")
                or entity is None
                or entity.entity_type not in expected
                or entity.entity_type in resources
                or entity.deleted
                or entity.revision != 1
                or entity.scope_id
                != (owner if entity.entity_type == "account" else book)
                or entity.payload != expected[entity.entity_type]
                or entity.balance_minor
                != (10000 if entity.entity_type == "account" else None)
            ):
                raise RuntimeError("formal_seed_receipt_or_payload_changed")
            resources[entity.entity_type] = str(entity.id)
        if set(resources) != set(expected):
            raise RuntimeError("complete_seed_resources_required")
    return finish_seed(
        plan,
        account,
        identity,
        resources["account"],
        resources["category"],
        recovered=True,
    )


def snapshot_digest(values):
    return hashlib.sha256(
        json.dumps(
            values,
            sort_keys=True,
            ensure_ascii=False,
            separators=(",", ":"),
            default=str,
        ).encode("utf-8")
    ).hexdigest()


def model_snapshot(row, *, excluding=()):
    return {
        column.name: getattr(row, column.name)
        for column in row.__table__.columns
        if column.name not in excluding
    }


def verify(engine, fixture, stage_id=None):
    with Session(engine) as session:
        if stage_id is None:
            result = {
                "stages": session.scalar(select(func.count()).select_from(ImportStage)),
                "batches": session.scalar(
                    select(func.count()).select_from(ImportBatch)
                ),
            }
        else:
            stage = session.get(ImportStage, UUID(stage_id))
            if stage is None or stage.owner_user_id != UUID(fixture["account"]["id"]):
                raise RuntimeError("owned_stage_required")
            if stage.source_sha256 not in {
                fixture["inputs"][key]["sha256"] for key in ("native", "qianji")
            }:
                raise RuntimeError("owned_original_source_required")
            publication = session.get(ImportPublication, stage.id)
            batch = session.get(ImportBatch, stage.batch_id)
            result = {
                "stage_id": str(stage.id),
                "batch_id": str(stage.batch_id),
                "status": stage.status,
                "stage_version": stage.stage_version,
                "source_sha256": stage.source_sha256,
                "received_bytes": stage.received_bytes,
                "received_chunks": stage.received_chunks,
                "source_released": stage.source_released_at is not None,
                "batch_status": batch.status if batch else None,
                "imported_items": session.scalar(
                    select(func.count())
                    .select_from(ImportItem)
                    .where(ImportItem.batch_id == stage.batch_id)
                ),
                "publication_chunks": publication.chunk_count if publication else 0,
                "actual_source_chunks": session.scalar(
                    select(func.count())
                    .select_from(ImportStageUploadChunk)
                    .where(ImportStageUploadChunk.stage_id == stage.id)
                ),
                "actual_preview_rows": session.scalar(
                    select(func.count())
                    .select_from(ImportStageRow)
                    .where(ImportStageRow.stage_id == stage.id)
                ),
                "actual_requirement_rows": session.scalar(
                    select(func.count())
                    .select_from(ImportStageRequirement)
                    .where(ImportStageRequirement.stage_id == stage.id)
                ),
            }
            items = list(
                session.scalars(
                    select(ImportItem)
                    .where(ImportItem.batch_id == stage.batch_id)
                    .order_by(ImportItem.position)
                )
            )
            chunks = list(
                session.scalars(
                    select(ImportPublicationChunk)
                    .where(ImportPublicationChunk.publication_id == stage.id)
                    .order_by(ImportPublicationChunk.chunk_index)
                )
            )
            result["formal_apply_metadata_sha256"] = {
                "batch_except_status": snapshot_digest(
                    model_snapshot(batch, excluding={"status"})
                )
                if batch
                else None,
                "items": snapshot_digest([model_snapshot(item) for item in items]),
                "publication": snapshot_digest(model_snapshot(publication))
                if publication
                else None,
                "chunks": snapshot_digest([model_snapshot(chunk) for chunk in chunks]),
            }
            undo = session.get(ImportPublication, uuid5(stage.id, "undo"))
            result["undo_publication_chunks"] = undo.chunk_count if undo else 0
            audit = session.get(ImportStageSourceRelease, stage.id)
            result["source_release_audit"] = (
                None
                if audit is None
                else {
                    "sha256": snapshot_digest(model_snapshot(audit)),
                    "deleted_source_bytes": audit.deleted_source_bytes,
                    "deleted_source_chunks": audit.deleted_source_chunks,
                    "deleted_preview_rows": audit.deleted_preview_rows,
                    "deleted_requirement_rows": audit.deleted_requirement_rows,
                    "received_bytes_snapshot": audit.received_bytes_snapshot,
                    "received_chunks_snapshot": audit.received_chunks_snapshot,
                    "reserved_bytes_released": audit.reserved_bytes_released,
                }
            )
            if publication and (
                session.scalar(
                    select(func.count())
                    .select_from(ImportPublicationChunk)
                    .where(ImportPublicationChunk.publication_id == publication.id)
                )
                != publication.chunk_count
            ):
                raise RuntimeError("formal_publication_chunk_count_changed")
            target = session.get(SyncEntity, UUID(fixture["native_targets"]["cash"]))
            result["native_cash_balance_minor"] = (
                str(target.balance_minor) if target else None
            )
            result["native_cash_deleted"] = target.deleted if target else None
        result.update(
            sync_push_receipts=session.scalar(
                select(func.count()).select_from(SyncReceipt)
            ),
            ledger_entries=session.scalar(
                select(func.count()).select_from(LedgerEntry)
            ),
            active_owned_sessions=session.scalar(
                select(func.count())
                .select_from(UserSession)
                .where(
                    UserSession.user_id == UUID(fixture["account"]["id"]),
                    UserSession.revoked_at.is_(None),
                )
            ),
        )
    return result


def run_job(engine, settings, fixture, job_id):
    worker = Worker(engine, settings)
    try:
        for _ in range(20):
            with Session(engine) as session:
                job = session.get(BackgroundJob, job_id)
                if (
                    job is None
                    or job.owner_user_id != UUID(fixture["account"]["id"])
                    or job.kind not in {"import_preview", "import_apply"}
                ):
                    raise RuntimeError("owned_stage_job_required")
                if job.status == "succeeded":
                    return {
                        "job_id": str(job.id),
                        "status": job.status,
                        "result": job.result,
                    }
                if job.status in {"failed", "cancelled"}:
                    raise RuntimeError("owned_stage_job_terminal_failure")
            if not worker.run_once():
                sleep(0.1)
        raise RuntimeError("owned_stage_job_not_completed")
    finally:
        worker.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "mode", choices=("prepare", "seed", "resume-seed", "serve", "job", "verify")
    )
    parser.add_argument("--env-file", type=Path)
    parser.add_argument("--migrate-fresh", action="store_true")
    parser.add_argument("--fixture", type=Path)
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--job-id", type=UUID)
    parser.add_argument("--stage-id", type=UUID)
    args = parser.parse_args()
    if args.mode == "prepare":
        if (
            args.fixture
            or args.worker
            or args.job_id
            or args.stage_id
            or not args.env_file
        ):
            raise RuntimeError("closed_prepare_arguments_required")
        free_ports(API_PORT, WEB_PORT)
        run_id = uuid4().hex
        run = PRIVATE / run_id
        run.mkdir(parents=True)
        settings, engine, database = configure(
            args.env_file, run, migrate_fresh=args.migrate_fresh
        )
        try:
            with Session(engine) as session:
                if session.scalar(select(func.count()).select_from(User)):
                    raise RuntimeError("new_empty_stage_database_required")
            plan = {
                "purpose": PURPOSE,
                "version": 1,
                "run_id": run_id,
                "run_directory": str(run),
                "environment_file": str(args.env_file.resolve()),
                "database": database,
                "expected_head": HEAD,
                "server": f"http://{HOST}:{API_PORT}",
                "web_origin": f"http://{HOST}:{WEB_PORT}",
                "profile_directory": str(run / "chrome-profile"),
                "evidence_directory": str(EVIDENCE / run_id),
                "inputs": fixture_files(run, run_id),
            }
            write(run / "fixture-plan.json", plan)
            write(
                EVIDENCE / run_id / "prepare-receipt.json",
                {
                    **plan,
                    "http_started": False,
                    "flutter_started": False,
                    "users_created": False,
                    "explicit_new_empty_migration": args.migrate_fresh,
                },
            )
            print(
                json.dumps(
                    {
                        "prepared": True,
                        "fixture": str(run / "fixture-plan.json"),
                        "database": database,
                        "head": HEAD,
                        "api_started": False,
                        "sdk_started": False,
                    }
                )
            )
        finally:
            engine.dispose()
        return
    if (
        args.env_file
        or args.migrate_fresh
        or not args.fixture
        or args.worker
        and args.mode != "serve"
    ):
        raise RuntimeError("closed_existing_fixture_arguments_required")
    path = private_path(args.fixture)
    fixture = json.loads(path.read_text("utf-8"))
    if fixture.get("purpose") != PURPOSE or fixture.get("expected_head") != HEAD:
        raise RuntimeError("owned_head16_fixture_required")
    run = private_path(Path(fixture["run_directory"]))
    if path.parent != run:
        raise RuntimeError("owned_exact_fixture_directory_required")
    settings, engine, database = configure(Path(fixture["environment_file"]), run)
    if database != fixture["database"]:
        raise RuntimeError("owned_fixture_database_changed")
    try:
        if args.mode in {"seed", "resume-seed"}:
            if path.name != "fixture-plan.json":
                raise RuntimeError("unseeded_fixture_plan_required")
            target = (
                seed(engine, settings, fixture)
                if args.mode == "seed"
                else resume_seed(engine, fixture)
            )
            print(
                json.dumps(
                    {
                        "seeded": True,
                        "private_fixture": str(target),
                        "api_stopped": True,
                        "sdk_started": False,
                        "recovered_configuration_only": args.mode == "resume-seed",
                    }
                )
            )
        elif args.mode == "serve":
            if path.name != "client-config.json":
                raise RuntimeError("seeded_private_fixture_required")
            with Host(settings, engine, workers=args.worker) as host:
                print(
                    "owned_stage_main_ready" + ("_with_worker" if args.worker else ""),
                    flush=True,
                )
                try:
                    while True:
                        if host.worker_failed:
                            raise RuntimeError("owned_stage_worker_failed")
                        sleep(0.2)
                except KeyboardInterrupt:
                    pass
        elif args.mode == "job":
            if path.name != "client-config.json":
                raise RuntimeError("seeded_private_fixture_required")
            if not args.job_id:
                raise RuntimeError("explicit_owned_job_required")
            print(json.dumps(run_job(engine, settings, fixture, args.job_id)))
        else:
            result = verify(
                engine, fixture, str(args.stage_id) if args.stage_id else None
            )
            target = Path(fixture["evidence_directory"]) / (
                "postgresql-" + uuid4().hex + ".json"
            )
            write(target, result)
            print(json.dumps({"verified": True, "receipt": str(target)}))
    finally:
        engine.dispose()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # noqa: BLE001 - native errors may contain a private DSN/response
        code = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        if not re.fullmatch(r"[A-Za-z0-9_]+", code):
            code = "private_failure"
        print("stage_harness_stopped_" + code, file=sys.stderr)
        raise SystemExit(1) from None
