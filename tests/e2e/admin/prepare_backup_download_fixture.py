"""Real pg_dump + attachment objects, preserving earlier admin QA evidence."""

import argparse
import hashlib
import io
import json
import secrets
from datetime import timedelta
from pathlib import Path
from uuid import UUID, uuid4

from dotenv import dotenv_values
from flowtrace_server.attachments.models import Attachment
from flowtrace_server.attachments.storage import AttachmentStore
from flowtrace_server.auth.models import AdminRole
from flowtrace_server.auth.service import create_user, now
from flowtrace_server.backups.service import create_backup, verify_backup
from flowtrace_server.config import Settings
from flowtrace_server.persistence.database import build_engine
from flowtrace_server.persistence.private_files import private_directory, private_open
from flowtrace_server.persistence.testing import require_isolated_database
from PIL import Image
from sqlalchemy.orm import Session


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--operations-fixture", required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    operations_path = args.operations_fixture.resolve()
    if not operations_path.is_relative_to(root / "outputs/validation/P5/admin"):
        raise SystemExit("unexpected_fixture_location")
    operations = json.loads(operations_path.read_text(encoding="utf-8"))
    if operations.get("purpose") != "flowtrace-p5-admin-operations-synthetic":
        raise SystemExit("unexpected_fixture")
    admin = json.loads(
        Path(operations["admin_fixture"]).read_text(encoding="utf-8-sig")
    )
    values = dotenv_values(operations["env_file"])
    url = values.get("FLOWTRACE_TEST_DATABASE_URL")
    parsed = require_isolated_database(url, values.get("FLOWTRACE_ENVIRONMENT", ""))
    if not parsed.database.startswith("flowtrace_test_p5_admin_"):
        raise SystemExit("unexpected_database")
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url=url,
        data_directory=Path(values["FLOWTRACE_DATA_DIRECTORY"]),
    )
    engine = build_engine(settings)
    run_id = uuid4()
    credentials_path = root / "work/flowtrace-dev" / f"admin-backup-qa-{run_id}.json"
    password, username = secrets.token_urlsafe(24), f"qa_owner_{run_id.hex}"
    owner_id = UUID(admin["identities"]["owner"]["user_id"])
    try:
        with Session(engine) as session, session.begin():
            restricted_owner = create_user(session, username, password)
            session.add(AdminRole(user_id=restricted_owner.id, role="server_owner"))
        with private_open(
            credentials_path, credentials_path.parent, create=True
        ) as stream:
            stream.write(
                json.dumps(
                    {
                        "owner_without_recovery": {
                            "username": username,
                            "password": password,
                        }
                    }
                ).encode()
            )
        store = AttachmentStore(settings.data_directory / "attachments")
        output = io.BytesIO()
        Image.new("RGB", (3, 2), "green").save(output, format="PNG")
        original = output.getvalue()
        key, attachment_id = uuid4().hex + uuid4().hex, uuid4()
        staged = store.staging / f"{uuid4().hex}.part"
        with private_open(staged, store.root, create=True) as stream:
            stream.write(original)
        image = store.publish(staged, key, "image/png")
        with Session(engine) as session, session.begin():
            session.add(
                Attachment(
                    id=attachment_id,
                    upload_id=uuid4(),
                    scope_id=owner_id,
                    created_by=owner_id,
                    sha256=hashlib.sha256(original).hexdigest(),
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
        backup = create_backup(
            settings,
            settings.data_directory / "backups",
            pg_dump=root / "work/flowtrace-dev/postgresql/pgsql/bin/pg_dump.exe",
        )
        backup_id = UUID(backup["backup_id"])
        manifest = verify_backup(settings.data_directory / "backups", backup_id)
        package = settings.data_directory / "backups" / str(backup_id)
        members = []
        for name in [
            "manifest.json",
            manifest["database"]["path"],
            *(item["path"] for item in manifest["files"]),
        ]:
            content = (package / name).read_bytes()
            members.append(
                {
                    "name": f"{backup_id}/{name}",
                    "sha256": hashlib.sha256(content).hexdigest(),
                    "size_bytes": len(content),
                }
            )
        partial_id = uuid4()
        private_directory(settings.data_directory / "backups" / str(partial_id))
        result = {
            "purpose": "flowtrace-p5-admin-backup-download-synthetic",
            "run_id": str(run_id),
            "admin_fixture": operations["admin_fixture"],
            "env_file": operations["env_file"],
            "credentials_path": str(credentials_path),
            "good_backup_id": str(backup_id),
            "damaged_backup_id": operations["damaged_backup_id"],
            "partial_backup_id": str(partial_id),
            "members": members,
            "attachment_id": str(attachment_id),
            "state": "seeded",
        }
        destination = operations_path.parent / f"backup-download-{run_id}.json"
        with private_open(destination, operations_path.parent, create=True) as stream:
            stream.write(json.dumps(result, indent=2).encode())
        print(
            json.dumps(
                {
                    "backup_fixture": str(destination),
                    "files": len(members),
                    "objects": sum("/objects/" in item["name"] for item in members),
                }
            )
        )
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
