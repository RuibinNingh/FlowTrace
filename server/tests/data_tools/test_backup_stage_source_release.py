"""Nonempty stage BYTEA/formal publication/release audit real isolated restore."""

import hashlib
import json
import os
from datetime import datetime
from pathlib import Path
from uuid import UUID

import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session
from sync.helpers import account, actor, expense, operation, push

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.models import UserSession
from flowtrace_server.auth.service import authenticate_access
from flowtrace_server.backups.service import create_backup, restore_isolated, verify_backup_leased
from flowtrace_server.imports.models import ImportBatch, ImportItem
from flowtrace_server.imports.staging_models import (
    ImportPublication,
    ImportPublicationChunk,
    ImportStage,
    ImportStageRequirement,
    ImportStageRow,
    ImportStageSourceRelease,
    ImportStageUploadChunk,
)
from flowtrace_server.persistence.database import build_engine
from flowtrace_server.persistence.models import ServerState
from flowtrace_server.sync.models import SyncEntity

from .test_backup_restore import backup_engine as backup_engine
from .test_backup_restore import pg_binaries, settings_for
from .test_import_attachments import ready_image
from .test_source_release import published, release

pytestmark = pytest.mark.postgres

TABLES = (
    ImportStage,
    ImportStageUploadChunk,
    ImportStageRow,
    ImportStageRequirement,
    ImportBatch,
    ImportItem,
    ImportPublication,
    ImportPublicationChunk,
    ImportStageSourceRelease,
)


def exact_stage_rows(engine):
    with Session(engine) as session:
        return {
            model.__tablename__: [
                dict(row)
                for row in session.execute(
                    select(model.__table__).order_by(*model.__table__.primary_key.columns)
                ).mappings()
            ]
            for model in TABLES
        }


def json_value(value):
    if isinstance(value, UUID):
        return str(value)
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, bytes):
        return {"bytes_sha256": hashlib.sha256(value).hexdigest(), "size": len(value)}
    raise TypeError(type(value).__name__)


