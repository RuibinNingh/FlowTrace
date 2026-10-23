"""Real source-derived requirements: invalid rows, versions, privacy and release."""

import csv
import hashlib
import io
from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from openpyxl import Workbook
from sqlalchemy import delete, event, func, select, text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.orm import Session
from sync.helpers import actor, epoch

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.imports import staging_requirements
from flowtrace_server.imports.models import ImportBatch
from flowtrace_server.imports.parsers import canonical, digest
from flowtrace_server.imports.staging import cancel_stage, reauthorize_stage, update_stage_mapping
from flowtrace_server.imports.staging_cleanup import expire_owned_stages_in_transaction
from flowtrace_server.imports.staging_models import (
    ImportStage,
    ImportStageRequirement,
    ImportStageRow,
    ImportStageSourceRelease,
)
from flowtrace_server.imports.staging_reauthorize import reauthorize_published_stage
from flowtrace_server.imports.staging_requirements import stage_requirements
from flowtrace_server.imports.staging_schemas import StageMappingUpdate, StageReauthorize
from flowtrace_server.jobs import store
from flowtrace_server.jobs.models import BackgroundJob

from .test_source_release import published, release
from .test_staging_http import PREFIX, headers
from .test_staging_http import stage_http as stage_http
from .test_staging_parse import complete_parse, prepared
from .test_staging_parsers import bill_row, native_row, source_file
from .test_staging_preview import claim_exact

pytestmark = pytest.mark.postgres


@pytest.fixture
def source_owner(postgres_engine):
    owner = actor(postgres_engine)
    yield owner
    # Preserve all source/financial history; cancel only this fixture's intents.
    with Session(postgres_engine) as session, session.begin():
        for job in session.scalars(
            select(BackgroundJob).where(
                BackgroundJob.owner_user_id == owner.principal.user_id,
                BackgroundJob.kind.in_(["import_preview", "import_apply"]),
                BackgroundJob.status.in_(["pending", "running", "retry_wait"]),
            )
        ):
            store.cancel(session, job.id)


def qianji_file(records, format_name="qianji_csv"):
    columns = [
        "时间",
        "类型",
        "金额",
        "账户1",
        "账户2",
        "分类",
        "二级分类",
        "标签",
        "账单图片",
        "备注",
    ]
    rows = [columns] + [[record.get(key, "") for key in columns] for record in records]
    if format_name.endswith("csv"):
        output = io.StringIO(newline="")
        csv.writer(output).writerows(rows)
        return output.getvalue().encode()
    workbook = Workbook()
    for row in rows:
        workbook.active.append(row)
    output = io.BytesIO()
    workbook.save(output)
    return output.getvalue()


def qianji_mapping(owner):
    return {
        "template_mapping": {
            "scope_id": str(owner.book_id),
            "timezone": "Asia/Shanghai",
        }
    }


def parsed(engine, owner, content, format_name="flowtrace_json", mapping=None):
    stage, lease = prepared(engine, owner, content, format_name, mapping)
    result = complete_parse(engine, lease)
    return stage, result


def page(engine, owner, stage, *, version=1, cursor=None, limit=100):
    with Session(engine) as session:
        return stage_requirements(
            session,
            owner.principal,
            UUID(stage.stage_id),
            stage_version=version,
            cursor=cursor,
            limit=limit,
        )


def all_items(engine, owner, stage, *, version=1, limit=100):
    result, cursor, expected_hash = [], None, None
    while True:
        current = page(engine, owner, stage, version=version, cursor=cursor, limit=limit)
        expected_hash = expected_hash or current.requirements_hash
        assert expected_hash == current.requirements_hash
        result.extend(current.items)
        if not current.has_more:
            break
        cursor = current.next_cursor
    assert [item.position for item in result] == list(range(1, len(result) + 1))
    assert digest([item.model_dump(mode="json") for item in result]) == expected_hash
    return result


