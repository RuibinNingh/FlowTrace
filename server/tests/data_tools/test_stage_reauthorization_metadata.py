"""New-origin source proof is read-only and cannot authorize rebind/finance."""

import hashlib
import json
import re
from datetime import timedelta
from uuid import UUID, uuid4

import pytest
from pydantic import ValidationError
from sqlalchemy import event, func, select
from sqlalchemy.orm import Session
from sync.helpers import Actor, actor, epoch, revoke, share

from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.models import User, UserSession
from flowtrace_server.auth.service import issue_session
from flowtrace_server.imports.parsers import digest
from flowtrace_server.imports.staging import update_stage_mapping
from flowtrace_server.imports.staging_models import ImportStage
from flowtrace_server.imports.staging_schemas import (
    StageMapping,
    StageMappingUpdate,
    StageReauthorizationMetadata,
)
from flowtrace_server.persistence.registry import Base
from flowtrace_server.sync.common import require_current_client
from flowtrace_server.sync.models import SyncClient

from .test_source_release import published, release
from .test_staging_http import PREFIX, headers, post
from .test_staging_http import stage_http as stage_http
from .test_staging_parse import complete_parse, prepared
from .test_staging_parsers import source_file
from .test_staging_preview import categories
from .test_staging_requirements import source_owner as source_owner

FIELDS = {
    "stage_id",
    "batch_id",
    "stage_version",
    "format",
    "expected_bytes",
    "source_sha256",
    "mapping_hash",
    "status",
    "source_released",
    "expired",
}


def test_metadata_wire_is_closed_minimal_and_contains_no_origin_or_mapping_contents():
    raw = dict(
        stage_id=str(uuid4()),
        batch_id=str(uuid4()),
        stage_version=2,
        format="flowtrace_json",
        expected_bytes=967,
        source_sha256="a" * 64,
        mapping_hash="b" * 64,
        status="applied",
        source_released=True,
        expired=True,
    )
    assert set(StageReauthorizationMetadata.model_validate(raw).model_dump()) == FIELDS
    for patch in (
        {"origin_session_id": str(uuid4())},
        {"client_id": str(uuid4())},
        {"mapping": {}},
        {"source_sha256": "invalid"},
        {"stage_version": True},
        {"status": "uploading"},
    ):
        with pytest.raises(ValidationError):
            StageReauthorizationMetadata.model_validate(raw | patch)


def table_fingerprints(engine):
    """Only hashes reach an assertion; source/session contents never enter logs."""
    with Session(engine) as session:
        return {
            table.name: hashlib.sha256(
                json.dumps(
                    [
                        dict(value)
                        for value in session.execute(
                            select(table).order_by(*table.primary_key.columns)
                        ).mappings()
                    ],
                    default=str,
                    sort_keys=True,
                    ensure_ascii=False,
                ).encode()
            ).hexdigest()
            for table in Base.metadata.sorted_tables
        }


def endpoint(stage):
    return PREFIX + f"/{stage.stage_id}/reauthorization"


@pytest.mark.postgres
def test_lost_mapping_reply_then_revoked_origin_new_client_can_only_read_proof(
    postgres_engine,
    source_owner,
    stage_http,
):
    content = source_file("flowtrace_json", categories(source_owner, 4))
    stage, lease = prepared(postgres_engine, source_owner, content)
    complete_parse(postgres_engine, lease)
    desired = StageMapping(source_namespace="待恢复的原冻结映射 😀")
    # The PUT commits N -> N+1; its response is deliberately not retained.
    with Session(postgres_engine) as session:
        update_stage_mapping(
            session,
            source_owner.principal,
            UUID(stage.stage_id),
            StageMappingUpdate(stage_version=1, mapping=desired),
        )
    with Session(postgres_engine) as session, session.begin():
        session.get(UserSession, source_owner.principal.session_id).revoked_at = session.scalar(
            select(func.clock_timestamp())
        )
    renewed = actor(postgres_engine, source_owner.principal.user_id)
    with Session(postgres_engine) as session:
        assert (
            session.get(SyncClient, (renewed.principal.user_id, renewed.principal.client_id))
            is None
        )
    before = table_fingerprints(postgres_engine)
    seen = []

    def no_dml(_, __, statement, ___, ____, _____):
        seen.append(statement.split(None, 1)[0].upper())
        assert not re.match(
            r"\s*(INSERT|UPDATE|DELETE|TRUNCATE|ALTER|CREATE|DROP)\b", statement, re.I
        )

    event.listen(postgres_engine, "before_cursor_execute", no_dml)
    try:
        response = stage_http.get(endpoint(stage), headers=headers(renewed))
    finally:
        event.remove(postgres_engine, "before_cursor_execute", no_dml)
    assert response.status_code == 200 and seen and "no-store" in response.headers["cache-control"]
    assert table_fingerprints(postgres_engine) == before
    value = response.json()
    assert set(value) == FIELDS and value["stage_version"] == 2
    assert value["source_sha256"] == hashlib.sha256(content).hexdigest()
    assert value["mapping_hash"] == digest(desired.model_dump(mode="json"))
    assert value["status"] == "uploaded" and not value["source_released"] and not value["expired"]
    ordinary = stage_http.get(PREFIX + "/" + stage.stage_id, headers=headers(renewed))
    assert ordinary.status_code == 409
    # Metadata proof permits no implicit new binding and does not weaken CAS.
    wrong = post(
        stage_http,
        renewed,
        {"stage_id": stage.stage_id},
        "reauthorize",
        {
            "stage_version": 1,
            "client_id": str(renewed.principal.client_id),
            "sync_epoch": epoch(postgres_engine),
        },
    )
    assert wrong.status_code == 409
    before_bind = stage_http.get(endpoint(stage), headers=headers(renewed)).json()
    assert before_bind == value
    confirmed = post(
        stage_http,
        renewed,
        {"stage_id": stage.stage_id},
        "reauthorize",
        {
            "stage_version": 2,
            "client_id": str(renewed.principal.client_id),
            "sync_epoch": epoch(postgres_engine),
        },
    )
    assert confirmed.status_code == 200 and confirmed.json()["stage_version"] == 3
    assert confirmed.json()["mapping_hash"] == value["mapping_hash"]


