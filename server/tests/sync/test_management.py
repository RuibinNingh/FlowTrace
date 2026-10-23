from copy import deepcopy
from uuid import UUID

import pytest
from pydantic import ValidationError
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from flowtrace_server.books.models import Book
from flowtrace_server.sync.canonical import content_hash
from flowtrace_server.sync.models import (
    LedgerEntry,
    SnapshotPage,
    SyncChange,
    SyncEntity,
    SyncSnapshot,
)
from flowtrace_server.sync.projections import entity_data
from flowtrace_server.sync.schemas import (
    BOOK_CORE_FIELDS,
    MANAGEMENT_NEW_FIELDS,
    BookPayload,
    CategoryPayload,
    TagPayload,
)

from .helpers import account, epoch, expense, money, operation, push, share

pytestmark = pytest.mark.postgres


def category_payload(name="合成分类", **changes):
    return {
        "name": name,
        "kind": "expense",
        "parent_id": None,
        "icon": "food",
        "sort_order": 0,
        **changes,
    }


def tag_payload(name="合成标签", **changes):
    return {"name": name, "color": "#2279D7", **changes}


def create(engine, actor, kind, payload, *, scope=None):
    command = operation(scope or actor.book_id, kind, payload)
    result = push(engine, actor, command)[0]
    assert result["status"] == "applied", result
    return command


def update(engine, actor, command, payload):
    with Session(engine) as session:
        current = session.get(SyncEntity, UUID(command["entity_id"]))
        revision = str(current.revision)
        scope = current.scope_id
    changed = operation(
        scope,
        command["entity_type"],
        payload,
        identifier=UUID(command["entity_id"]),
        action="update",
        revision=revision,
    )
    return push(engine, actor, changed)[0]


def test_management_defaults_are_closed_and_strict(actors):
    assert (
        BookPayload.model_validate(
            {
                "name": "旧账本",
                "currency": "CNY",
                "timezone": "Asia/Shanghai",
                "month_start_day": 1,
            }
        ).display_mode
        == "month"
    )
    for invalid in (True, "weekly", 1, None):
        with pytest.raises(ValidationError):
            BookPayload.model_validate(
                {
                    "name": "无效显示",
                    "currency": "CNY",
                    "timezone": "Asia/Shanghai",
                    "month_start_day": 1,
                    "display_mode": invalid,
                }
            )
    assert (
        BookPayload.model_validate(
            {
                "name": "旧账本",
                "currency": "CNY",
                "timezone": "Asia/Shanghai",
                "month_start_day": 1,
            }
        ).model_dump()["show_assets"]
        is False
    )
    assert CategoryPayload.model_validate(category_payload()).archived is False
    assert TagPayload.model_validate(tag_payload()).model_dump() == {
        **tag_payload(),
        "kind": "tag",
        "group_id": None,
        "archived": False,
        "sort_order": 0,
    }
    for payload in [
        tag_payload(kind="group", group_id="11111111-1111-4111-8111-111111111111"),
        tag_payload(kind="unknown"),
        tag_payload(archived=1),
        tag_payload(sort_order=True),
        tag_payload(sort_order=-1),
        tag_payload(sort_order=2147483648),
        tag_payload(extra=True),
    ]:
        with pytest.raises(ValidationError):
            TagPayload.model_validate(payload)


def test_book_metadata_core_orm_and_legacy_update_preserve_new_fields(actors, postgres_engine):
    alice, _, _ = actors
    payload = {
        "name": "配置账本",
        "currency": "CNY",
        "timezone": "Asia/Shanghai",
        "month_start_day": 12,
        "template": "travel",
        "icon": "flight",
        "cover_color": "#123ABC",
        "show_assets": True,
        "display_mode": "year",
    }
    command = create(postgres_engine, alice, "book", payload, scope=alice.principal.user_id)
    legacy = {key: payload[key] for key in BOOK_CORE_FIELDS}
    legacy.update(name="旧客户端改名", timezone="America/New_York", month_start_day=31)
    assert update(postgres_engine, alice, command, legacy)["status"] == "applied"
    with Session(postgres_engine) as session:
        book = session.get(Book, UUID(command["entity_id"]))
        entity = session.get(SyncEntity, book.id)
        assert book.name == legacy["name"] and book.timezone == "America/New_York"
        assert book.month_start_day == 31
        assert all(entity.payload[key] == payload[key] for key in MANAGEMENT_NEW_FIELDS["book"])
        assert "icon" not in Book.__table__.columns
    assert (
        update(
            postgres_engine,
            alice,
            command,
            {**legacy, "show_assets": False, "display_mode": "all"},
        )["status"]
        == "applied"
    )
    with Session(postgres_engine) as session:
        saved = session.get(SyncEntity, UUID(command["entity_id"])).payload
        assert saved["show_assets"] is False
        assert saved["display_mode"] == "all"