@pytest.mark.parametrize("format_name", ["qianji_csv", "qianji_xlsx"])
def test_invalid_v10_rows_still_have_complete_original_names_without_notes_or_amounts(
    postgres_engine,
    source_owner,
    format_name,
):
    record = {
        "时间": "2026-10-20",
        "类型": "转账",
        "金额": "invalid exact amount",
        "账户1": "现金",
        "账户2": "储蓄 卡",
        "分类": "父类",
        "二级分类": "午餐",
        "标签": "工作#旅行",
        "账单图片": '["http://127.0.0.1/never-fetch.png","相册图片"]',
        "备注": "私人备注\n跨行原文",
    }
    stage, result = parsed(
        postgres_engine,
        source_owner,
        qianji_file([record] * 61, format_name),
        format_name,
        qianji_mapping(source_owner),
    )
    assert result == {"code": "import_stage_parsed_with_errors", "created_count": 61}
    items = all_items(postgres_engine, source_owner, stage, limit=3)
    assert [(item.kind, item.source_key) for item in items] == [
        ("account", "现金"),
        ("account", "储蓄 卡"),
        ("category", "午餐"),
        ("tag", "工作"),
        ("tag", "旅行"),
        ("image", "http://127.0.0.1/never-fetch.png"),
        ("image", "相册图片"),
    ]
    assert all(item.first_line == 2 and item.source_kind == "name" for item in items)
    assert all(item.attachment_source is None for item in items)
    assert "私人备注" not in str(items) and "invalid exact amount" not in str(items)
    with Session(postgres_engine) as session:
        assert session.get(ImportStageRow, (UUID(stage.stage_id), 1)).row_payload is None
        assert not session.scalar(
            select(ImportBatch.id).where(
                ImportBatch.user_id == source_owner.principal.user_id,
            )
        )


def test_csv_first_line_uses_physical_blank_and_multiline_cells(postgres_engine, source_owner):
    content = (
        '时间,类型,金额,账户1,备注\r\n\r\n2026-10-20,支出,bad,现金,"第一行\n第二行"\r\n'
        "\r\n2026-10-20,支出,bad,银行卡,私人备注\r\n"
    ).encode()
    stage, _ = parsed(
        postgres_engine,
        source_owner,
        content,
        "qianji_csv",
        qianji_mapping(source_owner),
    )
    assert [
        (value.source_key, value.first_line)
        for value in all_items(
            postgres_engine,
            source_owner,
            stage,
        )
    ] == [("现金", 3), ("银行卡", 6)]


@pytest.mark.parametrize("format_name", ["flowtrace_json", "flowtrace_csv", "flowtrace_xlsx"])
def test_native_invalid_bill_keeps_known_refs_but_excludes_forward_source_definitions(
    postgres_engine,
    source_owner,
    format_name,
):
    bill, defined = bill_row(), native_row()
    scope, account, tag, image, source_bill = (str(uuid4()) for _ in range(5))
    bill["scope_id"] = defined["scope_id"] = scope
    bill["payload"].update(
        money={"currency": "CNY", "currency_scale": 2, "amount_minor": "invalid"},
        account_id=account,
        category_id=defined["source_id"],
        tag_ids=[tag],
        attachment_ids=[image],
        allocations=[{"source_bill_id": source_bill, "amount_minor": "invalid"}],
        note="无权据此推断金融原文",
    )
    stage, _ = parsed(
        postgres_engine,
        source_owner,
        source_file(format_name, [bill, defined]),
        format_name,
    )
    items = all_items(postgres_engine, source_owner, stage)
    assert [(item.kind, item.resource_type, item.source_key) for item in items] == [
        ("scope", "book", scope),
        ("resource", "account", account),
        ("resource", "tag", tag),
        ("image", None, image),
        ("resource", "bill", source_bill),
    ]
    assert all(item.source_kind == "identifier" for item in items)
    assert all(item.source_key != defined["source_id"] for item in items)


def test_native_manifest_is_available_for_image_matching_without_reading_urls(
    postgres_engine,
    source_owner,
):
    bill, image = bill_row(), str(uuid4())
    bill["scope_id"] = str(source_owner.book_id)
    bill["payload"]["attachment_ids"] = [image]
    source = dict(attachment_id=image, sha256="b" * 64, size_bytes=77, media_type="image/png")
    envelope = {
        "format": "flowtrace-export-v1",
        "document": {"format": "flowtrace-data-v1", "source_namespace": "真实引用", "rows": [bill]},
        "attachments": [source | {"href": f"/api/v1/attachments/{image}/content"}],
    }
    stage, _ = parsed(postgres_engine, source_owner, canonical(envelope))
    images = [
        item for item in all_items(postgres_engine, source_owner, stage) if item.kind == "image"
    ]
    assert len(images) == 1 and images[0].attachment_source.model_dump() == {
        "source_id": image,
        "sha256": "b" * 64,
        "size_bytes": 77,
        "media_type": "image/png",
    }