@pytest.mark.postgres
def test_current_existing_client_is_not_renewed_and_foreign_owner_is_not_revealed(
    postgres_engine,
    source_owner,
    stage_http,
):
    stage, _ = prepared(
        postgres_engine, source_owner, source_file("flowtrace_json", categories(source_owner, 1))
    )
    before = table_fingerprints(postgres_engine)
    assert stage_http.get(endpoint(stage), headers=headers(source_owner)).status_code == 200
    assert table_fingerprints(postgres_engine) == before
    outsider = actor(postgres_engine)
    denied = stage_http.get(endpoint(stage), headers=headers(outsider))
    assert denied.status_code == 404 and "source_sha256" not in denied.text
    assert stage_http.get(endpoint(stage)).status_code == 401
    assert (
        stage_http.get(endpoint(stage) + "?origin=false", headers=headers(source_owner)).status_code
        == 422
    )


@pytest.mark.postgres
@pytest.mark.parametrize(
    "change", ["revoked", "access_expired", "client_frozen", "client_expired", "client_epoch"]
)
def test_current_session_and_existing_client_must_still_be_valid(
    postgres_engine,
    source_owner,
    stage_http,
    change,
):
    stage, _ = prepared(
        postgres_engine, source_owner, source_file("flowtrace_json", categories(source_owner, 1))
    )
    renewed = actor(postgres_engine, source_owner.principal.user_id)
    with Session(postgres_engine) as session, session.begin():
        require_current_client(session, renewed.principal)
        token = session.get(UserSession, renewed.principal.session_id)
        client = session.get(SyncClient, (renewed.principal.user_id, renewed.principal.client_id))
        if change == "revoked":
            token.revoked_at = token.created_at
        elif change == "access_expired":
            token.access_expires_at = token.created_at - timedelta(seconds=1)
        elif change == "client_frozen":
            client.frozen = True
        elif change == "client_expired":
            client.valid_until = client.last_seen_at - timedelta(seconds=1)
        else:
            client.sync_epoch = uuid4()
    before = table_fingerprints(postgres_engine)
    response = stage_http.get(endpoint(stage), headers=headers(renewed))
    assert response.status_code == (401 if change in {"revoked", "access_expired"} else 410)
    assert table_fingerprints(postgres_engine) == before


@pytest.mark.postgres
def test_stage_old_epoch_is_rejected_even_for_new_client_without_sync_history(
    postgres_engine,
    source_owner,
    stage_http,
):
    stage, _ = prepared(
        postgres_engine, source_owner, source_file("flowtrace_json", categories(source_owner, 1))
    )
    with Session(postgres_engine) as session, session.begin():
        session.get(ImportStage, UUID(stage.stage_id)).sync_epoch = uuid4()
    renewed = actor(postgres_engine, source_owner.principal.user_id)
    response = stage_http.get(endpoint(stage), headers=headers(renewed))
    assert response.status_code == 409 and response.json()["error"]["code"] == "epoch_changed"