def test_legacy_current_json_gets_defaults_without_silent_rewrite(actors, postgres_engine):
    alice, _, _ = actors
    tag = create(postgres_engine, alice, "tag", tag_payload())
    category = create(postgres_engine, alice, "category", category_payload())
    with Session(postgres_engine) as session:
        for identifier in [alice.book_id, UUID(tag["entity_id"]), UUID(category["entity_id"])]:
            entity = session.get(SyncEntity, identifier)
            legacy = {
                key: value
                for key, value in entity.payload.items()
                if key not in MANAGEMENT_NEW_FIELDS[entity.entity_type]
            }
            entity.payload = legacy
        session.commit()
    with Session(postgres_engine) as session:
        for identifier in [alice.book_id, UUID(tag["entity_id"]), UUID(category["entity_id"])]:
            entity = session.get(SyncEntity, identifier)
            before, revision = deepcopy(entity.payload), entity.revision
            projected = entity_data(session, entity)["payload"]
            assert MANAGEMENT_NEW_FIELDS[entity.entity_type].issubset(projected)
            assert entity.payload == before and entity.revision == revision


def test_tag_group_references_are_same_book_and_groups_are_not_bill_tags(actors, postgres_engine):
    alice, bob, _ = actors
    group = create(postgres_engine, alice, "tag", tag_payload("组", kind="group"))
    child = create(postgres_engine, alice, "tag", tag_payload("成员", group_id=group["entity_id"]))
    invalid = operation(alice.book_id, "tag", tag_payload(group_id=child["entity_id"]))
    assert push(postgres_engine, alice, invalid)[0]["error"]["code"] == "tag.invalid_group"
    foreign = create(postgres_engine, bob, "tag", tag_payload("他人组", kind="group"))
    invalid["operation_id"] = operation(alice.book_id, "tag", tag_payload())["operation_id"]
    invalid["payload"]["group_id"] = foreign["entity_id"]
    assert push(postgres_engine, alice, invalid)[0]["error"]["code"] == "not_found"
    other_book = create(
        postgres_engine,
        alice,
        "book",
        {
            "name": "本人另一本",
            "currency": "CNY",
            "timezone": "Asia/Shanghai",
            "month_start_day": 1,
        },
        scope=alice.principal.user_id,
    )
    own_foreign_group = create(
        postgres_engine,
        alice,
        "tag",
        tag_payload(kind="group"),
        scope=UUID(other_book["entity_id"]),
    )
    invalid["operation_id"] = operation(alice.book_id, "tag", tag_payload())["operation_id"]
    invalid["payload"]["group_id"] = own_foreign_group["entity_id"]
    assert push(postgres_engine, alice, invalid)[0]["error"]["code"] == "not_found"
    bill = operation(alice.book_id, "bill", expense(alice.book_id, tag_ids=[group["entity_id"]]))
    assert push(postgres_engine, alice, bill)[0]["error"]["code"] == "tag.group_not_selectable"
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, UUID(bill["entity_id"])) is None


def test_group_delete_and_conversion_require_explicit_detach_and_preserve_history(
    actors, postgres_engine
):
    alice, _, _ = actors
    group = create(postgres_engine, alice, "tag", tag_payload("组", kind="group"))
    child = create(
        postgres_engine,
        alice,
        "tag",
        tag_payload("成员", group_id=group["entity_id"], archived=True),
    )
    remove = operation(
        alice.book_id, "tag", {}, identifier=UUID(group["entity_id"]), action="delete", revision="1"
    )
    assert push(postgres_engine, alice, remove)[0]["error"]["code"] == "tag.group_not_empty"
    assert (
        update(postgres_engine, alice, group, tag_payload(kind="tag"))["error"]["code"]
        == "tag.group_not_empty"
    )
    assert (
        update(postgres_engine, alice, child, tag_payload(group_id=None, archived=False))["status"]
        == "applied"
    )
    # A rejected operation is immutable; a new explicit attempt has a new ID.
    remove["operation_id"] = operation(alice.book_id, "tag", tag_payload())["operation_id"]
    assert push(postgres_engine, alice, remove)[0]["status"] == "applied"
    bill = create(
        postgres_engine, alice, "bill", expense(alice.book_id, tag_ids=[child["entity_id"]])
    )
    assert (
        update(postgres_engine, alice, child, tag_payload(kind="group"))["error"]["code"]
        == "tag.definition_in_use"
    )
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, UUID(bill["entity_id"])).payload["tag_ids"] == [
            child["entity_id"]
        ]


