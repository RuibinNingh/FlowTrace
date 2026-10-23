"""Real installed 0013 guards; each new metadata fixture is rolled back.

No backup files or existing protected records are deleted for cleanup. Actors
and referenced jobs come from the actual identity/job services. Invalid foreign
keys below are explicit negative inputs, never fabricated positive fixtures.
"""

from dataclasses import dataclass
from datetime import timedelta
from uuid import uuid4

import pytest
from sqlalchemy import insert, null, select, text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.orm import Session
from sync.helpers import actor

from flowtrace_server.backups.retention_models import (
    BackupControl,
    BackupHold,
    BackupPin,
    BackupRetentionIntent,
)
from flowtrace_server.backups.retention_schemas import PackageStamp
from flowtrace_server.configuration.models import ConfigurationHead
from flowtrace_server.jobs import store
from flowtrace_server.persistence.models import ServerState

pytestmark = pytest.mark.postgres
TABLES = {"pin": BackupPin.__table__, "hold": BackupHold.__table__}


@pytest.fixture(scope="module")
def retention_actors(postgres_engine):
    return actor(postgres_engine), actor(postgres_engine)


@dataclass
class Case:
    session: Session
    owner: object
    other: object
    backup_id: object
    other_backup_id: object
    job_id: object
    other_job_id: object
    intent_id: object
    pin_id: object
    hold_id: object
    stamp: object
    instance_id: object
    epoch: object
    config_version: int

    def pin(self):
        return dict(
            id=uuid4(),
            backup_id=self.backup_id,
            created_by=self.owner.principal.user_id,
            create_request_id=uuid4(),
            create_request_hash="a" * 64,
        )

    def hold(self):
        return dict(
            id=uuid4(),
            backup_id=self.backup_id,
            holder_kind="download",
            holder_id=uuid4(),
            job_id=None,
            owner_user_id=self.owner.principal.user_id,
        )

    def intent(self):
        return dict(
            id=uuid4(),
            preview_id=uuid4(),
            actor_id=self.owner.principal.user_id,
            origin_session_id=self.owner.principal.session_id,
            request_id=uuid4(),
            request_hash="a" * 64,
            selection_sha256="b" * 64,
            config_version=self.config_version,
            source_instance_id=self.instance_id,
            source_epoch=self.epoch,
            packages=[
                PackageStamp(
                    backup_id=self.backup_id,
                    control_version=1,
                    manifest_sha256="a" * 64,
                    tree_sha256="b" * 64,
                    size_bytes=30,
                    file_count=3,
                    created_at=self.stamp - timedelta(days=31),
                    instance_id=self.instance_id,
                    sync_epoch=self.epoch,
                ).model_dump(mode="json")
            ],
            job_id=self.other_job_id,
        )


@pytest.fixture
def lifecycle(postgres_engine, retention_actors):
    owner, other = retention_actors
    backup_id, other_backup_id = uuid4(), uuid4()
    with Session(postgres_engine, expire_on_commit=False) as session:
        session.begin()
        try:
            state = session.get(ServerState, 1)
            stamp = store.stamp(session)
            jobs = [
                store.enqueue(
                    session,
                    kind="backup_verify",
                    occurrence_key="retention-pg:" + uuid4().hex,
                    owner_user_id=owner.principal.user_id,
                    payload={"backup_id": str(backup_id)},
                )
                for _ in range(2)
            ]
            for identifier in (backup_id, other_backup_id):
                session.add(
                    BackupControl(
                        backup_id=identifier,
                        manifest_sha256="a" * 64,
                        tree_sha256="b" * 64,
                        instance_id=state.instance_id,
                        sync_epoch=state.sync_epoch,
                        created_at=stamp - timedelta(days=31),
                        size_bytes=30,
                        file_count=3,
                    )
                )
            session.flush()
            case = Case(
                session,
                owner,
                other,
                backup_id,
                other_backup_id,
                jobs[0].id,
                jobs[1].id,
                uuid4(),
                uuid4(),
                uuid4(),
                stamp,
                state.instance_id,
                state.sync_epoch,
                session.get(ConfigurationHead, 1).current_version,
            )
            intent = case.intent() | {"id": case.intent_id, "job_id": case.job_id}
            session.add(BackupRetentionIntent(**intent))
            session.add(BackupPin(**(case.pin() | {"id": case.pin_id})))
            session.add(
                BackupHold(
                    **(
                        case.hold()
                        | {
                            "id": case.hold_id,
                            "holder_kind": "job",
                            "holder_id": case.job_id,
                            "job_id": case.job_id,
                        }
                    )
                )
            )
            session.flush()
            yield case
        finally:
            # ROLLBACK is the only cleanup of protected rows; no DELETE bypass.
            session.rollback()
    with Session(postgres_engine) as session:
        assert session.get(BackupControl, backup_id) is None
        assert session.get(BackupControl, other_backup_id) is None