def test_fixed_hash_pages_never_read_source_again_and_reject_wrong_generation(
    postgres_engine,
    source_owner,
):
    records = [
        dict(时间="2026-10-20", 类型="支出", 金额="bad", 账户1=f"卡{index}") for index in range(205)
    ]
    stage, _ = parsed(
        postgres_engine,
        source_owner,
        qianji_file(records),
        "qianji_csv",
        qianji_mapping(source_owner),
    )

    def no_source(_, __, statement, ___, ____, _____):
        assert "import_stage_upload_chunks" not in statement.lower()
        assert "import_stage_rows" not in statement.lower()

    event.listen(postgres_engine, "before_cursor_execute", no_source)
    try:
        first = page(postgres_engine, source_owner, stage)
        items = all_items(postgres_engine, source_owner, stage, limit=83)
    finally:
        event.remove(postgres_engine, "before_cursor_execute", no_source)
    assert len(items) == 205 and first.has_more
    assert [item.source_key for item in items] == [f"卡{index}" for index in range(205)]
    with Session(postgres_engine) as session, session.begin():
        session.get(ImportStage, UUID(stage.stage_id)).requirements_hash = "f" * 64
    with pytest.raises(ApiError, match="import_stage_requirements_cursor_invalid"):
        page(postgres_engine, source_owner, stage, cursor=first.next_cursor)


def test_mapping_and_unpublished_reauth_clear_old_derivation_and_reparse_new_version(
    postgres_engine,
    source_owner,
):
    content = qianji_file([dict(时间="2026-10-20", 类型="支出", 金额="bad", 账户1="现金")])
    stage, _ = parsed(
        postgres_engine,
        source_owner,
        content,
        "qianji_csv",
        qianji_mapping(source_owner),
    )
    first = page(postgres_engine, source_owner, stage)
    with Session(postgres_engine) as session:
        changed = update_stage_mapping(
            session,
            source_owner.principal,
            UUID(stage.stage_id),
            StageMappingUpdate(stage_version=1, mapping=qianji_mapping(source_owner)),
        )
        assert changed.requirements_version is None and changed.requirements_count == 0
    with pytest.raises(ApiError, match="import_stage_version_changed"):
        page(postgres_engine, source_owner, stage)
    complete_parse(postgres_engine, claim_exact(postgres_engine, changed.parse_job_id))
    assert page(postgres_engine, source_owner, stage, version=2).requirements_hash == (
        first.requirements_hash
    )
    renewed = actor(postgres_engine, source_owner.principal.user_id)
    with Session(postgres_engine) as session:
        rebound = reauthorize_stage(
            session,
            renewed.principal,
            UUID(stage.stage_id),
            StageReauthorize(
                stage_version=2,
                client_id=str(renewed.principal.client_id),
                sync_epoch=epoch(postgres_engine),
            ),
        )
        assert rebound.requirements_version is None and rebound.requirements_count == 0
    complete_parse(postgres_engine, claim_exact(postgres_engine, rebound.parse_job_id))
    with pytest.raises(ApiError, match="import_stage_reauthorization_required"):
        page(postgres_engine, source_owner, stage, version=3)
    assert page(postgres_engine, renewed, stage, version=3).items[0].source_key == "现金"


def test_legacy_missing_metadata_is_not_a_valid_empty_requirements_page(
    postgres_engine,
    source_owner,
):
    stage, _ = parsed(postgres_engine, source_owner, source_file("flowtrace_json", [native_row()]))
    with Session(postgres_engine) as session, session.begin():
        row = session.get(ImportStage, UUID(stage.stage_id))
        session.execute(
            delete(ImportStageRequirement).where(ImportStageRequirement.stage_id == row.id)
        )
        row.requirements_version = row.requirements_hash = None
        row.requirements_count = 0
    with pytest.raises(ApiError, match="import_stage_requirements_unavailable"):
        page(postgres_engine, source_owner, stage)