def test_group_archive_effective_for_new_choices_but_old_bill_can_keep_tag(actors, postgres_engine):
    alice, _, _ = actors
    group = create(postgres_engine, alice, "tag", tag_payload("组", kind="group"))
    child = create(
        postgres_engine,
        alice,
        "tag",
        tag_payload("成员", group_id=group["entity_id"], sort_order=7),
    )
    payload = expense(alice.book_id, tag_ids=[child["entity_id"]])
    bill = create(postgres_engine, alice, "bill", payload)
    assert (
        update(postgres_engine, alice, group, tag_payload(kind="group", archived=True))["status"]
        == "applied"
    )
    denied = operation(alice.book_id, "bill", payload)
    assert push(postgres_engine, alice, denied)[0]["error"]["code"] == "tag.archived"
    assert (
        update(postgres_engine, alice, bill, {**payload, "note": "保留历史标签"})["status"]
        == "applied"
    )
    assert (
        update(postgres_engine, alice, group, tag_payload(kind="group", archived=False))["status"]
        == "applied"
    )
    assert update(postgres_engine, alice, child, tag_payload(archived=True))["status"] == "applied"
    assert update(postgres_engine, alice, child, tag_payload("旧版改名"))["status"] == "applied"
    with Session(postgres_engine) as session:
        saved = session.get(SyncEntity, UUID(child["entity_id"])).payload
        assert saved["group_id"] == group["entity_id"] and saved["archived"] is True
        assert saved["sort_order"] == 7
    assert update(postgres_engine, alice, child, tag_payload(archived=False))["status"] == "applied"
    assert create(postgres_engine, alice, "bill", payload)


def test_category_hierarchy_conversion_archive_and_sort_are_nonfinancial(actors, postgres_engine):
    alice, _, _ = actors
    parent = create(postgres_engine, alice, "category", category_payload("父"))
    other = create(postgres_engine, alice, "category", category_payload("另一个父"))
    child_payload = category_payload("子", parent_id=parent["entity_id"])
    child = create(postgres_engine, alice, "category", child_payload)
    denied = update(postgres_engine, alice, parent, category_payload(parent_id=other["entity_id"]))
    assert denied["error"]["code"] == "category.invalid_parent"
    assert (
        update(postgres_engine, alice, parent, category_payload(kind="income"))["error"]["code"]
        == "category.definition_in_use"
    )
    identifier = account(postgres_engine, alice)
    bill_payload = expense(alice.book_id, identifier, category_id=child["entity_id"])
    bill = create(postgres_engine, alice, "bill", bill_payload)
    assert (
        update(postgres_engine, alice, parent, category_payload(archived=True))["status"]
        == "applied"
    )
    assert (
        push(postgres_engine, alice, operation(alice.book_id, "bill", bill_payload))[0]["error"][
            "code"
        ]
        == "category.archived"
    )
    assert (
        update(postgres_engine, alice, bill, {**bill_payload, "note": "仍可核对"})["status"]
        == "applied"
    )
    assert (
        update(
            postgres_engine,
            alice,
            child,
            {**child_payload, "sort_order": 22, "icon": "custom-icon"},
        )["status"]
        == "applied"
    )
    assert (
        update(postgres_engine, alice, child, category_payload(parent_id=other["entity_id"]))[
            "status"
        ]
        == "applied"
    )
    assert (
        update(postgres_engine, alice, child, category_payload(parent_id=None))["status"]
        == "applied"
    )
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, identifier).balance_minor == 99900
        assert (
            session.scalar(
                select(func.sum(LedgerEntry.amount_minor)).where(
                    LedgerEntry.account_id == identifier
                )
            )
            == -100
        )
        assert session.get(SyncEntity, UUID(child["entity_id"])).payload["parent_id"] is None


def test_archived_fee_category_is_preserved_only_on_its_original_bill(actors, postgres_engine):
    alice, _, _ = actors
    category = create(postgres_engine, alice, "category", category_payload("手续费"))
    identifier = account(postgres_engine, alice)
    destination = account(postgres_engine, alice, opening="0")
    payload = expense(
        alice.book_id,
        bill_type="transfer",
        from_account_id=str(identifier),
        to_account_id=str(destination),
        fee={
            "money": money("5"),
            "account_id": str(identifier),
            "category_id": category["entity_id"],
            "flags": {"exclude_from_statistics": False, "exclude_from_budget": False},
        },
    )
    bill = create(postgres_engine, alice, "bill", payload)
    assert (
        update(postgres_engine, alice, category, category_payload(archived=True))["status"]
        == "applied"
    )
    assert (
        push(postgres_engine, alice, operation(alice.book_id, "bill", payload))[0]["error"]["code"]
        == "category.archived"
    )
    assert (
        update(postgres_engine, alice, bill, {**payload, "note": "保留原手续费分类"})["status"]
        == "applied"
    )
    with Session(postgres_engine) as session:
        assert session.get(SyncEntity, identifier).balance_minor == 99895
        assert session.get(SyncEntity, destination).balance_minor == 100


