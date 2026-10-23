"""Installed P4 wheel, real loopback HTTP, synthetic data and one guarded database.

Run from the repository root with Python -I -S. No production install, browser,
phone, reset/drop or live 18080 action occurs. Secrets are read in-process only.
"""

from __future__ import annotations

import hashlib
import json
import secrets
import socket
import sys
from pathlib import Path
from threading import Thread
from time import monotonic, sleep
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from uuid import uuid4
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[3]
LIBRARY = ROOT / "server/.wheel-assets-venv/Lib/site-packages"
WHEEL = ROOT / "server/dist/assets/flowtrace_server-0.1.0-py3-none-any.whl"
PRIVATE = ROOT / "work/flowtrace-assets/http"
ENV = ROOT / "work/flowtrace-dev/postgresql/server-assets.env"
DATABASE, HOST, PORT = "flowtrace_test_assets_local", "127.0.0.1", 18085
sys.path.insert(0, str(LIBRARY))

from datetime import UTC

import flowtrace_server
import uvicorn
from alembic import command
from flowtrace_server.auth.models import UserSession
from flowtrace_server.auth.service import create_user, issue_session
from flowtrace_server.books.models import BookMembership
from flowtrace_server.config import Settings
from flowtrace_server.main import create_app
from flowtrace_server.persistence.database import build_engine, migration_config
from flowtrace_server.persistence.testing import require_isolated_database
from sqlalchemy import func, select, text
from sqlalchemy.orm import Session


def money(amount, currency="CNY"):
    return {"currency": currency, "currency_scale": 2, "amount_minor": str(amount)}