def test_zero_external_requirements_have_a_formal_empty_hash(postgres_engine, source_owner):
    row = native_row()
    row.update(
        entity_type="book",
        payload={
            "name": "新账本",
            "currency": "CNY",
            "timezone": "Asia/Shanghai",
            "month_start_day": 1,
        },
    )
    stage, _ = parsed(postgres_engine, source_owner, source_file("flowtrace_json", [row]))
    empty = page(postgres_engine, source_owner, stage)
    assert empty.items == [] and not empty.has_more and empty.next_cursor is None
    assert empty.requirements_hash == hashlib.sha256(b"[]").hexdigest()


def test_unique_limit_and_hash_collision_fail_closed_without_partial_derivation(
    postgres_engine,
    source_owner,
    monkeypatch,
):
    monkeypatch.setattr(staging_requirements, "STAGE_MAX_REQUIREMENTS", 3)
    records = [
        dict(时间="2026-10-20", 类型="支出", 金额="bad", 账户1=f"卡{index}") for index in range(4)
    ]
    stage, result = parsed(
        postgres_engine,
        source_owner,
        qianji_file(records),
        "qianji_csv",
        qianji_mapping(source_owner),
    )
    assert result == {"code": "too_many_mapping_requirements", "created_count": 0}
    with Session(postgres_engine) as session:
        row = session.get(ImportStage, UUID(stage.stage_id))
        assert row.status == "failed" and row.requirements_version is None
        assert not session.scalar(
            select(ImportStageRequirement.position).where(ImportStageRequirement.stage_id == row.id)
        )
    monkeypatch.setattr(staging_requirements, "key_hash", lambda item: "a" * 64)
    _, result = parsed(
        postgres_engine,
        source_owner,
        qianji_file(records[:2]),
        "qianji_csv",
        qianji_mapping(source_owner),
    )
    assert result == {"code": "mapping_requirement_hash_collision", "created_count": 0}


def test_budget_after_persist_rolls_back_rows_requirements_and_job_result(
    postgres_engine,
    source_owner,
):
    stage, lease = prepared(
        postgres_engine,
        source_owner,
        source_file("flowtrace_json", [native_row()]),
    )

    def budget():
        # This listener observes only the worker connection after the new INSERT.
        if inserted:
            raise RuntimeError("requirements-budget-expired")

    inserted = False

    def listener(_, __, statement, ___, ____, _____):
        nonlocal inserted
        if statement.lower().startswith("insert into import_stage_requirements"):
            inserted = True

    event.listen(postgres_engine, "after_cursor_execute", listener)
    try:
        with pytest.raises(RuntimeError, match="requirements-budget-expired"):
            complete_parse(postgres_engine, lease, budget)
    finally:
        event.remove(postgres_engine, "after_cursor_execute", listener)
    with Session(postgres_engine) as session:
        row = session.get(ImportStage, UUID(stage.stage_id))
        assert row.status == "uploaded" and row.requirements_version is None
        assert not session.scalar(
            select(ImportStageRequirement.position).where(ImportStageRequirement.stage_id == row.id)
        )
        assert not session.scalar(
            select(ImportStageRow.position).where(ImportStageRow.stage_id == row.id)
        )
        assert session.get(BackgroundJob, lease.job_id).result is None
    assert complete_parse(postgres_engine, lease)["created_count"] == 1


def test_cancel_and_expiry_remove_only_this_stage_derived_names(postgres_engine, source_owner):
    one, _ = parsed(postgres_engine, source_owner, source_file("flowtrace_json", [native_row()]))
    two, _ = parsed(postgres_engine, source_owner, source_file("flowtrace_json", [native_row()]))
    kept = page(postgres_engine, source_owner, two)
    with Session(postgres_engine) as session:
        cancelled = cancel_stage(session, source_owner.principal, UUID(one.stage_id), 1)
        assert cancelled.requirements_version is None and cancelled.requirements_count == 0
    assert page(postgres_engine, source_owner, two) == kept
    with Session(postgres_engine) as session, session.begin():
        row = session.get(ImportStage, UUID(two.stage_id))
        row.created_at -= timedelta(days=8)
        row.expires_at = session.scalar(select(func.clock_timestamp())) - timedelta(seconds=1)
    with Session(postgres_engine) as session, session.begin():
        assert expire_owned_stages_in_transaction(
            session,
            source_owner.principal.user_id,
            check_budget=lambda: None,
        ) == (UUID(two.stage_id),)
    with Session(postgres_engine) as session:
        assert not session.scalar(
            select(ImportStageRequirement.position).where(
                ImportStageRequirement.stage_id.in_([UUID(one.stage_id), UUID(two.stage_id)])
            )
        )