def rejected(case, statement, params=None, *, state="55000", message=None):
    with pytest.raises(DBAPIError) as caught, case.session.begin_nested():
        case.session.execute(statement, params or {})
    assert caught.value.orig.sqlstate == state
    if message:
        assert caught.value.orig.diag.message_primary == message
    case.session.expire_all()
    assert case.session.scalar(text("SELECT 1")) == 1


def release(case, kind, **patch):
    values = dict(version=2, released_at=case.stamp + timedelta(seconds=1))
    if kind == "pin":
        values.update(
            released_by=case.owner.principal.user_id,
            release_request_id=uuid4(),
            release_request_hash="c" * 64,
        )
    else:
        values.update(release_proof="job_terminal_verified")
    return values | patch


def update_row(case, kind, values):
    table = TABLES[kind]
    return table.update().where(table.c.id == getattr(case, kind + "_id")).values(**values)


def test_database_defaults_create_only_active_v1_and_normal_queries_work(lifecycle):
    case = lifecycle
    for model, identifier in ((BackupPin, case.pin_id), (BackupHold, case.hold_id)):
        row = case.session.get(model, identifier)
        assert row.version == 1 and row.released_at is None and row.created_at is not None
    pin = case.session.get(BackupPin, case.pin_id)
    assert pin.released_by is pin.release_request_id is pin.release_request_hash is None
    assert case.session.get(BackupHold, case.hold_id).release_proof is None
    control = case.session.get(BackupControl, case.backup_id)
    assert control.version == 1 and control.state == "available" and control.intent_id is None
    assert control.registered_at is not None and control.updated_at is not None


@pytest.mark.parametrize("kind", ["pin", "hold", "control"])
def test_raw_insert_really_uses_server_defaults_without_orm_python_defaults(lifecycle, kind):
    case = lifecycle
    params = {
        "id": uuid4(),
        "backup": case.backup_id,
        "owner": case.owner.principal.user_id,
        "request": uuid4(),
    }
    if kind == "pin":
        statement = """INSERT INTO backup_pins
            (id, backup_id, created_by, create_request_id, create_request_hash)
            VALUES (:id, :backup, :owner, :request, repeat('a',64))
            RETURNING version, released_at, created_at"""
    elif kind == "hold":
        statement = """INSERT INTO backup_holds
            (id, backup_id, holder_kind, holder_id, owner_user_id)
            VALUES (:id, :backup, 'download', :request, :owner)
            RETURNING version, released_at, created_at"""
    else:
        params.update(instance=case.instance_id, epoch=case.epoch, stamp=case.stamp)
        statement = """INSERT INTO backup_controls
            (backup_id, manifest_sha256, tree_sha256, instance_id, sync_epoch,
             created_at, size_bytes, file_count)
            VALUES (:id, repeat('a',64), repeat('b',64), :instance, :epoch, :stamp, 30, 3)
            RETURNING version, state, intent_id, registered_at"""
    row = case.session.execute(text(statement), params).mappings().one()
    assert row["version"] == 1
    if kind == "control":
        assert row["state"] == "available" and row["intent_id"] is None
        assert row["registered_at"] is not None
    else:
        assert row["released_at"] is None and row["created_at"] is not None


