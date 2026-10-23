"""Prepare fresh synthetic account/files; preparation is not browser acceptance.

Requires an already-created empty loopback test database. Never grants CREATEDB,
resets a database, reads personal files, or emits credentials/connection strings.
"""

import argparse
import base64
import csv
import hashlib
import io
import json
import secrets
from pathlib import Path
from uuid import NAMESPACE_URL, UUID, uuid4, uuid5

from alembic import command
from dotenv import dotenv_values
from flowtrace_server.auth.service import create_user
from flowtrace_server.config import Settings
from flowtrace_server.imports.attachment_sources import read_attachment_sources
from flowtrace_server.imports.parsers import canonical, parse_json
from flowtrace_server.imports.qianji_template import TemplateMapping, parse_qianji_csv
from flowtrace_server.persistence.database import build_engine, migration_config
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.persistence.testing import require_isolated_database
from sqlalchemy import inspect, select
from sqlalchemy.orm import Session

ROOT = Path(__file__).resolve().parents[3]
PURPOSE = "flowtrace-data-tools-normal-browser-synthetic"
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAFElEQVR4nGPUaXnNAAZMEIqBgQEAHGMBn0OjIGsAAAAASUVORK5CYII="
)


def money(value):
    return {"currency": "CNY", "currency_scale": 2, "amount_minor": value}