def main():
    if not Path(flowtrace_server.__file__).resolve().is_relative_to(LIBRARY.resolve()):
        raise RuntimeError("installed_wheel_required")
    direct = json.loads(
        next(LIBRARY.glob("flowtrace_server-*.dist-info/direct_url.json")).read_text()
    )
    if direct.get("dir_info", {}).get("editable") or "archive_info" not in direct:
        raise RuntimeError("noneditable_wheel_required")
    with ZipFile(WHEEL) as archive:
        members = [
            name
            for name in archive.namelist()
            if name.startswith("flowtrace_server/") and not name.endswith("/")
        ]
        assert members and all(
            (LIBRARY / name).read_bytes() == archive.read(name) for name in members
        )
    values = {}
    for line in ENV.read_text(encoding="utf-8-sig").splitlines():
        if line.strip() and not line.lstrip().startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip("\"'")
    url = require_isolated_database(values["FLOWTRACE_DATABASE_URL"], "test")
    if (
        url.database != DATABASE
        or url.host != HOST
        or url.port != 55432
        or url.username != "flowtrace_dev"
    ):
        raise RuntimeError("dedicated_database_guard_failed")
    if values["FLOWTRACE_TEST_DATABASE_URL"] != values["FLOWTRACE_DATABASE_URL"]:
        raise RuntimeError("dedicated_database_guard_failed")
    with socket.socket() as probe:
        if probe.connect_ex((HOST, PORT)) == 0:
            raise RuntimeError("owned_port_already_in_use")
    PRIVATE.mkdir(parents=True, exist_ok=True)
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url=values["FLOWTRACE_DATABASE_URL"],
        data_directory=PRIVATE,
        diagnostics_enabled=False,
        allowed_hosts=[HOST],
    )
    engine = build_engine(settings)
    with engine.begin() as connection:
        assert connection.scalar(text("SELECT current_user")) == "flowtrace_dev"
        config = migration_config()
        config.attributes["connection"] = connection
        command.upgrade(config, "head")
        assert connection.scalar(text("SELECT version_num FROM alembic_version")) == (
            "0006_assets_currencies"
        )
    actors = []
    with Session(engine) as session:
        for _ in range(2):
            user = create_user(
                session, "assets_http_" + uuid4().hex, secrets.token_urlsafe(32)
            )
            client_id = uuid4()
            _, tokens = issue_session(
                session, user, client_id, "合成P4 HTTP", "api_native"
            )
            book_id = session.scalar(
                select(BookMembership.book_id).where(
                    BookMembership.user_id == user.id, BookMembership.role == "owner"
                )
            )
            actors.append(
                {
                    "user": user.id,
                    "client": client_id,
                    "book": book_id,
                    "token": tokens["access_token"],
                }
            )
        session.commit()
    app = create_app(settings)
    server = uvicorn.Server(
        uvicorn.Config(app, host=HOST, port=PORT, access_log=False, log_level="error")
    )
    thread = Thread(target=server.run, name="flowtrace-owned-assets-http", daemon=True)
    thread.start()
    checks, owner, stranger = [], actors[0], actors[1]

    def http(method, path, body=None, who=owner):
        headers = {"Content-Type": "application/json"}
        if who:
            headers["Authorization"] = "Bearer " + who["token"]
        request = Request(
            f"http://{HOST}:{PORT}{path}",
            method=method,
            headers=headers,
            data=None if body is None else json.dumps(body).encode(),
        )
        try:
            response = urlopen(request, timeout=15)
        except HTTPError as error:
            response = error
        with response:
            raw = response.read(8 * 1024 * 1024 + 1)
            assert len(raw) <= 8 * 1024 * 1024
            return response.status, json.loads(raw) if raw else None

    def ok(name, method, path, body=None, who=owner):
        status, data = http(method, path, body, who)
        assert status == 200, (name, status)
        checks.append(name)
        return data

    def synced(kind, scope, payload, identifier=None, action="create", revision="0"):
        identifier = identifier or uuid4()
        body = {
            "protocol_version": 1,
            "client_id": str(owner["client"]),
            "sync_epoch": info["sync_epoch"],
            "operations": [
                {
                    "operation_id": str(uuid4()),
                    "scope_id": str(scope),
                    "entity_type": kind,
                    "entity_id": str(identifier),
                    "action": action,
                    "base_revision": revision,
                    "depends_on": None,
                    "payload": payload,
                }
            ],
        }
        result = ok("sync_" + kind + "_" + action, "POST", "/api/v1/sync/push", body)[
            "results"
        ][0]
        assert result["status"] == "applied", result.get("error", {}).get("code")
        return identifier

    def config_body(revision, **extra):
        return {
            "operation_id": str(uuid4()),
            "client_id": str(owner["client"]),
            "instance_id": info["instance_id"],
            "sync_epoch": info["sync_epoch"],
            "base_revision": str(revision),
            **extra,
        }

    def account_body(kind, amount, currency="CNY", **extra):
        return {
            "name": "合成P4账户",
            "kind": kind,
            "opening": money(amount, currency),
            "include_in_net_assets": True,
            "hidden": False,
            "opening_date": "2026-01-01",
            **extra,
        }

    try:
        deadline = monotonic() + 10
        while not server.started and thread.is_alive() and monotonic() < deadline:
            sleep(0.025)
        assert server.started and thread.is_alive()
        ok("ready", "GET", "/health/ready", who=None)
        info = ok("server_info", "GET", "/api/v1/server-info", who=None)
        assert {"assets-v1", "currencies-v1"}.issubset(info["capabilities"])
        schema = ok("actual_openapi", "GET", "/openapi.json", who=None)
        assert (
            len(schema["paths"]) == 41 and len(schema["components"]["schemas"]) == 112
        )
        catalog = ok("catalog", "GET", "/api/v1/currencies/catalog")
        assert len(catalog["currencies"]) == 165
        bank = ok("banks", "GET", "/api/v1/assets/banks?q=cmb")
        assert bank["banks"] == [{"id": "cmb", "name": "招商银行"}]
        assert (
            len(ok("providers", "GET", "/api/v1/assets/providers")["providers"]) == 39
        )
        group_id = uuid4()
        frozen_group = config_body(
            0, group={"id": str(group_id), "name": "合成组", "sort_order": 0}
        )
        group = ok("group_create", "POST", "/api/v1/assets/groups", frozen_group)
        assert group["revision"] == "1"
        first = synced(
            "account",
            owner["user"],
            account_body("bank", 100000, group_id=str(group_id)),
        )
        second = synced(
            "account",
            owner["user"],
            account_body("investment", 0, "EUR", provider_id="fund"),
        )
        credit = synced(
            "account",
            owner["user"],
            account_body(
                "credit_card",
                -10000,
                credit={
                    "limit": money(20000),
                    "statement_day": 15,
                    "due_mode": "fixed_day",
                    "due_day": 5,
                },
            ),
        )
        ok(
            "preferences",
            "PUT",
            "/api/v1/currencies/preferences",
            config_body(
                1,
                preferences={
                    "base_currency": "CNY",
                    "enabled_codes": ["CNY", "EUR"],
                    "valuation_policy": "latest_on_or_before",
                },
            ),
        )
        rate_id = uuid4()
        rate_fields = {
            "id": str(rate_id),
            "from_currency": "EUR",
            "to_currency": "CNY",
            "effective_date": "2026-10-21",
            "rate": "8",
            "rate_source": "manual",
        }
        frozen_rate = config_body(2, rate=rate_fields)
        saved = ok("valuation_rate", "POST", "/api/v1/currencies/rates", frozen_rate)
        assert saved == ok(
            "valuation_rate_replay", "POST", "/api/v1/currencies/rates", frozen_rate
        )
        bill_id = synced(
            "bill",
            owner["book"],
            {
                "bill_type": "transfer",
                "book_id": str(owner["book"]),
                "money": money(10000),
                "from_account_id": str(first),
                "to_account_id": str(second),
                "target_money": money(1250, "EUR"),
                "business_date": "2026-10-21",
                "business_timezone": "Asia/Shanghai",
                "note": "合成冻结汇率",
                "transfer_fx": {
                    "rate": "0.125",
                    "rate_date": "2026-10-21",
                    "rate_source": "manual",
                },
            },
        )
        overview = ok(
            "current_overview", "GET", "/api/v1/assets/overview?as_of=2026-10-21"
        )
        assert overview["available"] and overview["totals"]["net_minor"] == "90000"
        entries = ok(
            "private_entries",
            "GET",
            f"/api/v1/assets/accounts/{first}/entries"
            "?start_date=2026-10-01&end_date_exclusive=2026-11-01",
        )
        assert entries["entries"][0]["money"]["amount_minor"] == "-10000"
        calendar = ok(
            "credit_calendar",
            "GET",
            f"/api/v1/assets/accounts/{credit}/credit-calendar"
            "?start_date=2026-10-01&end_date_exclusive=2026-11-01",
        )
        assert (
            calendar["total_debt_minor"] == "10000"
            and calendar["opening_carry_minor"] == "10000"
        )
        assert calendar["cycles"][0]["statement_due_minor"] == "0"
        history = ok(
            "historical_curve",
            "GET",
            "/api/v1/assets/history?start_date=2026-10-21"
            "&end_date_exclusive=2026-10-23",
        )
        assert all(
            row["available"] and row["totals"]["net_minor"] == "90000"
            for row in history["points"]
        )
        assert (
            http(
                "GET",
                f"/api/v1/assets/overview?as_of=2026-10-21&scope_id={owner['user']}",
                who=stranger,
            )[0]
            == 403
        )
        checks.append("foreign_scope_rejected")
        assert (
            http("DELETE", f"/api/v1/assets/groups/{group_id}", config_body(3))[0]
            == 409
        )
        checks.append("nonempty_group_delete_rejected")
        assert (
            ok("old_group_replay", "POST", "/api/v1/assets/groups", frozen_group)
            == group
        )
        frozen = ok(
            "frozen_bill_before_rate_change",
            "GET",
            f"/api/v1/sync/entities/bill/{bill_id}?scope_id={owner['book']}",
        )
        ok(
            "delete_valuation",
            "DELETE",
            f"/api/v1/currencies/rates/{rate_id}",
            config_body(3),
        )
        new_rate_id = uuid4()
        ok(
            "new_valuation",
            "POST",
            "/api/v1/currencies/rates",
            config_body(4, rate={**rate_fields, "id": str(new_rate_id), "rate": "9"}),
        )
        changed = ok(
            "changed_valuation_only", "GET", "/api/v1/assets/overview?as_of=2026-10-21"
        )
        assert changed["totals"]["net_minor"] == "91250"
        unchanged = ok(
            "frozen_bill_after_rate_change",
            "GET",
            f"/api/v1/sync/entities/bill/{bill_id}?scope_id={owner['book']}",
        )
        assert unchanged == frozen
        assert unchanged["editable_payload"]["target_money"]["amount_minor"] == "1250"
        synced("bill", owner["book"], {}, bill_id, "delete", "1")
        for identifier in (first, second, credit):
            current = ok(
                "account_current_before_cleanup",
                "GET",
                f"/api/v1/sync/entities/account/{identifier}?scope_id={owner['user']}",
            )
            synced(
                "account",
                owner["user"],
                {},
                identifier,
                "delete",
                current["event"]["revision"],
            )
        ok(
            "delete_empty_group",
            "DELETE",
            f"/api/v1/assets/groups/{group_id}",
            config_body(5),
        )
        ok(
            "delete_final_valuation",
            "DELETE",
            f"/api/v1/currencies/rates/{new_rate_id}",
            config_body(6),
        )
        for who in actors:
            assert http("POST", "/api/v1/auth/logout", who=who)[0] in {200, 204}
        checks.append("synthetic_sessions_logout")
        with engine.connect() as connection:
            active = connection.scalar(
                select(func.count())
                .select_from(UserSession)
                .where(
                    UserSession.user_id.in_([row["user"] for row in actors]),
                    UserSession.revoked_at.is_(None),
                )
            )
        assert active == 0
    finally:
        # Even a failed assertion cannot leave the private service or QA sessions live.
        try:
            with engine.begin() as connection:
                from datetime import datetime

                connection.execute(
                    UserSession.__table__.update()
                    .where(
                        UserSession.user_id.in_([row["user"] for row in actors]),
                        UserSession.revoked_at.is_(None),
                    )
                    .values(revoked_at=datetime.now(UTC))
                )
        finally:
            server.should_exit = True
            thread.join(10)
            engine.dispose()
    assert not thread.is_alive()
    receipt = {
        "passed": True,
        "environment": "Windows/Python3.12/PostgreSQL18.6",
        "database": DATABASE,
        "port": PORT,
        "wheel_sha256": hashlib.sha256(WHEEL.read_bytes()).hexdigest(),
        "wheel_bytes": WHEEL.stat().st_size,
        "package_files_verified": len(members),
        "openapi": {"paths": 41, "schemas": 112, "operations": 47},
        "http_checks": checks,
        "owned_service_thread_stopped": True,
        "active_synthetic_sessions": active,
        "changed_live_18080": False,
        "migration": "0006_assets_currencies",
    }
    output = ROOT / "outputs/validation/P4/assets-wheel-http-receipt.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(
        json.dumps(
            {"passed": True, "http_checks": len(checks), "service_stopped": True}
        )
    )


if __name__ == "__main__":
    main()