@pytest.mark.parametrize(
    "kind", ["pin_request", "hold_holder", "intent_preview", "intent_request", "intent_job"]
)
def test_real_unique_request_and_holder_constraints_preserve_original(lifecycle, kind):
    case = lifecycle
    if kind == "pin_request":
        original = case.session.get(BackupPin, case.pin_id)
        statement = insert(BackupPin.__table__).values(
            **(case.pin() | {"create_request_id": original.create_request_id})
        )
    elif kind == "hold_holder":
        statement = insert(BackupHold.__table__).values(
            **(
                case.hold()
                | {"holder_kind": "job", "holder_id": case.job_id, "job_id": case.job_id}
            )
        )
    else:
        original = case.session.get(BackupRetentionIntent, case.intent_id)
        field = {
            "intent_preview": "preview_id",
            "intent_request": "request_id",
            "intent_job": "job_id",
        }[kind]
        statement = insert(BackupRetentionIntent.__table__).values(
            **(case.intent() | {field: getattr(original, field)})
        )
    rejected(case, statement, state="23505")


def test_release_request_identity_is_unique_across_pins(lifecycle):
    case = lifecycle
    first = release(case, "pin")
    case.session.execute(update_row(case, "pin", first))
    second = case.pin()
    case.session.execute(insert(BackupPin.__table__).values(**second))
    statement = BackupPin.__table__.update().where(BackupPin.id == second["id"]).values(**first)
    rejected(case, statement, state="23505")


@pytest.mark.parametrize("action", ["update", "no_op", "delete", "truncate"])
def test_intent_raw_sql_is_append_only_and_savepoint_survives(lifecycle, action):
    case = lifecycle
    sql = {
        "update": "UPDATE backup_retention_intents SET request_hash=:hash WHERE id=:id",
        "no_op": "UPDATE backup_retention_intents SET config_version=config_version WHERE id=:id",
        "delete": "DELETE FROM backup_retention_intents WHERE id=:id",
        # List referring tables to pass PostgreSQL's pre-trigger FK safety check.
        # No CASCADE, and the outer fixture transaction always rolls back.
        "truncate": "TRUNCATE backup_retention_intents, backup_controls, backup_pins, backup_holds",
    }[action]
    rejected(
        case,
        text(sql),
        {"id": case.intent_id, "hash": "c" * 64},
        message="backup_retention_intent_immutable",
    )
    assert case.session.get(BackupRetentionIntent, case.intent_id).request_hash == "a" * 64


@pytest.mark.parametrize("kind", ["pin", "hold"])
def test_only_complete_once_release_preserves_every_subject_column(lifecycle, kind):
    case, table = lifecycle, TABLES[kind]
    key = getattr(case, kind + "_id")
    before = dict(case.session.execute(select(table).where(table.c.id == key)).mappings().one())
    case.session.execute(update_row(case, kind, release(case, kind)))
    after = dict(case.session.execute(select(table).where(table.c.id == key)).mappings().one())
    assert after["version"] == 2 and after["released_at"] is not None
    allowed = (
        {"version", "released_at", "release_proof"}
        if kind == "hold"
        else {"version", "released_at", "released_by", "release_request_id", "release_request_hash"}
    )
    assert {k: v for k, v in before.items() if k not in allowed} == {
        k: v for k, v in after.items() if k not in allowed
    }
    assert case.session.scalar(text("SELECT 1")) == 1


