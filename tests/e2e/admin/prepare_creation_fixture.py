"""Add one synthetic attachment and restricted owner, without creating a backup."""

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
from flowtrace_server.config import Settings
from flowtrace_server.persistence.database import build_engine, check_database
from flowtrace_server.persistence.private_files import private_open
from flowtrace_server.persistence.testing import require_isolated_database
from PIL import Image
from sqlalchemy.orm import Session


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    source = args.fixture.resolve()
    if not source.is_relative_to(root / "outputs/validation/P5/admin"):
        raise SystemExit("unexpected_fixture")
    admin = json.loads(source.read_text(encoding="utf-8-sig"))
    if admin.get("configuration_fixture") is not True:
        raise SystemExit("configuration_fixture_required")
    values = dotenv_values(admin["env_file"])
    parsed = require_isolated_database(
        values["FLOWTRACE_TEST_DATABASE_URL"], values["FLOWTRACE_ENVIRONMENT"]
    )
    if not parsed.database.startswith("flowtrace_test_p5_admin_"):
        raise SystemExit("unexpected_database")
    settings = Settings(
        _env_file=None,
        database_url=values["FLOWTRACE_TEST_DATABASE_URL"],
        environment="test",
        data_directory=Path(values["FLOWTRACE_DATA_DIRECTORY"]),
    )
    engine = build_engine(settings)
    check_database(engine)
    run = uuid4()
    private_path = root / "work/flowtrace-dev" / f"admin-creation-qa-{run}.json"
    credentials_path = Path(admin["credentials_path"]).resolve()
    if not credentials_path.is_relative_to(root / "work/flowtrace-dev"):
        raise SystemExit("unexpected_private_fixture")
    credentials = json.loads(credentials_path.read_text(encoding="utf-8-sig"))
    restricted_password = secrets.token_urlsafe(24)
    restricted_username = f"qa_creation_owner_{run.hex}"
    owner = UUID(admin["identities"]["owner"]["user_id"])
    try:
        store = AttachmentStore(settings.data_directory / "attachments")
        image_bytes = io.BytesIO()
        Image.new("RGB", (3, 2), "navy").save(image_bytes, format="PNG")
        original = image_bytes.getvalue()
        key, attachment_id = uuid4().hex + uuid4().hex, uuid4()
        stage = store.staging / f"{uuid4().hex}.part"
        with private_open(stage, store.root, create=True) as stream:
            stream.write(original)
        image = store.publish(stage, key, "image/png")
        with Session(engine) as session, session.begin():
            user = create_user(session, restricted_username, restricted_password)
            session.add(AdminRole(user_id=user.id, role="server_owner"))
            restricted_id = user.id
            session.add(
                Attachment(
                    id=attachment_id,
                    upload_id=uuid4(),
                    scope_id=owner,
                    created_by=owner,
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
        credentials["owner_without_recovery"] = {
            "username": restricted_username,
            "password": restricted_password,
        }
        with private_open(private_path, private_path.parent, create=True) as stream:
            stream.write(json.dumps(credentials).encode())
        fixture = {
            "purpose": "flowtrace-p5-backup-creation-synthetic",
            "run_id": str(run),
            "admin_fixture": str(source),
            "env_file": admin["env_file"],
            "credentials_path": str(private_path),
            "restricted_owner_id": str(restricted_id),
            "attachment_id": str(attachment_id),
            "original_sha256": hashlib.sha256(original).hexdigest(),
            "original_bytes": len(original),
            "origin": admin["origin"],
            "state": "seeded-no-backup-created",
        }
        destination = source.parent / f"backup-creation-{run}.json"
        with private_open(destination, source.parent, create=True) as stream:
            stream.write(json.dumps(fixture, indent=2).encode())
        print(
            json.dumps(
                {"fixture": str(destination), "synthetic_original_bytes": len(original)}
            )
        )
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
