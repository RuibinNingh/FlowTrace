"""Prepare or hold one new synthetic P4 browser fixture; never launches a browser.

The default action is a read-only package/port check. `prepare` and `hold` are
explicit coordinator actions. Expectations are loaded from the product's fixed
scenario, not calculated from observed application output.
"""

from __future__ import annotations

import argparse
import hashlib
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
from uuid import UUID, uuid4

sys.path.insert(0, str(Path(__file__).resolve().parent))
from client_harness import (
    DATABASE,
    HOST,
    LIBRARY,
    PORT,
    PRIVATE,
    ROOT,
    WHEEL,
    WHEEL_SHA256,
    configure,
    write_json,
)

# isort: split
# client_harness establishes the fixed, noneditable wheel path before imports.
import uvicorn
from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.models import User, UserSession
from flowtrace_server.auth.service import create_user, issue_session, now
from flowtrace_server.books.models import Book, BookMembership
from flowtrace_server.main import create_app
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.sync.input import parse_push_body
from flowtrace_server.sync.models import SyncEntity
from flowtrace_server.sync.schemas import AccountPayload, BookPayload, CategoryPayload
from flowtrace_server.sync.writer import push_operations
from sqlalchemy import func, select
from sqlalchemy.orm import Session

OUTPUT = ROOT / "outputs/validation/P4"
MANIFEST = OUTPUT / "web-assets-fixture.json"
CREDENTIAL_ROOT = ROOT / "work/flowtrace-dev/assets-ui"
SCENARIO = ROOT / "tests/e2e/client-web/p4_assets_scenario.json"
PURPOSE = "flowtrace-p4-assets-ui-synthetic"
ACCOUNT_KEYS = {
    "cash",
    "eur",
    "fee_account",
    "credit",
    "receivable",
    "payable",
    "unknown_opening",
}


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def render(value, tokens):
    if isinstance(value, str):
        for key, replacement in tokens.items():
            value = value.replace("{" + key + "}", replacement)
        if re.search(r"\{[A-Za-z_][A-Za-z0-9_]*\}", value):
            raise RuntimeError("unknown_scenario_token")
        return value
    if isinstance(value, list):
        return [render(item, tokens) for item in value]
    if isinstance(value, dict):
        return {key: render(item, tokens) for key, item in value.items()}
    return value


