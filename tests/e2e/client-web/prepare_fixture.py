"""Synthetic UI-test data only; this is preparation, never browser acceptance.

The sole target is the existing loopback 18080 development service. Credentials
and tokens are never printed or written into the public/synthetic manifest.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import re
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from uuid import UUID, uuid4

ROOT = Path(__file__).resolve().parents[3]
BASE = "http://127.0.0.1:18080"
CREDENTIALS = ROOT / "work/flowtrace-dev/client-auth-qa.json"
MANIFEST = ROOT / "outputs/validation/P3/web-fixture.json"
PURPOSE = "flowtrace-p3-web-synthetic"
PREFIX = "FT浏览器-P3-"
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAFElEQVR4nGPUaXnNAAZMEIqBgQEAHGMBn0OjIGsAAAAASUVORK5CYII="
)


class FixtureFailure(Exception):
    """Only safe, constant diagnostics reach stdout/stderr."""


def write_manifest(value: dict) -> None:
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    temporary = MANIFEST.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(MANIFEST)


def request(path: str, method="GET", body=None, *, token=None, binary=False):
    if not path.startswith("/") or path.startswith("//"):
        raise FixtureFailure("invalid_local_path")
    headers = {}
    if token:
        headers["Authorization"] = "Bearer " + token
    data = None
    if body is not None:
        if binary:
            data = body
            headers["Content-Type"] = "image/png"
        else:
            data = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode()
            headers["Content-Type"] = "application/json"
    try:
        with urlopen(Request(BASE + path, data=data, headers=headers, method=method), timeout=20) as response:
            if response.status == 204:
                return None
            raw = response.read(1024 * 1024 + 1)
            if len(raw) > 1024 * 1024:
                raise FixtureFailure("oversized_response")
            return json.loads(raw)
    except HTTPError as error:
        try:
            code = json.loads(error.read(65536)).get("error", {}).get("code", "http_error")
        except (ValueError, AttributeError):
            code = "http_error"
        if not isinstance(code, str) or not re.fullmatch(r"[a-z_]{1,64}", code):
            code = "http_error"
        raise FixtureFailure(f"http_{error.code}_{code}") from None


def money(minor: str) -> dict:
    return {"currency": "CNY", "currency_scale": 2, "amount_minor": minor}


def build_plan(user: str, instance: str, epoch: str) -> dict:
    run = str(uuid4())
    marker = run[:8]
    ids = {name: str(uuid4()) for name in (
        "book", "parent", "child", "income_category", "tag", "picture",
        "expense_stats", "expense_budget", "income", "expense_picture", "before", "after",
    )}
    book = ids["book"]
    result = {
        "purpose": PURPOSE, "run_id": run, "server": BASE,
        "instance_id": instance, "sync_epoch": epoch, "user_id": user,
        "client_id": str(uuid4()), "book_id": book, "book_name": PREFIX + marker,
        "ids": ids, "state": "planned", "commands": [],
        "image": {"id": ids["picture"], "sha256": hashlib.sha256(PNG).hexdigest(),
                  "size_bytes": len(PNG), "width": 3, "height": 2, "ready": False},
        "expected": {
            "start": "2026-09-30", "end_exclusive": "2026-10-31",
            "visible_end": "2026-10-30", "income_minor": "10000",
            "expense_minor": "1350", "net_minor": "8650", "budget_eligible_minor": "2375",
            "period_raw_bill_count": 4, "all_bill_count": 6,
            "ui_budget_create_limit_minor": "10000", "ui_budget_remaining_minor": "7625",
            "picture_search_keyword": "合成图片-" + marker,
        },
        "browser_acceptance": "not_run",
    }

    def add(kind, label, payload, scope=None):
        result["commands"].append({"label": label, "applied": False, "operation": {
            "operation_id": str(uuid4()), "scope_id": scope or book, "entity_type": kind,
            "entity_id": ids[label], "action": "create", "base_revision": "0",
            "depends_on": None, "payload": payload,
        }})

    add("book", "book", {"name": result["book_name"], "currency": "CNY", "timezone": "Asia/Shanghai",
        "month_start_day": 31, "icon": "book", "show_assets": True, "display_mode": "month"}, user)
    for label, name, kind, parent in (
        ("parent", "FT餐饮-", "expense", None),
        ("child", "FT咖啡-", "expense", ids["parent"]),
        ("income_category", "FT工资-", "income", None),
    ):
        add("category", label, {"name": name + marker, "kind": kind, "parent_id": parent,
                               "icon": "food" if kind == "expense" else "salary", "sort_order": 0})
    add("tag", "tag", {"name": "FT标签-" + marker, "color": "#2279D7"})
    for label, day, minor, kind, no_stats, no_budget, note in (
        ("expense_stats", "2026-10-01", "1025", "expense", False, True, "统计样本-"),
        ("expense_budget", "2026-10-15", "2050", "expense", True, False, "预算样本-"),
        ("income", "2026-10-20", "10000", "income", False, False, "合成工资-"),
        ("expense_picture", "2026-10-21", "325", "expense", False, False, "合成图片-"),
        ("before", "2026-09-29", "100", "expense", False, False, "期前边界-"),
        ("after", "2026-10-31", "200", "expense", False, False, "期后边界-"),
    ):
        payload = {"book_id": book, "bill_type": kind, "money": money(minor),
            "business_date": day, "business_timezone": "Asia/Shanghai", "note": note + marker,
            "category_id": ids["income_category"] if kind == "income" else ids["child"],
            "tag_ids": [] if kind == "income" else [ids["tag"]],
            "flags": {"exclude_from_statistics": no_stats, "exclude_from_budget": no_budget}}
        if label == "expense_picture":
            payload["attachment_ids"] = [ids["picture"]]
        add("bill", label, payload)
    return result


def push(plan: dict, token: str, operation: dict) -> dict:
    result = request("/api/v1/sync/push", "POST", {
        "protocol_version": 1, "sync_epoch": plan["sync_epoch"],
        "client_id": plan["client_id"], "operations": [operation],
    }, token=token)["results"][0]
    if result["status"] != "applied":
        raise FixtureFailure("operation_rejected")
    return result


def ensure_image(plan: dict, token: str) -> None:
    if plan["image"]["ready"]:
        return
    image = plan["image"]
    ticket = request("/api/v1/attachments/uploads", "POST", {
        "attachment_id": image["id"], "scope_id": plan["book_id"], "sha256": image["sha256"],
        "size_bytes": len(PNG), "media_type": "image/png",
    }, token=token)
    if ticket["status"] != "ready":
        path = "/api/v1/attachments/uploads/" + ticket["upload_id"]
        if ticket["status"] == "pending":
            request(path + "/content", "PUT", PNG, token=token, binary=True)
        complete = request(path + "/complete", "POST", token=token)
        if complete["sha256"] != image["sha256"]:
            raise FixtureFailure("image_hash_mismatch")
    image["ready"] = True
    write_manifest(plan)


def check_manifest(plan: dict, user: str, info: dict) -> None:
    if (plan.get("purpose") != PURPOSE or plan.get("server") != BASE
            or plan.get("user_id") != user or not plan.get("book_name", "").startswith(PREFIX)
            or plan.get("sync_epoch") != info["sync_epoch"]
            or plan.get("instance_id") != info["instance_id"]):
        raise FixtureFailure("manifest_identity_mismatch")
    for key in ("run_id", "book_id", "client_id"):
        UUID(plan[key])


def seed(plan: dict, token: str) -> None:
    if plan.get("state") == "cleaned":
        raise FixtureFailure("fixture_already_cleaned_choose_new_manifest")
    for command in plan["commands"]:
        if command["applied"]:
            continue
        if command["label"] == "expense_picture":
            ensure_image(plan, token)
        result = push(plan, token, command["operation"])
        command["applied"] = True
        command["revision"] = result["revision"]
        write_manifest(plan)
    query = urlencode({"start_date": plan["expected"]["start"],
                       "end_date_exclusive": plan["expected"]["end_exclusive"]})
    report = request(f"/api/v1/books/{plan['book_id']}/report?{query}", token=token)["report"]
    if not report["available"]:
        raise FixtureFailure("seed_report_unavailable")
    for field in ("income_minor", "expense_minor", "net_minor", "budget_eligible_minor"):
        if report["totals"][field] != plan["expected"][field]:
            raise FixtureFailure("seed_report_golden_mismatch")
    plan["state"] = "seeded"
    plan["preparation_http_check"] = "passed_not_browser_acceptance"
    write_manifest(plan)


def current_entities(plan: dict, token: str) -> list[dict]:
    # Unlike an incremental pull (which covers all authorized scopes), this
    # snapshot explicitly materializes only this one synthetic book.
    snapshot = request("/api/v1/sync/snapshots", "POST", {
        "protocol_version": 1, "client_id": plan["client_id"],
        "sync_epoch": plan["sync_epoch"], "scope_ids": [plan["book_id"]],
    }, token=token)
    if snapshot["status"] != "ready":
        raise FixtureFailure("cleanup_snapshot_not_ready")
    next_token = snapshot["first_page_token"]
    entities = []
    for index in range(20):
        page = request(f"/api/v1/sync/snapshots/{snapshot['snapshot_id']}/pages", "POST", {
            "client_id": plan["client_id"], "page_token": next_token,
        }, token=token)
        if page["page_index"] != index:
            raise FixtureFailure("cleanup_snapshot_page_order")
        for event in page["items"]:
            if event["scope_id"] != plan["book_id"]:
                raise FixtureFailure("cleanup_unexpected_scope")
            entities.append(event)
        next_token = page["next_page_token"]
        if next_token is None:
            if len(snapshot["manifest"]["pages"]) != index + 1:
                raise FixtureFailure("cleanup_snapshot_page_count")
            return entities
    raise FixtureFailure("cleanup_too_many_pages")


def cleanup(plan: dict, token: str) -> None:
    if plan.get("state") == "cleaned":
        return
    book = request(f"/api/v1/sync/entities/book/{plan['book_id']}?scope_id={plan['book_id']}", token=token)
    if book["event"]["deleted"]:
        plan["state"] = "cleaned"
        write_manifest(plan)
        return
    if book["editable_payload"]["name"] != plan["book_name"]:
        raise FixtureFailure("cleanup_book_name_changed")
    entities = [event for event in current_entities(plan, token) if not event["deleted"]]
    rank = {"bill": 0, "budget": 1, "tag": 2, "category": 3, "book": 4}

    def key(event):
        # Explicit current authorized payload, never data from another scope.
        payload = (event.get("data") or {}).get("payload") or {}
        return (rank.get(event["entity_type"], 99),
                0 if payload.get("parent_id") or payload.get("group_id") else 1)

    for event in sorted(entities, key=key):
        kind = event["entity_type"]
        if kind not in rank:
            raise FixtureFailure("cleanup_unexpected_entity_kind")
        latest = request(f"/api/v1/sync/entities/{kind}/{event['entity_id']}?scope_id={plan['book_id']}", token=token)["event"]
        if latest["deleted"]:
            continue
        push(plan, token, {"operation_id": str(uuid4()), "scope_id": plan["book_id"],
            "entity_type": kind, "entity_id": event["entity_id"], "action": "delete",
            "base_revision": latest["revision"], "depends_on": None, "payload": {}})
    plan["state"] = "cleaned"
    plan["cleanup"] = "normal scoped tombstones; physical attachment GC not asserted"
    write_manifest(plan)


def verify_ui_result(plan: dict, token: str) -> None:
    """Supplement the real UI receipts; never creates business entities."""
    query = urlencode({"start_date": plan["expected"]["start"],
                       "end_date_exclusive": plan["expected"]["end_exclusive"]})
    report = request(f"/api/v1/books/{plan['book_id']}/report?{query}", token=token)["report"]
    expected = {"income_minor": "10000", "expense_minor": "1475",
                "net_minor": "8525", "budget_eligible_minor": "2500"}
    if not report["available"] or any(report["totals"][key] != value for key, value in expected.items()):
        raise FixtureFailure("ui_result_report_mismatch")
    events = [event for event in current_entities(plan, token) if not event["deleted"]]
    bills = [(event.get("data") or {}).get("payload") or {} for event in events
             if event["entity_type"] == "bill"]
    budgets = [(event.get("data") or {}).get("payload") or {} for event in events
               if event["entity_type"] == "budget"]
    added = [bill for bill in bills if bill.get("note") == "UI补记-" + plan["run_id"][:8]]
    if (len(bills) != 7 or len(added) != 1 or added[0]["business_date"] != "2026-10-16"
            or added[0]["money"] != money("125") or added[0]["category_id"] != plan["ids"]["child"]):
        raise FixtureFailure("ui_result_saved_bill_mismatch")
    starts = {"2026-09-30", "2026-10-31"}
    if (len(budgets) != 2 or {budget["period_start"] for budget in budgets} != starts
            or any(budget["total"] != money("10001") for budget in budgets)):
        raise FixtureFailure("ui_result_budget_mismatch")
    result = {"result": "passed", "kind": "supplemental_server_check_after_real_ui_sync",
              "all_bill_count": 7, "unique_ui_added_bill_count": 1, "budget_count": 2,
              "both_budget_limits_minor": "10001", "report_totals": expected,
              "browser_acceptance": "see_separate_real_ui_receipts"}
    (MANIFEST.parent / "web-ui-server-receipt.json").write_text(json.dumps(result, indent=2), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("seed", "cleanup", "verify-ui"))
    args = parser.parse_args()
    rows = json.loads(CREDENTIALS.read_text(encoding="utf-8-sig"))
    account = rows[0]  # Existing synthetic Web QA account only.
    plan = json.loads(MANIFEST.read_text(encoding="utf-8-sig")) if MANIFEST.exists() else None
    info = request("/api/v1/server-info")
    client = plan["client_id"] if plan else str(uuid4())
    login = request("/api/v1/auth/login", "POST", {
        "username": account["username"], "password": account["password"],
        "client_id": client, "client_kind": "native", "device_name": "FlowTrace P3 synthetic browser fixture preparation",
    })
    token = login["access_token"]
    try:
        if plan is None:
            if args.action != "seed":
                raise FixtureFailure("no_manifest_to_clean")
            plan = build_plan(login["user_id"], info["instance_id"], info["sync_epoch"])
            plan["client_id"] = client
            write_manifest(plan)  # Frozen UUIDs/payloads before the first write.
        check_manifest(plan, login["user_id"], info)
        if args.action == "seed":
            seed(plan, token)
        elif args.action == "cleanup":
            cleanup(plan, token)
        else:
            verify_ui_result(plan, token)
        print(json.dumps({"state": plan["state"], "browser_acceptance": "not_run",
                          "manifest": "outputs/validation/P3/web-fixture.json"}))
    finally:
        request("/api/v1/auth/logout", "POST", token=token)


if __name__ == "__main__":
    try:
        main()
    except FixtureFailure as error:
        raise SystemExit(str(error)) from None
    except Exception:
        raise SystemExit("fixture_preparation_failed_inspect_locally_without_printing_credentials") from None