@pytest.mark.parametrize("kind", ["pin", "hold"])
@pytest.mark.parametrize("action", ["no_op", "delete", "truncate", "release_twice", "revive"])
def test_protection_no_op_deletion_truncation_and_revival_are_rejected(lifecycle, kind, action):
    case, table = lifecycle, TABLES[kind]
    if action in {"release_twice", "revive"}:
        case.session.execute(update_row(case, kind, release(case, kind)))
    if action == "delete":
        statement = table.delete().where(table.c.id == getattr(case, kind + "_id"))
    elif action == "truncate":
        statement = text("TRUNCATE " + table.name)
    elif action == "revive":
        fields = {field: None for field in release(case, kind)} | {"version": 1}
        statement = update_row(case, kind, fields)
    else:
        statement = update_row(case, kind, {"version": table.c.version})
    rejected(case, statement)
    assert case.session.scalar(
        select(table.c.version).where(table.c.id == getattr(case, kind + "_id"))
    ) == (2 if action in {"release_twice", "revive"} else 1)


@pytest.mark.parametrize(
    ("kind", "field"),
    [
        (kind, field)
        for kind, fields in (
            (
                "pin",
                (
                    "id",
                    "backup_id",
                    "created_by",
                    "created_at",
                    "create_request_id",
                    "create_request_hash",
                ),
            ),
            (
                "hold",
                ("id", "backup_id", "owner_user_id", "created_at", "holder_id", "holder_kind"),
            ),
        )
        for field in fields
    ],
)
def test_complete_release_cannot_rewrite_any_pin_or_hold_subject(lifecycle, kind, field):
    case = lifecycle
    patch = {
        "id": uuid4(),
        "backup_id": case.other_backup_id,
        "created_by": case.other.principal.user_id,
        "owner_user_id": case.other.principal.user_id,
        "created_at": case.stamp,
        "create_request_id": uuid4(),
        "create_request_hash": "e" * 64,
        "holder_id": case.other_job_id,
        "holder_kind": "restore_intent",
    }
    values = release(case, kind, **{field: patch[field]})
    if field == "holder_id":
        values["job_id"] = case.other_job_id  # Both are real, matching FK targets.
    rejected(case, update_row(case, kind, values), message=f"backup_{kind}_lifecycle_invalid")


@pytest.mark.parametrize("kind", ["pin", "hold"])
@pytest.mark.parametrize("version", [None, 0, 2, 3])
def test_insert_cannot_start_released_or_null_or_non_v1(lifecycle, kind, version):
    case = lifecycle
    values = (case.pin() if kind == "pin" else case.hold()) | {"version": version}
    if version == 2:
        values.update(release(case, kind))
    rejected(
        case, insert(TABLES[kind]).values(**values), message=f"backup_{kind}_lifecycle_invalid"
    )


@pytest.mark.parametrize(
    ("kind", "field"),
    [
        ("pin", "released_at"),
        ("pin", "released_by"),
        ("pin", "release_request_id"),
        ("pin", "release_request_hash"),
        ("hold", "released_at"),
        ("hold", "release_proof"),
    ],
)
def test_insert_defaults_never_allow_partial_release_fields(lifecycle, kind, field):
    case = lifecycle
    values = case.pin() if kind == "pin" else case.hold()
    values[field] = release(case, kind)[field]
    rejected(
        case, insert(TABLES[kind]).values(**values), message=f"backup_{kind}_lifecycle_invalid"
    )


@pytest.mark.parametrize(
    ("kind", "field"),
    [
        ("pin", "released_at"),
        ("pin", "released_by"),
        ("pin", "release_request_id"),
        ("pin", "release_request_hash"),
        ("hold", "released_at"),
        ("hold", "release_proof"),
    ],
)
def test_release_requires_all_proof_fields_without_null_three_value_bypass(lifecycle, kind, field):
    case = lifecycle
    rejected(
        case,
        update_row(case, kind, release(case, kind, **{field: None})),
        message=f"backup_{kind}_lifecycle_invalid",
    )


@pytest.mark.parametrize(
    ("kind", "patch", "state"),
    [
        ("pin", {"release_request_hash": "invalid"}, "23514"),
        ("hold", {"release_proof": "invented"}, "23514"),
        ("pin", {"released_by": "missing_user"}, "23503"),
        ("pin", {"released_at": "before_created"}, "23514"),
        ("hold", {"released_at": "before_created"}, "23514"),
    ],
)
def test_complete_release_still_checks_hash_proof_time_and_fk(lifecycle, kind, patch, state):
    case = lifecycle
    values = dict(patch)
    if values.get("released_by") == "missing_user":
        values["released_by"] = uuid4()
    if values.get("released_at") == "before_created":
        values["released_at"] = case.stamp - timedelta(days=1)
    rejected(case, update_row(case, kind, release(case, kind, **values)), state=state)


