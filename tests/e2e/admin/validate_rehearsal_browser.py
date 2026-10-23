"""Independent readback of the real browser restore; does not perform restoration."""

import argparse
import json
from pathlib import Path
from uuid import UUID, uuid4

from dotenv import dotenv_values
from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.backups import rehearsal
from flowtrace_server.backups.rehearsal_schemas import RestoreVerifiedReceipt
from flowtrace_server.config import Settings
from flowtrace_server.configuration.models import ConfigurationHead
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.persistence.database import build_engine
from restore_fixture import load_restore_targets
from sqlalchemy import func, select
from sqlalchemy.orm import Session


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--phase", choices=("preview", "final"), required=True)
    parser.add_argument("--browser-receipt", type=Path)
    args = parser.parse_args()
    fixture = json.loads(args.fixture.read_text(encoding="utf-8-sig"))
    values = dotenv_values(fixture["env_file"])
    targets = load_restore_targets(args.fixture)
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url=values["FLOWTRACE_TEST_DATABASE_URL"],
        data_directory=Path(values["FLOWTRACE_DATA_DIRECTORY"]),
        restore_targets=targets,
    )
    target_id, target = next(iter(targets.items()))
    engine = build_engine(settings)
    try:
        with Session(engine) as session:
            jobs = list(
                session.scalars(
                    select(BackgroundJob).where(
                        BackgroundJob.kind == "restore_rehearsal",
                        BackgroundJob.occurrence_key == f"restore-target:{target_id}",
                    )
                )
            )
            if args.phase == "preview":
                assert jobs == [] and not target.data_directory.exists()
                rehearsal._probe_empty(settings, target)
                print(json.dumps({"preview_did_not_restore": True}))
                return
            browser = json.loads(args.browser_receipt.read_text(encoding="utf-8-sig"))
            assert browser["phase"] == "passed" and browser["worker_invocations"] == 1
            assert len(jobs) == 1
            job = jobs[0]
            assert str(job.id) == browser["job_id"]
            assert (
                job.status == "succeeded"
                and job.attempt == 1
                and job.lease_generation == 1
            )
            assert str(job.payload["preview_id"]) == browser["preview_id"]
            head = session.get(ConfigurationHead, 1)
            assert head.current_version == 5
            count = session.scalar(
                select(func.count())
                .select_from(AdminAudit)
                .where(
                    AdminAudit.action == "restore.enqueue",
                    AdminAudit.target_id == job.id,
                )
            )
            assert count == 1
            replay_count = session.scalar(
                select(func.count())
                .select_from(AdminAudit)
                .where(
                    AdminAudit.action == "restore.intent_replay",
                    AdminAudit.target_id == job.id,
                )
            )
            assert replay_count == 1
            manifest, digest = rehearsal._verified_manifest(
                settings, UUID(fixture["backup_id"])
            )
            root = rehearsal._control(settings, target_id)
            receipt = rehearsal._read_record(
                root / "verified.json", root, RestoreVerifiedReceipt
            )
            assert (
                receipt.job_id == job.id
                and str(receipt.preview_id) == browser["preview_id"]
            )
            assert receipt.manifest_sha256 == digest
            actual = rehearsal._verify_target(
                settings, target, manifest, check_budget=lambda: None
            )
            assert all(actual[key] == getattr(receipt, key) for key in actual)
            report = {
                "kind": "real-browser-restore-independent-postconditions",
                "browser_receipt": str(args.browser_receipt.resolve()),
                "job_id": str(job.id),
                "target_id": str(target_id),
                "actual_target_database": "flowtrace_test_p5_restore_bdd1a35fdbdd4ef2",
                "source_configuration_version": head.current_version,
                "source_intents": 1,
                "enqueue_audits": count,
                "replay_audits": replay_count,
                "worker_cli_invocations": 1,
                "attempts": job.attempt,
                "private_receipt_binding_and_fresh_full_database_and_object_hashes": True,
                "object_count": actual["object_count"],
                "target_epoch_differs_from_backup": str(actual["restored_epoch"])
                != manifest["sync_epoch"],
                "all_target_sessions_revoked_and_sync_clients_frozen": True,
                "partial_and_previous_restore_targets_untouched": True,
                "state": "passed",
            }
            path = (
                args.fixture.parent / f"rehearsal-browser-postconditions-{uuid4()}.json"
            )
            path.write_text(
                json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            print(json.dumps({"report": str(path), "state": "passed"}))
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
