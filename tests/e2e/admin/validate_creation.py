"""Verify only artifacts identified by this exact real-browser creation receipt."""

import argparse
import json
import subprocess
from pathlib import Path
from uuid import UUID, uuid4

from dotenv import dotenv_values
from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.backups.service import verify_backup
from flowtrace_server.config import Settings
from flowtrace_server.configuration.models import ConfigurationHead
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.persistence.database import build_engine
from flowtrace_server.persistence.testing import require_isolated_database
from sqlalchemy import func, select
from sqlalchemy.orm import Session


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    fixture_path, receipt_path = args.fixture.resolve(), args.receipt.resolve()
    if not all(
        item.is_relative_to(root / "outputs/validation/P5/admin")
        for item in (fixture_path, receipt_path)
    ):
        raise SystemExit("unexpected_evidence_location")
    fixture = json.loads(fixture_path.read_text(encoding="utf-8-sig"))
    receipt = json.loads(receipt_path.read_text(encoding="utf-8-sig"))
    assert receipt["phase"] == "passed" and receipt["fixture"] == fixture["run_id"]
    assert receipt["kind"] == "real-backup-create-worker-and-verification-forms"
    assert len(receipt["creations"]) == 2
    values = dotenv_values(fixture["env_file"])
    require_isolated_database(
        values["FLOWTRACE_TEST_DATABASE_URL"], values["FLOWTRACE_ENVIRONMENT"]
    )
    settings = Settings(
        _env_file=None,
        database_url=values["FLOWTRACE_TEST_DATABASE_URL"],
        data_directory=Path(values["FLOWTRACE_DATA_DIRECTORY"]),
        environment="test",
    )
    engine = build_engine(settings)
    results = []
    try:
        with Session(engine) as session:
            assert session.get(ConfigurationHead, 1).current_version == 5
            verification = session.get(
                BackgroundJob, UUID(receipt["verification_job_id"])
            )
            assert (
                verification.status == "succeeded"
                and verification.kind == "backup_verify"
            )
            for created in receipt["creations"]:
                identifier = UUID(created["backup_id"])
                job = session.get(BackgroundJob, UUID(created["job_id"]))
                assert (
                    job.status == "succeeded" and job.result["code"] == "backup_created"
                )
                assert job.result["artifact_id"] == str(identifier)
                assert job.attempt == 1 and job.manual_retries == 0
                manifest = verify_backup(
                    settings.data_directory / "backups", identifier
                )
                objects = [
                    item
                    for item in manifest["files"]
                    if item["path"].startswith("objects/")
                ]
                assert len(objects) == 2
                assert any(
                    item["sha256"] == fixture["original_sha256"]
                    and item["size_bytes"] == fixture["original_bytes"]
                    for item in objects
                )
                assert len(manifest["files"]) + 2 == job.result["file_count"] == 5
                package = settings.data_directory / "backups" / str(identifier)
                package_bytes = (
                    sum(item["size_bytes"] for item in manifest["files"])
                    + manifest["database"]["size_bytes"]
                    + (package / "manifest.json").stat().st_size
                )
                assert job.result["bytes"] == package_bytes
                toc = subprocess.run(
                    [
                        str(
                            root
                            / "work/flowtrace-dev/postgresql/pgsql/bin/pg_restore.exe"
                        ),
                        "--list",
                        str(package / "database.dump"),
                    ],
                    capture_output=True,
                    timeout=30,
                    check=True,
                    shell=False,
                ).stdout.decode("utf-8", errors="replace")
                assert "TABLE DATA public attachments " in toc
                count = session.scalar(
                    select(func.count())
                    .select_from(AdminAudit)
                    .where(
                        AdminAudit.action == "job.backup_create_enqueue",
                        AdminAudit.target_id == job.id,
                    )
                )
                assert count == 1
                results.append(
                    {
                        "role": created["role"],
                        "job_id": str(job.id),
                        "backup_id": str(identifier),
                        "file_count_including_manifest": 5,
                        "package_bytes_including_manifest": package_bytes,
                        "objects": len(objects),
                        "all_hashes_verified": True,
                        "pg_restore_toc_contains_attachments": True,
                        "enqueue_audits": count,
                    }
                )
        report = {
            "kind": "real-browser-creation-package-postconditions",
            "browser_receipt": str(receipt_path),
            "configuration_version_preserved": 5,
            "artifacts": results,
            "prior_partial_browser_artifacts_retained": True,
        }
        output = fixture_path.parent / f"creation-postconditions-{uuid4()}.json"
        output.write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(json.dumps({"receipt": str(output), **report}))
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