def prepare():
    if MANIFEST.exists() and read(MANIFEST).get("state") != "cleaned":
        raise RuntimeError("active_browser_fixture_must_not_be_overwritten")
    scenario_raw = SCENARIO.read_bytes()
    scenario = json.loads(scenario_raw.decode("utf-8-sig"))
    stamp = datetime.now(UTC).astimezone(timezone(timedelta(hours=8)))
    run_id = uuid4()
    tokens = {
        "marker": run_id.hex[:12],
        "today": stamp.date().isoformat(),
        "year_start": f"{stamp.year}-01-01",
    }
    rendered = render(scenario, tokens)
    if rendered.get("purpose") != PURPOSE or rendered.get("version") != 1:
        raise RuntimeError("fixed_browser_scenario_required")
    seed = rendered["seed"]
    accounts = seed["accounts"]
    if (
        set(accounts) != ACCOUNT_KEYS
        or not rendered.get("inputs")
        or not rendered.get("expected")
    ):
        raise RuntimeError("fixed_browser_scenario_required")
    for row in accounts.values():
        if tokens["marker"] not in row["name"]:
            raise RuntimeError("synthetic_marker_required")
        AccountPayload.model_validate({**row["payload"], "name": row["name"]})
    category = {
        "name": seed["expense_category_name"],
        "kind": "expense",
        "parent_id": None,
        "icon": "food",
        "sort_order": 0,
        "archived": False,
    }
    CategoryPayload.model_validate(category)
    BookPayload.model_validate({"name": seed["book_name"], **seed["book_payload"]})
    names = {key: accounts[key]["name"] for key in ACCOUNT_KEYS}
    names.update(book=seed["book_name"], expense_category=seed["expense_category_name"])
    names.update(rendered.get("names", {}))
    if any(tokens["marker"] not in value for value in names.values()):
        raise RuntimeError("synthetic_name_marker_required")
    for key in ACCOUNT_KEYS:
        if names[key] != accounts[key]["name"]:
            raise RuntimeError("scenario_account_name_mismatch")
    runtime = PRIVATE / f"browser-{run_id}"
    runtime.mkdir(parents=True, exist_ok=False)
    private = CREDENTIAL_ROOT / str(run_id)
    private.mkdir(parents=True, exist_ok=False)
    settings, engine = configure(runtime)
    username, password = "p4_ui_" + tokens["marker"], secrets.token_urlsafe(32)
    ids = {key: str(uuid4()) for key in sorted(ACCOUNT_KEYS)}
    ids["expense_category"] = str(uuid4())
    principal = None
    try:
        with Session(engine) as session:
            user = create_user(session, username, password)
            book_id = session.scalar(
                select(BookMembership.book_id).where(
                    BookMembership.user_id == user.id, BookMembership.role == "owner"
                )
            )
            state = session.get(ServerState, 1)
            instance, epoch, user_id = state.instance_id, state.sync_epoch, user.id
            record, _ = issue_session(
                session, user, uuid4(), "合成浏览器种子准备", "api_native"
            )
            principal = Principal(
                user.id, record.id, record.client_id, record.purpose, frozenset()
            )
            original_book = dict(session.get(SyncEntity, book_id).payload)
            revision = str(session.get(SyncEntity, book_id).revision)
            session.commit()
        ids["book"] = str(book_id)
        operations = [
            {
                "operation_id": str(uuid4()),
                "scope_id": str(book_id),
                "entity_type": "book",
                "entity_id": str(book_id),
                "action": "update",
                "base_revision": revision,
                "depends_on": None,
                "payload": {
                    **original_book,
                    **seed["book_payload"],
                    "name": seed["book_name"],
                },
            }
        ]
        for key in sorted(ACCOUNT_KEYS):
            row = accounts[key]
            operations.append(
                {
                    "operation_id": str(uuid4()),
                    "scope_id": str(user_id),
                    "entity_type": "account",
                    "entity_id": ids[key],
                    "action": "create",
                    "base_revision": "0",
                    "depends_on": None,
                    "payload": {**row["payload"], "name": row["name"]},
                }
            )
        operations.append(
            {
                "operation_id": str(uuid4()),
                "scope_id": str(book_id),
                "entity_type": "category",
                "entity_id": ids["expense_category"],
                "action": "create",
                "base_revision": "0",
                "depends_on": None,
                "payload": category,
            }
        )
        raw = json.dumps(
            {
                "protocol_version": 1,
                "client_id": str(principal.client_id),
                "sync_epoch": str(epoch),
                "operations": operations,
            }
        ).encode()
        with Session(engine) as session:
            result = push_operations(session, principal, parse_push_body(raw))
        if any(row["status"] != "applied" for row in result["results"]):
            raise RuntimeError("synthetic_seed_operation_rejected")
        with Session(engine) as session:
            for key in ACCOUNT_KEYS:
                row = session.get(SyncEntity, UUID(ids[key]))
                assert row.scope_id == user_id and not row.deleted
                assert (
                    str(row.balance_minor)
                    == accounts[key]["payload"]["opening"]["amount_minor"]
                )
            session.get(UserSession, principal.session_id).revoked_at = now()
            session.commit()
            active = session.scalar(
                select(func.count())
                .select_from(UserSession)
                .where(UserSession.user_id == user_id, UserSession.revoked_at.is_(None))
            )
            assert active == 0
        credentials = private / "credentials.json"
        write_json(credentials, {"username": username, "password": password})
        manifest = {
            "purpose": PURPOSE,
            "state": "seeded",
            "run_id": str(run_id),
            "api_origin": f"http://{HOST}:{PORT}",
            "instance_id": str(instance),
            "sync_epoch": str(epoch),
            "user_id": str(user_id),
            "database": DATABASE,
            "credentials_path": credentials.relative_to(ROOT).as_posix(),
            "names": names,
            "ids": ids,
            "inputs": rendered["inputs"],
            "expected": rendered["expected"],
            "expected_rows": rendered.get("expected_rows", {}),
            "absent": rendered.get("absent", {}),
            "calculated": rendered.get("calculated", {}),
            "cleanup": rendered.get("cleanup", {}),
            "scenario_order": rendered["scenario_order"],
            "date": stamp.date().isoformat(),
            "scenario_sha256": hashlib.sha256(scenario_raw).hexdigest(),
            "wheel_sha256": WHEEL_SHA256,
        }
        control = {
            "purpose": PURPOSE,
            "run_id": str(run_id),
            "instance_id": str(instance),
            "sync_epoch": str(epoch),
            "user_id": str(user_id),
            "runtime_directory": str(runtime),
            "seed_operation_ids": [row["operation_id"] for row in operations],
            "seed_native_sessions_active": active,
            "backend_data_directory": str(settings.data_directory),
        }
        write_json(private / "server-control.json", control)
        OUTPUT.mkdir(parents=True, exist_ok=True)
        write_json(MANIFEST, manifest)
        print(
            json.dumps(
                {
                    "prepared": True,
                    "run_id": str(run_id),
                    "seed_native_sessions_active": 0,
                    "service_started": False,
                }
            )
        )
    finally:
        # A failed seed leaves synthetic rows for diagnosis, but no active seed session.
        try:
            if principal is not None:
                with Session(engine) as session:
                    record = session.get(UserSession, principal.session_id)
                    if record is not None and record.revoked_at is None:
                        record.revoked_at = now()
                        session.commit()
        finally:
            engine.dispose()


