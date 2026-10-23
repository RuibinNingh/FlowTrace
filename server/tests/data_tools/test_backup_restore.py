import hashlib
import io
import os
import shutil
from datetime import timedelta
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from alembic import command
from PIL import Image
from sqlalchemy.engine import make_url
from sqlalchemy.orm import Session
from sync.helpers import account, actor, expense, operation, push

from flowtrace_server.attachments.models import Attachment
from flowtrace_server.attachments.storage import AttachmentStore
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import authenticate_access, now
from flowtrace_server.backups.service import (
    BackupError,
    _connection,
    _verify_balances,
    create_backup,
    restore_isolated,
    verify_backup,
)
from flowtrace_server.config import Settings
from flowtrace_server.persistence.private_files import private_open
from flowtrace_server.persistence.testing import require_isolated_database


def settings_for(url, directory):
    return Settings(_env_file=None, environment="test", database_url=url, data_directory=directory)


def pg_binaries():
    directory = Path(__file__).resolve().parents[3] / "work/flowtrace-dev/postgresql/pgsql/bin"
    if not (directory / "pg_dump.exe").exists():
        pytest.skip("explicit local PostgreSQL tools unavailable")
    return directory


@pytest.fixture
def backup_engine():
    from flowtrace_server.persistence.database import build_engine, migration_config

    source = os.environ.get("FLOWTRACE_BACKUP_TEST_DATABASE_URL")
    target = os.environ.get("FLOWTRACE_RESTORE_TEST_DATABASE_URL")
    if not source or not target:
        pytest.skip("fresh isolated backup source/restore databases not configured")
    for value in (source, target):
        url = require_isolated_database(value, "test")
        assert url.host == "127.0.0.1" and url.port == 55432
        assert url.database != "flowtrace_test_p5_local"
    assert make_url(source).database != make_url(target).database
    engine = build_engine(settings_for(source, Path("unused")))
    with engine.begin() as connection:
        config = migration_config()
        config.attributes["connection"] = connection
        command.upgrade(config, "head")
    yield engine
    engine.dispose()


@pytest.mark.postgres
def test_real_dump_restore_metadata_money_files_and_revoked_sessions(backup_engine, tmp_path):
    postgres_engine = backup_engine
    binaries = pg_binaries()
    owner = actor(postgres_engine)
    cash = account(postgres_engine, owner, opening="10000")
    directory = tmp_path / "source"
    store = AttachmentStore(directory / "attachments")
    output = io.BytesIO()
    Image.new("RGB", (3, 2), "blue").save(output, format="PNG")
    original = output.getvalue()
    checksum = hashlib.sha256(original).hexdigest()
    key, identifier, upload = uuid4().hex + uuid4().hex, uuid4(), uuid4()
    staged = store.staging / (uuid4().hex + ".part")
    with private_open(staged, store.root, create=True) as stream:
        stream.write(original)
    image = store.publish(staged, key, "image/png")
    with Session(postgres_engine) as session:
        session.add(
            Attachment(
                id=identifier,
                upload_id=upload,
                scope_id=owner.book_id,
                created_by=owner.principal.user_id,
                sha256=checksum,
                size_bytes=len(original),
                media_type="image/png",
                storage_key=key,
                status="ready",
                created_at=now(),
                upload_expires_at=now() + timedelta(hours=24),
                ready_at=now(),
                orphaned_at=now(),
                width=image.width,
                height=image.height,
            )
        )
        session.commit()
    result = push(
        postgres_engine,
        owner,
        operation(
            owner.book_id,
            "bill",
            expense(owner.book_id, cash, "125", attachment_ids=[str(identifier)]),
        ),
    )[0]
    assert result["status"] == "applied"
    source_url = os.environ["FLOWTRACE_BACKUP_TEST_DATABASE_URL"]
    settings = settings_for(source_url, directory)
    packages = tmp_path / "packages"
    receipt = create_backup(settings, packages, pg_dump=binaries / "pg_dump.exe")
    assert receipt["status"] == "verified"
    backup_id = UUID(receipt["backup_id"])
    manifest = verify_backup(packages, backup_id)
    assert manifest["database_summary"]["tables"]["attachments"]["count"] == 1
    assert manifest["database_summary"]["tables"]["ledger_entries"]["count"] == 1
    assert any(item["path"] == "objects/" + key + ".bin" for item in manifest["files"])
    assert "password" not in (packages / str(backup_id) / "settings.json").read_text()
    target_url = os.environ["FLOWTRACE_RESTORE_TEST_DATABASE_URL"]
    target = settings_for(target_url, tmp_path / "recovered-data")
    report = restore_isolated(
        packages,
        backup_id,
        target,
        pg_restore=binaries / "pg_restore.exe",
        attachment_directory=target.data_directory / "attachments",
    )
    assert report["status"] == "isolated_verified" and report["sync_epoch_changed"]
    assert report["database_contents_verified"]
    assert report["attachment_files_verified"] == 2
    with _connection(target) as connection:
        connection.execute("UPDATE sync_entities SET balance_minor=NULL WHERE id=%s", (cash,))
        with pytest.raises(BackupError, match="restore_balance_mismatch"):
            _verify_balances(connection)
        connection.rollback()
        connection.execute(
            "UPDATE sync_entities SET payload=payload-'opening' WHERE id=%s", (cash,)
        )
        with pytest.raises(BackupError, match="restore_balance_mismatch"):
            _verify_balances(connection)
        connection.rollback()
        connection.execute("UPDATE ledger_entries SET currency='USD' WHERE account_id=%s", (cash,))
        with pytest.raises(BackupError, match="restore_balance_mismatch"):
            _verify_balances(connection)
        connection.rollback()
    assert (target.data_directory / "attachments/objects" / (key + ".bin")).read_bytes() == original
    from flowtrace_server.persistence.database import build_engine

    restored = build_engine(target)
    try:
        from flowtrace_server.auth.models import User
        from flowtrace_server.auth.service import issue_session, verify_password
        from flowtrace_server.books.permissions import authorize_scope
        from flowtrace_server.sync.models import SyncEntity

        with Session(restored) as session:
            assert session.get(SyncEntity, cash).balance_minor == 9875
            with pytest.raises(ApiError):
                authenticate_access(session, owner.token)
            user = session.get(User, owner.principal.user_id)
            assert (
                verify_password(session, user.username, "Synthetic-password-2026-only").id
                == user.id
            )
            record, _ = issue_session(session, user, uuid4(), "合成恢复验证", "api_native")
            from flowtrace_server.auth.dependencies import Principal

            principal = Principal(user.id, record.id, record.client_id, record.purpose, frozenset())
            assert authorize_scope(session, principal, owner.book_id).role == "owner"
            session.rollback()  # Login verification does not retain an active test session.
    finally:
        restored.dispose()
    # The original DB/session remains usable; restore never switches the live source.
    with Session(postgres_engine) as session:
        assert authenticate_access(session, owner.token).user_id == owner.principal.user_id
    with pytest.raises(BackupError, match="restore_directory_exists"):
        restore_isolated(
            packages,
            backup_id,
            target,
            pg_restore=binaries / "pg_restore.exe",
            attachment_directory=target.data_directory / "attachments",
        )
    tampered = tmp_path / "tampered-packages"
    shutil.copytree(packages, tampered)
    original_path = tampered / str(backup_id) / "objects" / (key + ".bin")
    original_path.write_bytes(b"damaged")
    with pytest.raises(BackupError, match="backup_file_size_mismatch"):
        verify_backup(tampered, backup_id)
    assert verify_backup(packages, backup_id)["backup_id"] == str(backup_id)