@pytest.mark.parametrize("action", ["update", "delete"])
def test_orm_intent_guard_and_savepoint_keep_surrounding_transaction_healthy(lifecycle, action):
    case = lifecycle
    with (
        pytest.raises(ValueError, match="backup_retention_intent_immutable"),
        case.session.begin_nested(),
    ):
        intent = case.session.get(BackupRetentionIntent, case.intent_id)
        if action == "update":
            intent.request_hash = "e" * 64
        else:
            case.session.delete(intent)
        case.session.flush()
    case.session.expire_all()
    assert case.session.scalar(text("SELECT 1")) == 1
    assert case.session.get(BackupRetentionIntent, case.intent_id).request_hash == "a" * 64


@pytest.mark.parametrize(
    ("kind", "patch", "state"),
    [
        ("pin", {"backup_id": "missing"}, "23503"),
        ("pin", {"created_by": "missing"}, "23503"),
        ("pin", {"create_request_hash": "invalid"}, "23514"),
        ("pin", {"created_at": None}, "23502"),
        ("hold", {"backup_id": "missing"}, "23503"),
        ("hold", {"owner_user_id": "missing"}, "23503"),
        ("hold", {"holder_kind": "invented"}, "23514"),
        ("hold", {"holder_kind": "job", "job_id": None}, "23514"),
        ("hold", {"holder_kind": "job", "job_id": "matching_missing"}, "23503"),
    ],
)
def test_protection_insert_fk_and_not_null_checks_cannot_be_bypassed(lifecycle, kind, patch, state):
    case = lifecycle
    values = case.pin() if kind == "pin" else case.hold()
    for field, value in patch.items():
        if value == "missing":
            values[field] = uuid4()
        elif value == "matching_missing":
            values[field] = values["holder_id"]
        else:
            values[field] = null() if value is None else value
    rejected(case, insert(TABLES[kind]).values(**values), state=state)


@pytest.mark.parametrize(
    ("field", "value", "state"),
    [
        ("config_version", -1, "23514"),
        ("request_hash", "bad", "23514"),
        ("packages", [], "23514"),
        ("packages", None, "23502"),
        ("actor_id", "missing", "23503"),
        ("origin_session_id", "missing", "23503"),
        ("job_id", "missing", "23503"),
    ],
)
def test_intent_requires_real_fk_closed_capacity_and_non_null_packages(
    lifecycle, field, value, state
):
    case = lifecycle
    values = case.intent()
    values[field] = uuid4() if value == "missing" else null() if value is None else value
    rejected(case, insert(BackupRetentionIntent.__table__).values(**values), state=state)


@pytest.mark.parametrize(
    ("patch", "state"),
    [
        ({"state": "reserved", "intent_id": None}, "23514"),
        ({"state": "available", "intent_id": "existing"}, "23514"),
        ({"state": "reserved", "intent_id": "missing"}, "23503"),
        ({"version": None}, "23502"),
        ({"size_bytes": 0}, "23514"),
    ],
)
def test_control_null_default_and_reservation_fk_constraints_remain_real(lifecycle, patch, state):
    case = lifecycle
    values = dict(
        backup_id=uuid4(),
        manifest_sha256="a" * 64,
        tree_sha256="b" * 64,
        instance_id=case.instance_id,
        sync_epoch=case.epoch,
        created_at=case.stamp,
        size_bytes=30,
        file_count=3,
    )
    for field, value in patch.items():
        values[field] = (
            case.intent_id
            if value == "existing"
            else uuid4()
            if value == "missing"
            else null()
            if value is None
            else value
        )
    rejected(case, insert(BackupControl.__table__).values(**values), state=state)