def hold():
    manifest = read(MANIFEST)
    run_id = UUID(manifest["run_id"])
    if (
        manifest["purpose"] != PURPOSE
        or manifest["state"] != "seeded"
        or manifest["api_origin"] != f"http://{HOST}:{PORT}"
        or manifest["wheel_sha256"] != WHEEL_SHA256
    ):
        raise RuntimeError("active_browser_fixture_required")
    private = CREDENTIAL_ROOT / str(run_id)
    control = read(private / "server-control.json")
    if any(
        control[key] != manifest[key]
        for key in ("purpose", "run_id", "instance_id", "sync_epoch", "user_id")
    ):
        raise RuntimeError("fixture_control_identity_mismatch")
    runtime = Path(control["runtime_directory"])
    settings, engine = configure(runtime, migrate=False)
    with Session(engine) as session:
        state = session.get(ServerState, 1)
        user = session.get(User, UUID(manifest["user_id"]))
        book = session.get(Book, UUID(manifest["ids"]["book"]))
        if (
            str(state.instance_id) != manifest["instance_id"]
            or str(state.sync_epoch) != manifest["sync_epoch"]
            or user is None
            or not user.enabled
            or book is None
            or book.deleted
            or book.owner_user_id != user.id
        ):
            raise RuntimeError("database_fixture_identity_mismatch")
    stop = private / "stop.request"
    if stop.exists():
        raise RuntimeError("fixture_stop_already_requested")
    server = uvicorn.Server(
        uvicorn.Config(
            create_app(settings),
            host=HOST,
            port=PORT,
            access_log=False,
            log_level="error",
        )
    )
    thread = Thread(target=server.run, name="flowtrace-owned-p4-ui", daemon=True)
    thread.start()
    try:
        deadline = monotonic() + 15
        while not server.started and thread.is_alive() and monotonic() < deadline:
            sleep(0.025)
        if not server.started:
            raise RuntimeError("owned_ui_service_start_failed")
        logging.getLogger("flowtrace").disabled = True
        write_json(
            private / "service-state.json",
            {"running": True, "pid": os.getpid(), "port": PORT, "run_id": str(run_id)},
        )
        print(
            json.dumps({"running": True, "port": PORT, "run_id": str(run_id)}),
            flush=True,
        )
        while thread.is_alive() and not stop.exists():
            sleep(0.2)
    finally:
        server.should_exit = True
        thread.join(timeout=15)
        engine.dispose()
        write_json(
            private / "service-state.json",
            {"running": False, "port": PORT, "run_id": str(run_id)},
        )
    if thread.is_alive():
        raise RuntimeError("owned_ui_service_did_not_stop")


def main():
    parser = argparse.ArgumentParser(
        description="Explicit isolated P4 browser fixture lifecycle"
    )
    parser.add_argument(
        "action", choices=["check", "prepare", "hold"], default="check", nargs="?"
    )
    args = parser.parse_args()
    if args.action == "prepare":
        prepare()
    elif args.action == "hold":
        hold()
    else:
        assert hashlib.sha256(WHEEL.read_bytes()).hexdigest() == WHEEL_SHA256
        with socket.socket() as probe:
            closed = probe.connect_ex((HOST, PORT)) != 0
        print(
            json.dumps(
                {
                    "fixed_wheel": True,
                    "port_closed": closed,
                    "library": str(LIBRARY.relative_to(ROOT)),
                    "database_mutated": False,
                }
            )
        )


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # noqa: BLE001 -- fixed public error projection without private values
        code = (
            str(error)
            if re.fullmatch(r"[a-z_]{1,100}", str(error))
            else type(error).__name__
        )
        print(f"p4_ui_fixture_failed:{code}; inspect ignored fixture state")
        raise SystemExit(1) from None
