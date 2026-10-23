"""Prepare/verify/clean one synthetic book-move UI run on loopback18080.

Preparation and supplemental HTTP verification are not browser acceptance.
Credentials remain in the ignored QA file; business operations are journaled
with fixed UUIDs before sending. No private-scope snapshots are requested.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener
from uuid import UUID, uuid4

from prepare_fixture import (
    BASE, CREDENTIALS, PNG, ROOT, FixtureFailure, current_entities, money, push, request,
)

OUTPUT = ROOT / "outputs/validation/P3"
MANIFEST = OUTPUT / "web-book-move-fixture.json"
PURPOSE = "flowtrace-p3-book-move-ui-synthetic"


def save(plan: dict) -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    temporary = MANIFEST.with_suffix(".tmp")
    temporary.write_text(json.dumps(plan, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(MANIFEST)


def make_plan(user: str, info: dict, client: str) -> dict:
    run = str(uuid4())
    marker = run[:8]
    ids = {key: str(uuid4()) for key in (
        "source", "target", "account", "source_category", "target_category",
        "source_tag", "target_tag", "picture", "bill",
    )}
    names = {
        "source": "FT移动来源-" + marker, "target": "FT移动目标-" + marker,
        "account": "FT移动私账-" + marker,
        "source_category": "FT原分类-" + marker, "target_category": "FT目标分类-" + marker,
        "source_tag": "FT原标签-" + marker, "target_tag": "FT目标标签-" + marker,
        "bill_note": "UI移动原图-" + marker,
    }
    plan = {"purpose": PURPOSE, "state": "planned", "run_id": run, "server": BASE,
            "client_id": client, "user_id": user, "instance_id": info["instance_id"],
            "sync_epoch": info["sync_epoch"], "ids": ids, "names": names,
            "commands": [], "cleanup_commands": [],
            "image": {"id": ids["picture"], "sha256": hashlib.sha256(PNG).hexdigest(),
                      "size_bytes": len(PNG), "media_type": "image/png", "ready": False},
            "expected": {"account_opening_minor": "10000", "account_balance_minor": "9875",
                         "expense_minor": "125", "business_date": "2026-10-21",
                         "business_timezone": "Asia/Shanghai", "occurred_at": "2026-10-21T05:06:07.123456Z"}}

    def add(kind: str, label: str, scope: str, payload: dict) -> None:
        plan["commands"].append({"label": label, "applied": False, "operation": {
            "operation_id": str(uuid4()), "scope_id": scope, "entity_type": kind,
            "entity_id": ids[label], "action": "create", "base_revision": "0",
            "depends_on": None, "payload": payload}})

    for label, zone in (("source", "Asia/Shanghai"), ("target", "America/New_York")):
        add("book", label, user, {"name": names[label], "currency": "CNY", "timezone": zone,
            "month_start_day": 1, "show_assets": True, "display_mode": "month", "icon": "book"})
    add("account", "account", user, {"name": names["account"], "kind": "cash",
        "opening": money("10000"), "include_in_net_assets": True, "hidden": False})
    for prefix in ("source", "target"):
        add("category", prefix + "_category", ids[prefix], {"name": names[prefix + "_category"],
            "kind": "expense", "parent_id": None, "icon": "food", "sort_order": 0})
        add("tag", prefix + "_tag", ids[prefix], {"name": names[prefix + "_tag"],
            "color": "#2279D7", "kind": "tag", "group_id": None, "sort_order": 0})
    expense = {"book_id": ids["source"], "bill_type": "expense", "money": money("125"),
        "account_id": ids["account"], "business_date": plan["expected"]["business_date"],
        "business_timezone": plan["expected"]["business_timezone"],
        "occurred_at": plan["expected"]["occurred_at"], "source": "manual",
        "category_id": ids["source_category"], "tag_ids": [ids["source_tag"]],
        "attachment_ids": [ids["picture"]], "note": names["bill_note"],
        "flags": {"exclude_from_statistics": False, "exclude_from_budget": False}}
    add("bill", "bill", ids["source"], expense)
    plan["original_bill"] = expense
    return plan


def check(plan: dict, user: str, info: dict) -> None:
    if (plan.get("purpose") != PURPOSE or plan.get("server") != BASE
            or plan.get("user_id") != user or plan.get("instance_id") != info["instance_id"]
            or plan.get("sync_epoch") != info["sync_epoch"]):
        raise FixtureFailure("move_fixture_identity_mismatch")
    for identifier in (plan["run_id"], plan["client_id"], *plan["ids"].values()):
        UUID(identifier)
    marker = plan["run_id"][:8]
    if (plan["names"]["source"] != "FT移动来源-" + marker
            or plan["names"]["target"] != "FT移动目标-" + marker
            or plan["names"]["account"] != "FT移动私账-" + marker):
        raise FixtureFailure("move_fixture_name_guard")


def image_ready(plan: dict, token: str) -> None:
    image = plan["image"]
    if image["ready"]:
        return
    ticket = request("/api/v1/attachments/uploads", "POST", {
        "attachment_id": image["id"], "scope_id": plan["ids"]["source"],
        "sha256": image["sha256"], "size_bytes": image["size_bytes"], "media_type": "image/png",
    }, token=token)
    if ticket["status"] != "ready":
        path = "/api/v1/attachments/uploads/" + ticket["upload_id"]
        if ticket["status"] == "pending":
            request(path + "/content", "PUT", PNG, token=token, binary=True)
        complete = request(path + "/complete", "POST", token=token)
        if complete["sha256"] != image["sha256"]:
            raise FixtureFailure("move_fixture_image_hash")
    image["ready"] = True
    save(plan)


def entity(plan: dict, token: str, kind: str, identifier: str, scope: str) -> dict:
    return request(f"/api/v1/sync/entities/{kind}/{identifier}?scope_id={scope}", token=token)


def balance(plan: dict, token: str) -> None:
    account = entity(plan, token, "account", plan["ids"]["account"], plan["user_id"])
    data = account["event"]["data"]
    if (data["payload"]["name"] != plan["names"]["account"] or data["balance"] != money("9875")):
        raise FixtureFailure("move_fixture_balance_changed")


def seed(plan: dict, token: str) -> None:
    if plan["state"] == "cleaned":
        raise FixtureFailure("move_fixture_cleaned_start_new_run")
    for row in plan["commands"]:
        if row["applied"]:
            continue
        if row["label"] == "bill":
            image_ready(plan, token)
        result = push(plan, token, row["operation"])
        row.update(applied=True, revision=result["revision"])
        save(plan)
    original = entity(plan, token, "bill", plan["ids"]["bill"], plan["ids"]["source"])
    if any(original["editable_payload"][key] != value for key, value in plan["original_bill"].items()):
        raise FixtureFailure("move_fixture_original_bill_changed")
    balance(plan, token)
    plan["state"] = "seeded"
    plan["http_preparation_check"] = "passed_not_browser_acceptance"
    save(plan)


def verify_ui(plan: dict, token: str) -> None:
    evidence = json.loads((OUTPUT / "web-book-move-sync-move-receipt.json").read_text(encoding="utf-8-sig"))
    sent = evidence.get("move_requests") or []
    applied = evidence.get("move_responses") or []
    if not sent or not applied or any(row["status"] != "applied" for row in applied):
        raise FixtureFailure("move_ui_applied_receipt_missing")
    command = sent[0]
    if (len({row["operation_id"] for row in sent}) != 1
            or len({row["wire_sha256"] for row in sent}) != 1
            or command["entity_id"] != plan["ids"]["bill"]
            or command["scope_id"] != plan["ids"]["source"]
            or command["move"]["target_scope_id"] != plan["ids"]["target"]
            or applied[-1]["operation_id"] != command["operation_id"]
            or applied[-1]["entity_id"] != plan["ids"]["bill"]):
        raise FixtureFailure("move_ui_marker_mismatch")
    current = entity(plan, token, "bill", plan["ids"]["bill"], plan["ids"]["target"])
    payload = current["editable_payload"]
    if (current["event"]["entity_id"] != plan["ids"]["bill"]
            or current["event"]["scope_id"] != plan["ids"]["target"]
            or current["event"]["revision"] != applied[-1]["revision"]
            or payload["category_id"] != plan["ids"]["target_category"]
            or payload["tag_ids"] != [plan["ids"]["target_tag"]]):
        raise FixtureFailure("move_ui_target_mapping_mismatch")
    for key in ("money", "bill_type", "account_id", "business_date", "business_timezone", "source", "note", "flags"):
        if payload[key] != plan["original_bill"][key]:
            raise FixtureFailure("move_ui_immutable_field_changed")
    if payload["occurred_at"].replace("+00:00", "Z") != plan["expected"]["occurred_at"]:
        raise FixtureFailure("move_ui_original_instant_changed")
    replacements = command["move"]["attachment_replacements"]
    if (len(replacements) != 1 or replacements[0]["source_id"] != plan["ids"]["picture"]
            or replacements[0]["target_id"] == plan["ids"]["picture"]
            or payload["attachment_ids"] != [replacements[0]["target_id"]]):
        raise FixtureFailure("move_ui_clone_marker_mismatch")
    clone = request("/api/v1/attachments/" + replacements[0]["target_id"], token=token)
    if (clone["scope_id"] != plan["ids"]["target"] or clone["status"] != "ready"
            or clone["sha256"] != plan["image"]["sha256"] or clone["size_bytes"] != len(PNG)):
        raise FixtureFailure("move_ui_clone_hash_mismatch")
    class NoRedirect(HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    clone_url = BASE + "/api/v1/attachments/" + replacements[0]["target_id"] + "/content"
    with build_opener(NoRedirect()).open(Request(clone_url, headers={"Authorization": "Bearer " + token}), timeout=15) as response:
        downloaded = response.read(len(PNG) + 1)
    if downloaded != PNG:
        raise FixtureFailure("move_ui_clone_actual_bytes_changed")
    query = urlencode({"start_date": "2026-10-01", "end_date_exclusive": "2026-11-01"})
    for label, expected in (("source", "0"), ("target", "125")):
        report = request(f"/api/v1/books/{plan['ids'][label]}/report?{query}", token=token)["report"]
        if not report["available"] or report["totals"]["expense_minor"] != expected:
            raise FixtureFailure("move_ui_report_mismatch")
    source_snapshot = current_entities({**plan, "book_id": plan["ids"]["source"]}, token)
    if any(row["entity_type"] == "bill" and not row["deleted"] for row in source_snapshot):
        raise FixtureFailure("move_ui_source_still_has_bill")
    balance(plan, token)
    result = {"result": "passed", "kind": "supplemental_read_only_after_real_ui",
              "same_bill_uuid": True, "explicit_category_and_tag_mapping": True,
              "original_time_and_private_account_preserved": True, "account_balance_minor": "9875",
              "source_expense_minor": "0", "target_expense_minor": "125",
              "clone_has_new_uuid_same_sha256": True, "clone_sha256": clone["sha256"],
              "actual_clone_bytes_match_source": True, "clone_bytes": len(downloaded),
              "ui_applied_operation_id": command["operation_id"], "applied_revision": applied[-1]["revision"]}
    (OUTPUT / "web-book-move-server-receipt.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    plan["state"] = "verified_after_ui"
    save(plan)


def cleanup(plan: dict, token: str) -> None:
    if plan["state"] == "cleaned":
        return
    rank = {"bill": 0, "budget": 1, "tag": 2, "category": 3}
    for label in ("source", "target"):
        scope = plan["ids"][label]
        book = entity(plan, token, "book", scope, scope)
        if book["event"]["deleted"]:
            continue
        if book["editable_payload"]["name"] != plan["names"][label]:
            raise FixtureFailure("move_cleanup_book_guard")
        rows = [row for row in current_entities({**plan, "book_id": scope}, token)
                if not row["deleted"] and row["entity_type"] != "book"]
        if any(row["entity_type"] not in rank for row in rows):
            raise FixtureFailure("move_cleanup_unexpected_scope_data")
        rows.sort(key=lambda row: rank[row["entity_type"]])
        rows.append(book["event"])
        for row in rows:
            delete_entity(plan, token, row["entity_type"], row["entity_id"], scope)
    account = entity(plan, token, "account", plan["ids"]["account"], plan["user_id"])
    if not account["event"]["deleted"]:
        if account["editable_payload"]["name"] != plan["names"]["account"]:
            raise FixtureFailure("move_cleanup_account_guard")
        delete_entity(plan, token, "account", plan["ids"]["account"], plan["user_id"])
    plan["state"] = "cleaned"
    plan["cleanup"] = "only_two_new_book_scopes_and_one_known_private_account_normal_tombstones"
    save(plan)


def delete_entity(plan: dict, token: str, kind: str, identifier: str, scope: str) -> None:
    current = entity(plan, token, kind, identifier, scope)["event"]
    if current["deleted"]:
        return
    previous = next((row for row in plan["cleanup_commands"]
                     if row["operation"]["entity_id"] == identifier and row["operation"]["scope_id"] == scope), None)
    if previous is None:
        previous = {"applied": False, "operation": {"operation_id": str(uuid4()),
            "scope_id": scope, "entity_type": kind, "entity_id": identifier, "action": "delete",
            "base_revision": current["revision"], "depends_on": None, "payload": {}}}
        plan["cleanup_commands"].append(previous)
        save(plan)
    push(plan, token, previous["operation"])
    previous["applied"] = True
    save(plan)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("seed", "verify-ui", "cleanup"))
    action = parser.parse_args().action
    account = json.loads(CREDENTIALS.read_text(encoding="utf-8-sig"))[0]
    plan = json.loads(MANIFEST.read_text(encoding="utf-8-sig")) if MANIFEST.exists() else None
    info = request("/api/v1/server-info")
    client = plan["client_id"] if plan else str(uuid4())
    login = request("/api/v1/auth/login", "POST", {"username": account["username"],
        "password": account["password"], "client_id": client, "client_kind": "native",
        "device_name": "FlowTrace dedicated book-move UI fixture preparation"})
    token = login["access_token"]
    try:
        if plan is None:
            if action != "seed":
                raise FixtureFailure("move_fixture_not_created")
            plan = make_plan(login["user_id"], info, client)
            save(plan)
        check(plan, login["user_id"], info)
        {"seed": seed, "verify-ui": verify_ui, "cleanup": cleanup}[action](plan, token)
        print(json.dumps({"action": action, "state": plan["state"], "credentials_logged": False,
                          "browser_acceptance": "separate_ui_receipts"}))
    finally:
        request("/api/v1/auth/logout", "POST", token=token)


if __name__ == "__main__":
    try:
        main()
    except FixtureFailure as error:
        raise SystemExit(str(error)) from None
    except Exception:
        raise SystemExit("move_fixture_failed_inspect_locally_no_credentials_logged") from None
