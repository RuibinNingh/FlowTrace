"""Closed source-reference wire and 0015 candidate DDL, without PG effects."""

from uuid import uuid4

import pytest
from pydantic import ValidationError
from sqlalchemy.dialects import postgresql
from sqlalchemy.schema import CreateTable

from flowtrace_server.imports.staging_models import (
    ImportStage,
    ImportStageRequirement,
    ImportStageSourceRelease,
)
from flowtrace_server.imports.staging_schemas import StageRequirement, StageRequirementsPage
from flowtrace_server.persistence.registry import Base


def named(**changes):
    return dict(
        position=1,
        kind="account",
        source_kind="name",
        source_key="现金 卡/原名",
        resource_type=None,
        first_line=200005,
        attachment_source=None,
    ) | changes


def test_qianji_keys_preserve_original_text_and_physical_line_without_financial_text():
    item = StageRequirement.model_validate(named())
    assert item.source_key == "现金 卡/原名" and item.first_line == 200005
    url = "http://127.0.0.1/仅原引用.png?x=1"
    assert StageRequirement.model_validate(named(kind="image", source_key=url)).source_key == url
    for patch in (
        {"amount_minor": "123"},
        {"note": "私人备注"},
        {"path": "never-read"},
        {"source_key": "\x00"},
        {"source_key": "长" * 2001},
        {"first_line": True},
        {"source_kind": "url"},
        {"kind": "scope"},
        {"resource_type": "account"},
    ):
        with pytest.raises(ValidationError):
            StageRequirement.model_validate(named(**patch))


def test_native_identifiers_require_explicit_kind_and_expected_type():
    identifier = str(uuid4())
    native = named(
        kind="resource", source_kind="identifier", source_key=identifier, resource_type="account"
    )
    assert StageRequirement.model_validate(native).source_key == identifier
    for patch in (
        {"source_key": "不是UUID"},
        {"kind": "account"},
        {"resource_type": None},
        {"resource_type": "user"},
        {"kind": "image", "resource_type": "book"},
    ):
        with pytest.raises(ValidationError):
            StageRequirement.model_validate(native | patch)
    assert StageRequirement.model_validate(native | {"kind": "scope", "resource_type": "book"})


def test_native_image_manifest_is_optional_closed_and_bound_to_same_source_id():
    image = str(uuid4())
    body = named(kind="image", source_kind="identifier", source_key=image)
    source = dict(source_id=image, sha256="a" * 64, size_bytes=77, media_type="image/png")
    assert StageRequirement.model_validate(body).attachment_source is None
    assert StageRequirement.model_validate(body | {"attachment_source": source}).attachment_source
    for patch in (
        {"source_id": str(uuid4())},
        {"href": "http://invalid/never-fetch"},
        {"size_bytes": 0},
    ):
        with pytest.raises(ValidationError):
            StageRequirement.model_validate(body | {"attachment_source": source | patch})
    with pytest.raises(ValidationError):
        StageRequirement.model_validate(named(attachment_source=source))


def test_page_is_version_hash_bound_ordered_and_explicitly_continued():
    body = dict(
        stage_id=str(uuid4()), stage_version=2, requirements_hash="b" * 64,
        items=[named()], has_more=True, next_cursor="opaque",
    )
    assert StageRequirementsPage.model_validate(body).items[0].first_line == 200005
    for patch in (
        {"requirements_hash": "bad"},
        {"has_more": False},
        {"next_cursor": None},
        {"items": []},
        {"items": [named(position=2), named(position=1)]},
        {"items": [named()] * 101},
    ):
        with pytest.raises(ValidationError):
            StageRequirementsPage.model_validate(body | patch)


def test_candidate_uses_narrow_hashed_identity_and_explicit_legacy_metadata():
    assert "users" in Base.metadata.tables
    ddl = str(CreateTable(ImportStageRequirement.__table__).compile(dialect=postgresql.dialect()))
    assert "PRIMARY KEY (stage_id, position)" in ddl
    assert "UNIQUE (stage_id, parsed_version, key_sha256)" in ddl
    assert "source_key TEXT NOT NULL" in ddl and "first_line BIGINT NOT NULL" in ddl
    assert "char_length(source_key) BETWEEN 1 AND 2000" in ddl
    assert "attachment_size_bytes BETWEEN 1 AND 10485760" in ddl
    assert "FOREIGN KEY(stage_id) REFERENCES import_stages (id)" in ddl
    stage = str(CreateTable(ImportStage.__table__).compile(dialect=postgresql.dialect()))
    assert "requirements_version IS NOT NULL" in stage
    assert "requirements_version IS NULL AND requirements_hash IS NULL" in stage
    assert ImportStage.__table__.c.requirements_count.server_default.arg == "0"
    assert ImportStage.__table__.c.requirements_version.nullable
    audit = str(
        CreateTable(ImportStageSourceRelease.__table__).compile(dialect=postgresql.dialect())
    )
    assert "deleted_requirement_rows BETWEEN 0 AND 200000" in audit
    assert ImportStageSourceRelease.__table__.c.deleted_requirement_rows.server_default.arg == "0"