def test_category_move_cannot_invalidate_existing_budget_and_archive_keeps_old_budget(
    actors, postgres_engine
):
    alice, _, _ = actors
    first = create(postgres_engine, alice, "category", category_payload("一"))
    second = create(postgres_engine, alice, "category", category_payload("二"))
    payload = {
        "period_start": "2026-10-01",
        "period_end_exclusive": "2026-11-01",
        "total": money("300"),
        "categories": [
            {"category_id": item["entity_id"], "limit": money("100")} for item in [first, second]
        ],
        "carry_forward": False,
    }
    budget = create(postgres_engine, alice, "budget", payload)
    moved = category_payload(parent_id=first["entity_id"])
    assert (
        update(postgres_engine, alice, second, moved)["error"]["code"] == "category.budget_overlap"
    )
    assert (
        update(postgres_engine, alice, first, category_payload(archived=True))["status"]
        == "applied"
    )
    assert (
        update(postgres_engine, alice, budget, {**payload, "total": money("400")})["status"]
        == "applied"
    )
    assert (
        push(postgres_engine, alice, operation(alice.book_id, "budget", payload))[0]["error"][
            "code"
        ]
        == "category.archived"
    )
    assert (
        update(
            postgres_engine, alice, budget, {**payload, "categories": payload["categories"][1:]}
        )["status"]
        == "applied"
    )
    assert update(postgres_engine, alice, second, moved)["status"] == "applied"


def test_management_permissions_editor_viewer_and_owner_only_book(actors, postgres_engine):
    alice, bob, carol = actors
    share(postgres_engine, alice, bob, "editor")
    share(postgres_engine, alice, carol, "viewer")
    group = create(postgres_engine, bob, "tag", tag_payload(kind="group"), scope=alice.book_id)
    assert (
        update(postgres_engine, bob, group, tag_payload(kind="group", archived=True))["status"]
        == "applied"
    )
    denied = operation(alice.book_id, "tag", tag_payload())
    assert push(postgres_engine, carol, denied)[0]["error"]["http_status"] == 403
    book_payload = {
        "name": "编辑者不能改账本",
        "currency": "CNY",
        "timezone": "Asia/Shanghai",
        "month_start_day": 1,
        "show_assets": True,
    }
    denied = operation(
        alice.book_id, "book", book_payload, identifier=alice.book_id, action="update", revision="1"
    )
    assert push(postgres_engine, bob, denied)[0]["error"]["code"] == "book_owner_required"


def test_batch_management_keeps_ordered_independent_results_and_failed_dependency(
    actors, postgres_engine
):
    alice, _, _ = actors
    parent = operation(alice.book_id, "category", category_payload())
    child = operation(alice.book_id, "category", category_payload(parent_id=parent["entity_id"]))
    too_deep = operation(alice.book_id, "category", category_payload(parent_id=child["entity_id"]))
    dependent = operation(alice.book_id, "tag", tag_payload(), depends=too_deep["operation_id"])
    independent = operation(alice.book_id, "tag", tag_payload("独立成功"))
    result = push(postgres_engine, alice, [parent, child, too_deep, dependent, independent])
    assert [item["status"] for item in result] == [
        "applied",
        "applied",
        "rejected",
        "rejected",
        "applied",
    ]
    assert result[2]["error"]["code"] == "category.invalid_parent"
    assert result[3]["error"]["code"] == "dependency_failed"