def test_published_reauth_keeps_hash_then_source_release_audits_actual_derived_deletion(
    postgres_engine,
    source_owner,
):
    owner, stage, body = published(postgres_engine, source_owner)
    original = page(postgres_engine, owner, stage)
    renewed = actor(postgres_engine, owner.principal.user_id)
    with Session(postgres_engine) as session:
        rebound = reauthorize_published_stage(
            session,
            renewed.principal,
            UUID(stage.stage_id),
            StageReauthorize(
                stage_version=1,
                client_id=str(renewed.principal.client_id),
                sync_epoch=epoch(postgres_engine),
            ),
            check_budget=lambda: None,
        )
        assert rebound.requirements_version == 2
    current = page(postgres_engine, renewed, stage, version=2)
    assert (
        current.items == original.items and current.requirements_hash == original.requirements_hash
    )
    body = body.model_copy(
        update={"stage_version": 2, "client_id": str(renewed.principal.client_id)}
    )
    receipt = release(postgres_engine, renewed, stage, body)
    assert receipt.deleted_requirement_rows == len(current.items) == 1
    assert release(postgres_engine, renewed, stage, body).replayed
    with pytest.raises(ApiError, match="import_stage_source_released"):
        page(postgres_engine, renewed, stage, version=2)
    with Session(postgres_engine) as session:
        assert (
            session.get(ImportStageSourceRelease, UUID(stage.stage_id)).deleted_requirement_rows
            == 1
        )


def test_http_private_paginated_actual_byte_limit_and_foreign_rejection(
    postgres_engine,
    source_owner,
    stage_http,
):
    records = [
        dict(时间="2026-10-20", 类型="支出", 金额="bad", 账户1="\x01" * 1995 + f"{i:05d}")
        for i in range(101)
    ]
    stage, _ = parsed(
        postgres_engine,
        source_owner,
        qianji_file(records),
        "qianji_csv",
        qianji_mapping(source_owner),
    )
    path = PREFIX + f"/{stage.stage_id}/requirements"
    response = stage_http.get(path, headers=headers(source_owner), params={"stage_version": 1})
    assert response.status_code == 200 and len(response.content) <= 1024 * 1024
    body = response.json()
    assert 0 < len(body["items"]) < 100 and body["has_more"]
    assert "no-store" in response.headers["cache-control"]
    tail = stage_http.get(
        path,
        headers=headers(source_owner),
        params={
            "stage_version": 1,
            "cursor": body["next_cursor"],
        },
    )
    assert tail.status_code == 200 and not tail.json()["has_more"]
    assert len(body["items"]) + len(tail.json()["items"]) == 101
    foreign = actor(postgres_engine)
    denied = stage_http.get(path, headers=headers(foreign), params={"stage_version": 1})
    assert denied.status_code == 404 and "items" not in denied.text
    for query in (
        "stage_version=1&stage_version=1",
        "stage_version=1&limit=101",
        "stage_version=1&cursor=bad",
        "stage_version=1&url=http://invalid",
    ):
        assert stage_http.get(path + "?" + query, headers=headers(source_owner)).status_code == 422


def test_sql_checks_reject_null_bypass_wrong_key_and_unpaired_manifest(
    postgres_engine, source_owner
):
    stage, _ = parsed(postgres_engine, source_owner, source_file("flowtrace_json", [native_row()]))
    with Session(postgres_engine) as session, session.begin():
        for statement in (
            "UPDATE import_stages SET requirements_version=NULL WHERE id=:id",
            "UPDATE import_stage_requirements SET source_key='arbitrary' WHERE stage_id=:id",
            "UPDATE import_stage_requirements SET attachment_size_bytes=77 WHERE stage_id=:id",
        ):
            with pytest.raises(DBAPIError) as failure:
                with session.begin_nested():
                    session.execute(text(statement), {"id": UUID(stage.stage_id)})
            assert failure.value.orig.sqlstate == "23514"
            assert session.scalar(text("SELECT 1")) == 1
