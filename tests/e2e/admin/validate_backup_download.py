"""Check exact browser ZIP bytes, real pg_restore TOC, and private cleanup."""

import argparse
import hashlib
import json
import stat
import subprocess
import zipfile
from pathlib import Path
from uuid import UUID, uuid4

from dotenv import dotenv_values
from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.config import Settings
from flowtrace_server.persistence.database import build_engine
from flowtrace_server.persistence.private_files import private_open
from flowtrace_server.persistence.testing import require_isolated_database
from sqlalchemy import select
from sqlalchemy.orm import Session


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--postconditions", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    fixture_path = args.fixture.resolve()
    if not fixture_path.is_relative_to(root / "outputs/validation/P5/admin"):
        raise SystemExit("unexpected_fixture_location")
    fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    if fixture.get("purpose") != "flowtrace-p5-admin-backup-download-synthetic":
        raise SystemExit("unexpected_fixture")
    if args.postconditions:
        values = dotenv_values(fixture["env_file"])
        url = values.get("FLOWTRACE_TEST_DATABASE_URL")
        parsed = require_isolated_database(url, values.get("FLOWTRACE_ENVIRONMENT", ""))
        if not parsed.database.startswith("flowtrace_test_p5_admin_"):
            raise SystemExit("unexpected_database")
        engine = build_engine(
            Settings(_env_file=None, database_url=url, environment="test")
        )
        try:
            with Session(engine) as session:
                records = list(
                    session.scalars(
                        select(AdminAudit).where(
                            AdminAudit.action == "backup.raw_download",
                            AdminAudit.target_id == UUID(fixture["good_backup_id"]),
                        )
                    )
                )
            successes = sum(row.summary.get("succeeded") is True for row in records)
            rejected = sum(row.summary.get("succeeded") is False for row in records)
            directory = Path(values["FLOWTRACE_DATA_DIRECTORY"]) / "admin-downloads"
            artifacts = len(list(directory.iterdir())) if directory.exists() else 0
            if successes < 2 or rejected < 3 or artifacts != 0:
                raise SystemExit("download_postconditions_failed")
            print(
                json.dumps(
                    {
                        "authorized_preparations": successes,
                        "rejected_attempts": rejected,
                        "temporary_archives": artifacts,
                    }
                )
            )
        finally:
            engine.dispose()
        return
    archive_path = args.archive.resolve()
    if (
        not archive_path.is_relative_to(fixture_path.parent)
        or not archive_path.is_file()
    ):
        raise SystemExit("unexpected_archive_location")
    expected = {record["name"]: record for record in fixture["members"]}
    database = None
    with zipfile.ZipFile(archive_path) as archive:
        if len(archive.infolist()) != len(expected) or set(archive.namelist()) != set(
            expected
        ):
            raise SystemExit("archive_member_mismatch")
        for info in archive.infolist():
            item = expected[info.filename]
            if (
                not stat.S_ISREG(info.external_attr >> 16)
                or info.file_size != item["size_bytes"]
            ):
                raise SystemExit("archive_entry_invalid")
            content = archive.read(info)
            if hashlib.sha256(content).hexdigest() != item["sha256"]:
                raise SystemExit("archive_hash_mismatch")
            if info.filename.endswith("/database.dump"):
                database = content
    target = archive_path.parent / f"verified-{uuid4()}.dump"
    with private_open(target, target.parent, create=True) as stream:
        stream.write(database)
    executable = root / "work/flowtrace-dev/postgresql/pgsql/bin/pg_restore.exe"
    result = subprocess.run(
        [str(executable), "--list", str(target)], check=False, capture_output=True, timeout=20
    )
    if result.returncode != 0 or b"TABLE DATA public attachments" not in result.stdout:
        raise SystemExit("actual_dump_toc_invalid")
    raw = archive_path.read_bytes()
    print(
        json.dumps(
            {
                "verified_members": len(expected),
                "objects": sum("/objects/" in name for name in expected),
                "sha256": hashlib.sha256(raw).hexdigest(),
                "size_bytes": len(raw),
                "pg_restore_toc_verified": True,
            }
        )
    )


if __name__ == "__main__":
    main()
