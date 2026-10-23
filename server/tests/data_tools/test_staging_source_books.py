"""Explicit same-batch book choice never guesses current resource permissions."""

from uuid import UUID, uuid4

import pytest
from sqlalchemy import event
from sqlalchemy.orm import Session
from sync.helpers import actor

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.imports.staging import update_stage_mapping
from flowtrace_server.imports.staging_schemas import StageMappingUpdate
from flowtrace_server.imports.staging_source_books import stage_source_books

from .test_import_attachments import ready_image
from .test_source_release import published, release
from .test_staging_holds import image_stage
from .test_staging_http import PREFIX, headers
from .test_staging_http import stage_http as stage_http
from .test_staging_parse import complete_parse, prepared
from .test_staging_parsers import native_row, source_file
from .test_staging_requirements import source_owner as source_owner

pytestmark = pytest.mark.postgres


def book(owner, index):
    return dict(
        source_id=str(uuid4()),
        entity_type="book",
        scope_id=str(owner.principal.user_id),
        payload=dict(
            name=f"原账本 {index} 😀",
            currency="CNY",
            timezone="Asia/Shanghai",
            month_start_day=15,
            display_mode="year",
        ),
    )


def page(engine, owner, stage, **kwargs):
    with Session(engine) as session:
        return stage_source_books(
            session,
            owner.principal,
            UUID(stage.stage_id),
            stage_version=kwargs.pop("stage_version", 1),
            **kwargs,
        )


def test_sparse_original_book_rows_are_complete_bounded_and_no_source_io(
    postgres_engine, source_owner, stage_http
):
    rows = [native_row() if index % 2 == 0 else book(source_owner, index) for index in range(205)]
    stage, lease = prepared(postgres_engine, source_owner, source_file("flowtrace_json", rows))
    complete_parse(postgres_engine, lease)
    statements = []

    def sql(_, __, statement, ___, ____, _____):
        statements.append(statement)
        assert "import_stage_upload_chunks" not in statement

    event.listen(postgres_engine, "before_cursor_execute", sql)
    try:
        first = stage_http.get(
            PREFIX + f"/{stage.stage_id}/source-books",
            params={"stage_version": 1, "limit": 100},
            headers=headers(source_owner),
        )
    finally:
        event.remove(postgres_engine, "before_cursor_execute", sql)
    assert first.status_code == 200 and statements
    value = first.json()
    assert set(value) == {"stage_id", "stage_version", "count", "items", "has_more", "next_cursor"}
    assert value["count"] == 102 and len(value["items"]) == 100 and value["has_more"]
    assert [item["position"] for item in value["items"]] == list(range(2, 201, 2))
    assert set(value["items"][0]) == {"position", "source_id", "name", "currency", "timezone"}
    assert value["items"][0] == dict(
        position=2,
        source_id=rows[1]["source_id"],
        **{key: rows[1]["payload"][key] for key in ("name", "currency", "timezone")},
    )
    last = page(postgres_engine, source_owner, stage, cursor=value["next_cursor"])
    assert last.count == 102 and [item.position for item in last.items] == [202, 204]
    assert not last.has_more and last.next_cursor is None
    assert len(first.content) < 1024 * 1024 and "no-store" in first.headers["cache-control"]


def test_source_books_list_contains_same_batch_image_destination_source_id(
    postgres_engine, source_owner, tmp_path
):
    uploaded, _, original, _ = ready_image(postgres_engine, source_owner, tmp_path / "images")
    stage, mapping = image_stage(postgres_engine, source_owner, uploaded, original)
    result = page(postgres_engine, source_owner, stage)
    assert result.count == 1 and len(result.items) == 1
    original_book = next(iter(mapping["attachment_transfers"].values()))
    assert result.items[0].source_id == original_book
    assert result.items[0].position == 3 and result.items[0].name == "含图迁移"


def test_version_origin_owner_cursor_and_query_are_strict(
    postgres_engine, source_owner, stage_http
):
    rows = [book(source_owner, index) for index in range(3)]
    stage, lease = prepared(postgres_engine, source_owner, source_file("flowtrace_json", rows))
    complete_parse(postgres_engine, lease)
    first = page(postgres_engine, source_owner, stage, limit=1)
    other = actor(postgres_engine)
    with pytest.raises(ApiError, match="import_stage_not_found"):
        page(postgres_engine, other, stage)
    renewed = actor(postgres_engine, source_owner.principal.user_id)
    with pytest.raises(ApiError, match="import_stage_reauthorization_required"):
        page(postgres_engine, renewed, stage)
    with pytest.raises(ApiError, match="import_stage_version_changed"):
        page(postgres_engine, source_owner, stage, stage_version=2)
    for cursor in ("!", first.next_cursor + "=", "x" * 513):
        with pytest.raises(ApiError, match="import_stage_source_books_cursor_invalid"):
            page(postgres_engine, source_owner, stage, cursor=cursor)
    path = PREFIX + f"/{stage.stage_id}/source-books?stage_version=1"
    for suffix in ("&limit=101", "&limit=0", "&stage_version=1", "&all=true"):
        response = stage_http.get(path + suffix, headers=headers(source_owner))
        assert response.status_code == 422
    with Session(postgres_engine) as session:
        update_stage_mapping(
            session,
            source_owner.principal,
            UUID(stage.stage_id),
            StageMappingUpdate(stage_version=1, mapping={}),
        )
    with pytest.raises(ApiError, match="import_stage_source_books_unavailable"):
        page(postgres_engine, source_owner, stage, stage_version=2, cursor=first.next_cursor)


def test_uploaded_unparsed_not_empty_success_and_released_source_is_gone(
    postgres_engine, source_owner
):
    stage, _ = prepared(
        postgres_engine, source_owner, source_file("flowtrace_json", [book(source_owner, 1)])
    )
    with pytest.raises(ApiError, match="import_stage_source_books_unavailable"):
        page(postgres_engine, source_owner, stage)
    owner, financial, release_body = published(postgres_engine)
    release(postgres_engine, owner, financial, release_body)
    with pytest.raises(ApiError, match="import_stage_source_released"):
        page(postgres_engine, owner, financial)