def test_real_nonempty_stage_source_and_release_audit_dump_verify_fresh_restore(backup_engine):
    value = os.environ.get("FLOWTRACE_STAGE_BACKUP_EVIDENCE_DIRECTORY")
    if not value:
        pytest.skip("explicit fresh stage backup evidence directory not configured")
    base = Path(value)
    assert not base.exists(), "never overwrite a prior backup/restore evidence directory"
    base.mkdir(parents=True)
    source_directory, target_directory = base / "source", base / "restored"
    source = settings_for(os.environ["FLOWTRACE_BACKUP_TEST_DATABASE_URL"], source_directory)
    target = settings_for(os.environ["FLOWTRACE_RESTORE_TEST_DATABASE_URL"], target_directory)
    binaries = pg_binaries()
    owner = actor(backup_engine)
    cash = account(backup_engine, owner, opening="10000")
    image_id, _, original, storage = ready_image(
        backup_engine, owner, source_directory / "attachments", scope_id=owner.book_id
    )
    assert (
        push(
            backup_engine,
            owner,
            operation(
                owner.book_id,
                "bill",
                expense(owner.book_id, cash, "125", attachment_ids=[str(image_id)]),
            ),
        )[0]["status"]
        == "applied"
    )
    _, kept, _ = published(backup_engine, owner)
    _, released, request = published(backup_engine, owner)
    released_receipt = release(backup_engine, owner, released, request)
    before = exact_stage_rows(backup_engine)
    assert len(before["import_stages"]) == 2
    assert len(before["import_stage_upload_chunks"]) > 0
    assert len(before["import_stage_rows"]) == 4
    assert len(before["import_stage_requirements"]) == 1
    assert len(before["import_publications"]) == len(before["import_publication_chunks"]) == 2
    assert len(before["import_stage_source_releases"]) == 1
    assert before["import_stage_source_releases"][0]["deleted_requirement_rows"] == 1
    assert released_receipt.deleted_requirement_rows == 1
    by_stage = {row["id"]: row for row in before["import_stages"]}
    assert by_stage[UUID(kept.stage_id)]["source_released_at"] is None
    assert by_stage[UUID(released.stage_id)]["source_released_at"] is not None
    assert (
        by_stage[UUID(released.stage_id)]["received_bytes"]
        == released_receipt.reserved_bytes_released
    )
    kept_bytes = b"".join(
        row["content"]
        for row in before["import_stage_upload_chunks"]
        if row["stage_id"] == UUID(kept.stage_id)
    )
    assert hashlib.sha256(kept_bytes).hexdigest() == by_stage[UUID(kept.stage_id)]["source_sha256"]
    kept_requirements = before["import_stage_requirements"]
    assert kept_requirements[0]["stage_id"] == UUID(kept.stage_id)
    assert (
        kept_requirements[0]["parsed_version"]
        == by_stage[UUID(kept.stage_id)]["requirements_version"]
    )
    assert kept_requirements[0]["kind"] == "scope"
    assert kept_requirements[0]["source_key"] == str(owner.book_id)
    with Session(backup_engine) as session:
        identity = session.get(ServerState, 1)
        old_instance, old_epoch = identity.instance_id, identity.sync_epoch
        assert session.get(SyncEntity, cash).balance_minor == 9875
    receipt = create_backup(source, source_directory / "backups", pg_dump=binaries / "pg_dump.exe")
    backup_id = UUID(receipt["backup_id"])
    manifest = verify_backup_leased(source, backup_id)
    assert manifest["database_summary"]["tables"]["import_stage_source_releases"]["count"] == 1
    assert manifest["database_summary"]["tables"]["import_stage_upload_chunks"]["count"] > 0
    assert manifest["database_summary"]["tables"]["import_stage_requirements"]["count"] == 1
    report = restore_isolated(
        source_directory / "backups",
        backup_id,
        target,
        pg_restore=binaries / "pg_restore.exe",
        attachment_directory=target_directory / "attachments",
    )
    assert report["status"] == "isolated_verified" and report["database_contents_verified"]
    assert report["sync_epoch_changed"] and report["attachment_files_verified"] == 2
    restored = build_engine(target)
    try:
        after = exact_stage_rows(restored)
        assert (
            after == before
        )  # Includes actual BYTEA, rows, marker, original received counts and audit.
        with Session(restored) as session:
            identity = session.get(ServerState, 1)
            assert identity.instance_id == old_instance and identity.sync_epoch != old_epoch
            assert session.get(SyncEntity, cash).balance_minor == 9875
            sessions = list(session.scalars(select(UserSession)))
            assert sessions and all(record.revoked_at is not None for record in sessions)
            with pytest.raises(ApiError):
                authenticate_access(session, owner.token)
        from flowtrace_server.attachments.models import Attachment

        with Session(restored) as session:
            restored_image = session.get(Attachment, image_id)
            restored_original = (
                target_directory / "attachments/objects" / (restored_image.storage_key + ".bin")
            )
            assert restored_original.read_bytes() == original
    finally:
        restored.dispose()
    assert exact_stage_rows(backup_engine) == before
    with Session(backup_engine) as session:
        assert authenticate_access(session, owner.token).user_id == owner.principal.user_id
    # Backup, all retained source bytes and both original/thumbnail directories
    # intentionally stay under the new evidence directory after test completion.
    evidence = {
        "result": "passed",
        "backup_id": str(backup_id),
        "schema_versions": manifest["schema_versions"],
        "table_counts": {name: len(rows) for name, rows in before.items()},
        "exact_metadata_and_bytea_roundtrip": True,
        "stage_snapshot_sha256": hashlib.sha256(
            json.dumps(
                before,
                default=json_value,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode()
        ).hexdigest(),
        "retained_source_sha256": hashlib.sha256(kept_bytes).hexdigest(),
        "retained_source_bytes": len(kept_bytes),
        "original_png_sha256": hashlib.sha256(original).hexdigest(),
        "original_png_bytes": len(original),
        "account_balance_minor": "9875",
        "received_history_preserved": True,
        "nonempty_requirements_and_deletion_audit_restored": True,
        "epoch_rotated_sessions_revoked": True,
        "original_source_session_remains_valid": True,
        "restore_does_not_reauthorize_old_stage_epoch": True,
        "source_and_target_were_fresh_and_distinct": True,
        "old_database_or_backup_reset_or_deleted": False,
    }
    (base / "receipt.json").write_text(
        json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", "utf-8"
    )
