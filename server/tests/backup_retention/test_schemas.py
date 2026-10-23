from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
from pydantic import ValidationError
from sqlalchemy.dialects import postgresql
from sqlalchemy.schema import CreateTable

from flowtrace_server.backups.retention_models import (
    BackupControl,
    BackupHold,
    BackupPin,
    BackupRetentionIntent,
)
from flowtrace_server.backups.retention_schemas import (
    MAX_PACKAGE_BYTES,
    BackupCandidate,
    HoldCreateCommand,
    PackageStamp,
    QuarantinePayload,
    RetentionPreviewRecord,
    RetentionSelection,
)
from flowtrace_server.persistence.registry import Base


def stamp(**patch):
    return PackageStamp(
        backup_id=uuid4(),
        control_version=1,
        manifest_sha256="a" * 64,
        tree_sha256="b" * 64,
        size_bytes=30,
        file_count=3,
        created_at=datetime.now(UTC) - timedelta(days=31),
        instance_id=uuid4(),
        sync_epoch=uuid4(),
        **patch,
    )


def preview(packages):
    now = datetime.now(UTC)
    return dict(
        preview_id=uuid4(),
        actor_id=uuid4(),
        session_id=uuid4(),
        request_id=uuid4(),
        config_version=0,
        source_instance_id=uuid4(),
        source_epoch=uuid4(),
        retention_days=30,
        cutoff=now - timedelta(days=30),
        packages=packages,
        selection_sha256="c" * 64,
        issued_at=now,
        expires_at=now + timedelta(seconds=300),
    )


def test_public_selection_is_canonical_unique_bounded_and_path_free():
    identities = tuple(sorted((uuid4(), uuid4()), key=str))
    values = dict(backup_ids=identities, request_id=uuid4(), expected_config_version=0)
    assert RetentionSelection(**values).backup_ids == identities
    for patch in (
        {"backup_ids": identities[::-1]},
        {"backup_ids": (identities[0],) * 2},
        {"backup_ids": tuple(uuid4() for _ in range(21))},
        {"expected_config_version": True},
        {"path": "private-only-sentinel"},
    ):
        with pytest.raises(ValidationError) as caught:
            RetentionSelection(**{**values, **patch})
        assert "private-only-sentinel" not in str(caught.value)
    with pytest.raises(ValidationError):
        QuarantinePayload(
            intent_id=uuid4(), selection_sha256="d" * 64, url="https://private.invalid"
        )


def test_preview_has_strict_capacity_lifetime_order_and_old_package_guards():
    first = stamp()
    values = preview((first,))
    assert RetentionPreviewRecord(**values).packages == (first,)
    assert "directory" not in RetentionPreviewRecord(**values).model_dump_json()
    for patch in (
        {"expires_at": values["issued_at"] + timedelta(seconds=301)},
        {"packages": (first, first)},
        {"packages": (first.model_copy(update={"created_at": values["cutoff"]}),)},
    ):
        with pytest.raises(ValidationError):
            RetentionPreviewRecord(**{**values, **patch})
    packages = tuple(sorted((stamp(), stamp()), key=lambda value: str(value.backup_id)))
    packages = tuple(p.model_copy(update={"size_bytes": MAX_PACKAGE_BYTES}) for p in packages)
    with pytest.raises(ValidationError):
        RetentionPreviewRecord(**preview(packages))


def test_hold_job_binding_and_unregistered_protection_cannot_be_claimed_available():
    job = uuid4()
    base = dict(
        hold_id=uuid4(),
        backup_id=uuid4(),
        expected_control_version=1,
        holder_kind="job",
        holder_id=job,
    )
    with pytest.raises(ValidationError):
        HoldCreateCommand(**base)
    assert HoldCreateCommand(**base, job_id=job).job_id == job
    with pytest.raises(ValidationError):
        HoldCreateCommand(**{**base, "holder_kind": "download"}, job_id=job)
    assert not BackupCandidate(
        backup_id=uuid4(),
        state="unregistered",
        eligible=False,
        protection_reasons=("unregistered",),
    ).eligible
    with pytest.raises(ValidationError):
        BackupCandidate(
            backup_id=uuid4(), state="unregistered", eligible=True, protection_reasons=()
        )


def test_frozen_postgresql_ddl_contains_required_cas_and_null_safe_relations():
    assert "users" in Base.metadata.tables
    compiled = {
        model.__tablename__: str(CreateTable(model.__table__).compile(dialect=postgresql.dialect()))
        for model in (BackupControl, BackupPin, BackupHold, BackupRetentionIntent)
    }
    assert "ck_backup_control_intent" in compiled["backup_controls"]
    assert "version=1" in compiled["backup_pins"] and "version=2" in compiled["backup_pins"]
    assert "job_id IS NOT NULL" in compiled["backup_holds"]
    assert "release_proof IS NOT NULL" in compiled["backup_holds"]
    assert "UNIQUE (job_id)" in compiled["backup_retention_intents"]
    assert "JSONB NOT NULL" in compiled["backup_retention_intents"]