def test_template_metadata_and_explicit_configuration_copy_never_clone_finances(
    actors, postgres_engine
):
    alice, _, _ = actors
    identifier = account(postgres_engine, alice)
    create(postgres_engine, alice, "bill", expense(alice.book_id, identifier))
    source_parent = create(postgres_engine, alice, "category", category_payload("源父"))
    source_child = create(
        postgres_engine,
        alice,
        "category",
        category_payload("源子", parent_id=source_parent["entity_id"]),
    )
    target = create(
        postgres_engine,
        alice,
        "book",
        {
            "name": "只复制配置",
            "currency": "CNY",
            "timezone": "Asia/Shanghai",
            "month_start_day": 1,
            "template": "daily",
            "icon": "book",
            "cover_color": "#123456",
            "show_assets": True,
        },
        scope=alice.principal.user_id,
    )
    target_id = UUID(target["entity_id"])
    target_parent = create(
        postgres_engine, alice, "category", source_parent["payload"], scope=target_id
    )
    create(
        postgres_engine,
        alice,
        "category",
        {**source_child["payload"], "parent_id": target_parent["entity_id"]},
        scope=target_id,
    )
    group = create(postgres_engine, alice, "tag", tag_payload(kind="group"), scope=target_id)
    create(postgres_engine, alice, "tag", tag_payload(group_id=group["entity_id"]), scope=target_id)
    with Session(postgres_engine) as session:
        types = list(
            session.scalars(select(SyncEntity.entity_type).where(SyncEntity.scope_id == target_id))
        )
        assert sorted(types) == ["book", "category", "category", "tag", "tag"]
        assert session.get(SyncEntity, identifier).balance_minor == 99900


def test_legacy_frozen_snapshot_page_hash_survives_new_defaults_and_new_snapshots_are_complete(
    actors, postgres_engine, sync_http
):
    alice, _, _ = actors
    create(postgres_engine, alice, "tag", tag_payload())
    create(postgres_engine, alice, "category", category_payload())
    headers = {"authorization": "Bearer " + alice.token}
    body = {
        "protocol_version": 1,
        "client_id": str(alice.principal.client_id),
        "sync_epoch": epoch(postgres_engine),
        "scope_ids": [str(alice.book_id)],
    }
    status = sync_http.post("/api/v1/sync/snapshots", json=body, headers=headers)
    assert status.status_code == 201
    status = status.json()
    token = status["first_page_token"]
    with Session(postgres_engine) as session:
        snapshot = session.get(SyncSnapshot, UUID(status["snapshot_id"]))
        page = session.scalar(select(SnapshotPage).where(SnapshotPage.snapshot_id == snapshot.id))
        old = deepcopy(page.response)
        for event in old["items"]:
            fields = MANAGEMENT_NEW_FIELDS.get(event["entity_type"], set())
            for field in fields:
                event["data"]["payload"].pop(field, None)
        old["page_sha256"] = content_hash(old["items"])
        page.response = old
        manifest = deepcopy(snapshot.manifest)
        manifest["pages"][0]["sha256"] = old["page_sha256"]
        snapshot.manifest = manifest
        snapshot.manifest_sha256 = content_hash(manifest)
        session.commit()
    reply = sync_http.post(
        f"/api/v1/sync/snapshots/{status['snapshot_id']}/pages",
        json={"client_id": body["client_id"], "page_token": token},
        headers=headers,
    )
    assert reply.status_code == 200
    assert reply.json() == old
    assert content_hash(reply.json()["items"]) == old["page_sha256"]
    # Old immutable changes also retain their original fields through pull.
    with Session(postgres_engine) as session:
        for change in session.scalars(
            select(SyncChange).where(SyncChange.scope_id == alice.book_id)
        ):
            data = deepcopy(change.data)
            for key in MANAGEMENT_NEW_FIELDS[change.entity_type]:
                data["payload"].pop(key, None)
            change.data = data
        for entity in session.scalars(
            select(SyncEntity).where(SyncEntity.scope_id == alice.book_id)
        ):
            data = deepcopy(entity.payload)
            for key in MANAGEMENT_NEW_FIELDS[entity.entity_type]:
                data.pop(key, None)
            entity.payload = data
        session.commit()
    pulled = sync_http.post(
        "/api/v1/sync/pull",
        json={
            "sync_epoch": body["sync_epoch"],
            "cursors": {str(alice.book_id): "0"},
            "limit": 200,
            "page_token": None,
        },
        headers=headers,
    )
    assert pulled.status_code == 200
    for commit in pulled.json()["commits"]:
        for event in commit["events"]:
            assert not MANAGEMENT_NEW_FIELDS[event["entity_type"]].intersection(
                event["data"]["payload"]
            )
    new = sync_http.post("/api/v1/sync/snapshots", json=body, headers=headers).json()
    page = sync_http.post(
        f"/api/v1/sync/snapshots/{new['snapshot_id']}/pages",
        json={"client_id": body["client_id"], "page_token": new["first_page_token"]},
        headers=headers,
    ).json()
    assert content_hash(page["items"]) == page["page_sha256"]
    for event in page["items"]:
        assert MANAGEMENT_NEW_FIELDS[event["entity_type"]].issubset(event["data"]["payload"])