def files_plan(run_id):
    marker = run_id[:8]
    ids = {
        name: str(uuid4())
        for name in (
            "book",
            "cash",
            "category",
            "tag",
            "expense",
            "refund",
            "image",
            "source_user",
        )
    }
    names = {
        "book": "流迹迁移验收-" + marker,
        "cash": "迁移现金-" + marker,
        "category": "迁移餐饮-" + marker,
        "tag": "迁移标签-" + marker,
        "expense_note": "含图合成支出-" + marker,
        "refund_note": "合成退款-" + marker,
        "csv_note": "两笔同额独立账单-" + marker,
    }
    rows = []

    def row(kind, label, payload, scope):
        rows.append(
            {
                "source_id": ids[label],
                "entity_type": kind,
                "scope_id": scope,
                "payload": payload,
            }
        )

    row(
        "book",
        "book",
        {
            "name": names["book"],
            "currency": "CNY",
            "timezone": "Asia/Shanghai",
            "month_start_day": 15,
            "display_mode": "year",
            "show_assets": True,
            "icon": "book",
        },
        ids["book"],
    )
    row(
        "account",
        "cash",
        {
            "name": names["cash"],
            "kind": "cash",
            "include_in_net_assets": True,
            "hidden": False,
            "opening": money("10000"),
        },
        ids["source_user"],
    )
    row(
        "category",
        "category",
        {
            "name": names["category"],
            "kind": "expense",
            "parent_id": None,
            "icon": "restaurant",
            "sort_order": 0,
        },
        ids["book"],
    )
    row("tag", "tag", {"name": names["tag"], "color": "#4C956C"}, ids["book"])
    common = {
        "book_id": ids["book"],
        "account_id": ids["cash"],
        "business_date": "2026-10-23",
        "business_timezone": "Asia/Shanghai",
    }
    row(
        "bill",
        "expense",
        {
            **common,
            "bill_type": "expense",
            "money": money("125"),
            "category_id": ids["category"],
            "tag_ids": [ids["tag"]],
            "attachment_ids": [ids["image"]],
            "note": names["expense_note"],
        },
        ids["book"],
    )
    row(
        "bill",
        "refund",
        {
            **common,
            "bill_type": "refund",
            "money": money("25"),
            "allocations": [
                {
                    "source_bill_id": ids["expense"],
                    "source_amount_minor": "25",
                    "receipt_amount_minor": "25",
                }
            ],
            "note": names["refund_note"],
        },
        ids["book"],
    )
    namespace = "qa-native-" + marker
    envelope = {
        "format": "flowtrace-export-v1",
        "document": {
            "format": "flowtrace-data-v1",
            "source_namespace": namespace,
            "rows": rows,
        },
        "attachments": [
            {
                "attachment_id": ids["image"],
                "sha256": hashlib.sha256(PNG).hexdigest(),
                "size_bytes": len(PNG),
                "media_type": "image/png",
                "href": f"/api/v1/attachments/{ids['image']}/content",
                "authorization": "current_session_and_scope_required",
            }
        ],
        "scope_versions": {},
        "filter": {},
    }
    native = canonical(envelope)
    document = parse_json(native)
    assert len(document.rows) == 6
    assert len(read_attachment_sources(native, "flowtrace_json", document)) == 1
    columns = (
        "时间",
        "分类",
        "二级分类",
        "类型",
        "金额",
        "账户1",
        "账户2",
        "备注",
        "账单图片",
        "账单标记",
        "手续费",
        "优惠券",
        "标签",
    )
    buffer = io.StringIO(newline="")
    writer = csv.DictWriter(buffer, fieldnames=columns)
    writer.writeheader()
    item = {key: "" for key in columns}
    item.update(
        {
            "时间": "2026-10-23 12:00",
            "分类": names["category"],
            "类型": "支出",
            "金额": "1.25",
            "账户1": names["cash"],
            "备注": names["csv_note"],
            "标签": names["tag"],
        }
    )
    writer.writerows([item, item])
    template = buffer.getvalue().encode("utf-8-sig")
    parsed_template = parse_qianji_csv(
        template,
        TemplateMapping(
            scope_id=ids["book"],
            timezone="Asia/Shanghai",
            account_names={names["cash"]: ids["cash"]},
            category_names={names["category"]: ids["category"]},
            tag_names={names["tag"]: ids["tag"]},
        ),
    )
    assert not parsed_template.errors and len(parsed_template.document.rows) == 2
    return ids, names, namespace, native, template


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--api-port", type=int, choices=(18090, 18091), default=18090)
    parser.add_argument("--web-port", type=int, choices=(18190, 18191), default=18190)
    args = parser.parse_args()
    values = dotenv_values(args.env_file)
    raw_url = values.get("FLOWTRACE_TEST_DATABASE_URL")
    url = require_isolated_database(raw_url, values.get("FLOWTRACE_ENVIRONMENT", ""))
    if (url.host, url.port, url.username) != (
        "127.0.0.1",
        55432,
        "flowtrace_dev",
    ) or url.database == "flowtrace_test_p5_local":
        raise SystemExit("fresh_loopback_test_database_required")
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url=raw_url,
        diagnostics_enabled=False,
    )
    engine = build_engine(settings)
    with engine.connect() as connection:
        if inspect(connection).get_table_names(schema="public"):
            raise SystemExit("empty_test_database_required_no_reset_performed")
    with engine.begin() as connection:
        config = migration_config()
        config.attributes["connection"] = connection
        command.upgrade(config, "head")
    run_id = uuid4().hex
    private = ROOT / "work/p5/browser" / run_id
    output = ROOT / "outputs/validation/P5" / run_id
    private.mkdir(parents=True, exist_ok=False)
    output.mkdir(parents=True, exist_ok=False)
    ids, names, namespace, native, template = files_plan(run_id)
    (private / "native.json").write_bytes(native)
    (private / "qianji.csv").write_bytes(template)
    (private / "original.png").write_bytes(PNG)
    username, password = (
        "ft_data_" + run_id[:12],
        "FlowTrace-qa-" + secrets.token_urlsafe(32),
    )
    credentials = private / "browser-auth.json"
    credentials.write_text(
        json.dumps({"username": username, "password": password}), encoding="utf-8"
    )
    with Session(engine) as session:
        user = create_user(session, username, password)
        state = session.scalar(select(ServerState))
        user_id, instance_id, epoch = (
            str(user.id),
            str(state.instance_id),
            str(state.sync_epoch),
        )
        session.commit()
    targets = {
        key: str(uuid5(UUID(user_id), namespace + ":" + source))
        for key, source in ids.items()
        if key not in {"source_user", "image"}
    }
    csv_hash = hashlib.sha256(template).hexdigest()
    manifest = {
        "purpose": PURPOSE,
        "run_id": run_id,
        "state": "prepared_not_browser_verified",
        "api_origin": f"http://127.0.0.1:{args.api_port}",
        "web_origin": f"http://127.0.0.1:{args.web_port}",
        "instance_id": instance_id,
        "sync_epoch": epoch,
        "user_id": user_id,
        "environment_file": str(args.env_file.resolve()),
        "credentials_file": str(credentials),
        "data_directory": str(private / "backend-data"),
        "output_directory": str(output),
        "profile_directory": str(
            ROOT
            / "work/flowtrace-dev/browser-profiles"
            / ("chrome-data-tools-" + run_id)
        ),
        "files": {
            "native": str(private / "native.json"),
            "qianji": str(private / "qianji.csv"),
            "image": str(private / "original.png"),
        },
        "source_ids": ids,
        "native_targets": targets,
        "names": names,
        "native_namespace": namespace,
        "native_sha256": hashlib.sha256(native).hexdigest(),
        "csv_sha256": csv_hash,
        "image_sha256": hashlib.sha256(PNG).hexdigest(),
        "image_bytes": len(PNG),
        "csv_target_ids": [
            str(
                uuid5(
                    UUID(user_id),
                    "qianji-public-template-v10:"
                    + str(
                        uuid5(
                            NAMESPACE_URL, f"qianji-template-v10:{csv_hash}:{position}"
                        )
                    ),
                )
            )
            for position in (2, 3)
        ],
        "expected": {
            "native_balance_minor": "9900",
            "after_csv_balance_minor": "9650",
            "after_csv_undo_balance_minor": "9900",
            "native_created_rows": 6,
            "csv_created_rows": 2,
            "csv_repeat_duplicates": 2,
        },
    }
    destination = output / "browser-fixture.json"
    destination.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    engine.dispose()
    print(
        json.dumps(
            {
                "fixture": str(destination.relative_to(ROOT)),
                "fresh_test_user_created": True,
                "source_rows": 6,
                "csv_rows": 2,
                "browser_acceptance": "not_executed",
                "secrets_printed": False,
            }
        )
    )


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    # CLI failure boundary deliberately excludes SQL driver text containing DSNs.
    except Exception as error:  # noqa: BLE001
        raise SystemExit("fixture_preparation_failed_" + type(error).__name__) from None