@pytest.mark.postgres
def test_source_expiry_and_release_are_metadata_not_reactivation(
    postgres_engine,
    source_owner,
    stage_http,
):
    _, stage, body = published(postgres_engine, source_owner)
    release(postgres_engine, source_owner, stage, body)
    with Session(postgres_engine) as session, session.begin():
        value = session.get(ImportStage, UUID(stage.stage_id))
        value.created_at -= timedelta(days=8)
        value.expires_at = value.updated_at - timedelta(seconds=1)
    renewed = actor(postgres_engine, source_owner.principal.user_id)
    response = stage_http.get(endpoint(stage), headers=headers(renewed))
    assert response.status_code == 200
    value = response.json()
    assert value["status"] == "applied" and value["expired"] and value["source_released"]
    assert value["stage_version"] == 1
    with Session(postgres_engine) as session:
        assert (
            session.get(ImportStage, UUID(stage.stage_id)).origin_session_id
            == source_owner.principal.session_id
        )


@pytest.mark.postgres
def test_source_owner_metadata_does_not_grant_published_reauthorization_after_scope_revocation(
    postgres_engine,
    source_owner,
    stage_http,
):
    member = actor(postgres_engine)
    share(postgres_engine, source_owner, member)
    _, stage, _ = published(postgres_engine, member, target=source_owner)
    revoke(postgres_engine, source_owner, member)
    renewed = actor(postgres_engine, member.principal.user_id)
    response = stage_http.get(endpoint(stage), headers=headers(renewed))
    assert response.status_code == 200 and response.json()["status"] == "applied"
    denied = post(
        stage_http,
        renewed,
        {"stage_id": stage.stage_id},
        "reauthorize",
        {
            "stage_version": 1,
            "client_id": str(renewed.principal.client_id),
            "sync_epoch": epoch(postgres_engine),
        },
    )
    assert denied.status_code == 403
    assert stage_http.get(endpoint(stage), headers=headers(renewed)).json() == response.json()


@pytest.mark.postgres
def test_other_session_reauth_winner_is_not_proved_by_shared_metadata(
    postgres_engine,
    source_owner,
    stage_http,
):
    stage, _ = prepared(
        postgres_engine, source_owner, source_file("flowtrace_json", categories(source_owner, 1))
    )
    first = actor(postgres_engine, source_owner.principal.user_id)
    winner = actor(postgres_engine, source_owner.principal.user_id)
    old = stage_http.get(endpoint(stage), headers=headers(first)).json()
    confirmed = post(
        stage_http,
        winner,
        {"stage_id": stage.stage_id},
        "reauthorize",
        {
            "stage_version": 1,
            "client_id": str(winner.principal.client_id),
            "sync_epoch": epoch(postgres_engine),
        },
    )
    assert confirmed.status_code == 200 and confirmed.json()["stage_version"] == 2
    proof = stage_http.get(endpoint(stage), headers=headers(first))
    assert proof.status_code == 200 and proof.json()["stage_version"] == 2
    assert proof.json()["mapping_hash"] == old["mapping_hash"]
    assert proof.json()["source_sha256"] == old["source_sha256"]
    ordinary_path = PREFIX + "/" + stage.stage_id
    assert stage_http.get(ordinary_path, headers=headers(first)).status_code == 409
    assert stage_http.get(ordinary_path, headers=headers(winner)).status_code == 200
    assert (
        post(
            stage_http,
            first,
            {"stage_id": stage.stage_id},
            "reauthorize",
            {
                "stage_version": 1,
                "client_id": str(first.principal.client_id),
                "sync_epoch": epoch(postgres_engine),
            },
        ).status_code
        == 409
    )


@pytest.mark.postgres
def test_web_api_metadata_is_read_only_and_admin_purpose_cannot_read_it(
    postgres_engine,
    source_owner,
    stage_http,
):
    stage, _ = prepared(
        postgres_engine, source_owner, source_file("flowtrace_json", categories(source_owner, 1))
    )
    peers = []
    for purpose in ("api_web", "admin"):
        with Session(postgres_engine) as session, session.begin():
            record, token = issue_session(
                session,
                session.get(User, source_owner.principal.user_id),
                uuid4(),
                "合成只读元数据",
                purpose,
            )
            peers.append(
                Actor(
                    Principal(
                        record.user_id,
                        record.id,
                        record.client_id,
                        record.purpose,
                        frozenset(),
                    ),
                    token["access_token"],
                    source_owner.book_id,
                )
            )
    before = table_fingerprints(postgres_engine)
    assert stage_http.get(endpoint(stage), headers=headers(peers[0])).status_code == 200
    assert stage_http.get(endpoint(stage), headers=headers(peers[1])).status_code == 403
    assert table_fingerprints(postgres_engine) == before
