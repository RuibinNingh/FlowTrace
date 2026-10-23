"""GET proves normalized desired state after a lost PUT reply, not write rights."""

import hashlib
import json
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from sqlalchemy.orm import Session
from sync.helpers import actor

from flowtrace_server.imports.parsers import canonical, digest
from flowtrace_server.imports.staging_models import ImportStage
from flowtrace_server.imports.staging_schemas import StageMapping

from .test_staging_http import PREFIX, create, headers, status
from .test_staging_http import stage_http as stage_http

GOLDEN = json.loads(
    (Path(__file__).parent / "fixtures/stage_mapping_golden.json").read_text("utf-8")
)


@pytest.mark.parametrize("case", GOLDEN["cases"], ids=lambda case: case["name"])
def test_cross_language_golden_normalizes_defaults_and_unicode_scalar_order(case):
    normalized = StageMapping.model_validate(case["input"]).model_dump(mode="json")
    assert normalized == case["normalized"]
    assert canonical(normalized).decode("utf-8") == case["canonical_json"]
    assert hashlib.sha256(case["canonical_json"].encode()).hexdigest() == case["sha256"]
    assert digest(normalized) == case["sha256"]


@pytest.mark.postgres
def test_lost_mapping_reply_get_matches_only_exact_next_version_and_frozen_normalized_hash(
    postgres_engine,
    stage_http,
):
    owner = actor(postgres_engine)
    stage, _, _ = create(stage_http, postgres_engine, owner, count=3)
    mapping = {
        "source_namespace": "新的映射 😀",
        "scope_mapping": {str(uuid4()): str(owner.book_id)},
    }
    frozen_body = {"stage_version": 1, "mapping": mapping}
    original_bytes = canonical(frozen_body)
    expected = digest(StageMapping.model_validate(mapping).model_dump(mode="json"))
    path = PREFIX + f"/{stage['stage_id']}/mapping"
    # Server success is deliberately discarded, simulating a lost transport reply.
    assert stage_http.put(path, headers=headers(owner), json=frozen_body).status_code == 200
    recovered = status(stage_http, owner, stage)
    assert recovered["stage_version"] == 2 and recovered["mapping_hash"] == expected
    assert "mapping" not in recovered and canonical(frozen_body) == original_bytes
    conflict = stage_http.put(path, headers=headers(owner), json=frozen_body)
    assert conflict.status_code == 409 and canonical(frozen_body) == original_bytes
    assert status(stage_http, owner, stage)["stage_version"] == 2
    # An unrelated later version is not proof that the original N -> N+1 command
    # is the one being acknowledged, even when its desired mapping is identical.
    assert (
        stage_http.put(
            path,
            headers=headers(owner),
            json={
                "stage_version": 2,
                "mapping": mapping,
            },
        ).status_code
        == 200
    )
    later = status(stage_http, owner, stage)
    assert later["stage_version"] == 3 and later["mapping_hash"] == expected


@pytest.mark.postgres
def test_legacy_empty_mapping_get_hash_includes_normalized_defaults(postgres_engine, stage_http):
    owner = actor(postgres_engine)
    stage, _, _ = create(stage_http, postgres_engine, owner, count=1)
    with Session(postgres_engine) as session, session.begin():
        session.get(ImportStage, UUID(stage["stage_id"])).mapping = {}
    recovered = status(stage_http, owner, stage)
    assert recovered["mapping_hash"] == GOLDEN["cases"][0]["sha256"]
    assert recovered["mapping_hash"] != digest({})
