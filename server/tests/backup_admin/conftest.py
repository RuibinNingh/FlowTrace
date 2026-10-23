import hashlib
from datetime import UTC, datetime
from uuid import uuid4

import pytest
from admin.conftest import admin_system as admin_system
from jobs.conftest import queue_case as queue_case
from sqlalchemy.orm import Session

from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.models import User
from flowtrace_server.auth.service import issue_session
from flowtrace_server.imports.parsers import canonical


def package(root, *, backup_id=None):
    identifier = backup_id or uuid4()
    directory = root / str(identifier)
    (directory / "objects").mkdir(parents=True)
    # These small unit files validate archive boundaries, not pg_restore.
    contents = {
        "database.dump": b"PGDMPunit-archive-boundary-fixture",
        "settings.json": b'{"environment":"test","diagnostics_enabled":true}',
        "objects/" + "a" * 64 + ".bin": b"synthetic_original_bytes",
        "objects/" + "a" * 64 + ".webp": b"synthetic_preview_bytes",
    }
    records = []
    for name, data in contents.items():
        (directory / name).write_bytes(data)
        records.append(
            {"path": name, "sha256": hashlib.sha256(data).hexdigest(), "size_bytes": len(data)}
        )
    manifest = {
        "format": "flowtrace-backup-v1",
        "backup_id": str(identifier),
        "created_at": datetime.now(UTC).isoformat(),
        "server_version": "0.1.0",
        "schema_versions": ["0009_background_jobs"],
        "database": records[0],
        "files": records[1:],
        "secret_configuration": "excluded_provision_separately",
    }
    raw = canonical(manifest)
    (directory / "manifest.json").write_bytes(raw)
    return identifier, directory, manifest, {**contents, "manifest.json": raw}


@pytest.fixture
def backup_system(admin_system):
    client, connection, owner_id = admin_system
    settings = client.app.state.settings
    identifier, directory, manifest, contents = package(settings.data_directory / "backups")
    with Session(connection, join_transaction_mode="create_savepoint") as session:
        record, _ = issue_session(
            session, session.get(User, owner_id), uuid4(), "Backup fixture", "admin"
        )
        principal = Principal(owner_id, record.id, record.client_id, "admin", frozenset())
        session.commit()
    return client, connection, principal, settings, identifier, directory, manifest, contents
