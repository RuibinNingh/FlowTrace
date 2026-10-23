"""Real staged enqueue and production Worker against two explicit fresh targets.

This is a one-time isolated restore acceptance, not browser acceptance. It keeps
all restored/partial target data, private receipts and source job attempts.
"""

import argparse
import hashlib
import json
from datetime import timedelta
from pathlib import Path
from uuid import UUID, uuid4

from dotenv import dotenv_values
from flowtrace_server.auth.dependencies import Principal
from flowtrace_server.auth.models import User, UserSession
from flowtrace_server.auth.service import issue_session, now, roles_for
from flowtrace_server.backups import rehearsal
from flowtrace_server.backups import service as backups
from flowtrace_server.config import RestoreTargetConfig, Settings
from flowtrace_server.configuration.models import ConfigurationHead
from flowtrace_server.jobs import administration, store
from flowtrace_server.jobs.models import BackgroundJob
from flowtrace_server.persistence.database import build_engine, check_database
from flowtrace_server.persistence.private_files import private_directory, private_open
from flowtrace_server.persistence.testing import require_isolated_database
from flowtrace_server.worker.runtime import Worker
from sqlalchemy.orm import Session


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--backup-id", type=UUID, required=True)
    parser.add_argument("--normal-target-env", type=Path, required=True)
    parser.add_argument("--partial-target-env", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    source_fixture = args.fixture.resolve()
    if not source_fixture.is_relative_to(root / "outputs/validation/P5/admin"):
        raise SystemExit("unexpected_source_fixture")
    admin = json.loads(source_fixture.read_text(encoding="utf-8-sig"))
    values = dotenv_values(admin["env_file"])
    require_isolated_database(
        values["FLOWTRACE_TEST_DATABASE_URL"], values["FLOWTRACE_ENVIRONMENT"]
    )
    credentials_path = Path(admin["credentials_path"]).resolve()
    if not credentials_path.is_relative_to(root / "work/flowtrace-dev"):
        raise SystemExit("unexpected_private_fixture")
    credentials = json.loads(credentials_path.read_text(encoding="utf-8-sig"))
    target_ids = {"normal": uuid4(), "partial": uuid4()}
    targets = {}
    for label, file in (
        ("normal", args.normal_target_env),
        ("partial", args.partial_target_env),
    ):
        env_path = file.resolve()
        if env_path.parent != root / "work/flowtrace-dev/postgresql":
            raise SystemExit("unexpected_target_env")
        target_values = dotenv_values(env_path)
        require_isolated_database(target_values["FLOWTRACE_TEST_DATABASE_URL"], "test")
        directory = Path(target_values["FLOWTRACE_DATA_DIRECTORY"])
        if directory.exists() or directory.is_symlink() or directory.is_junction():
            raise SystemExit("explicit_fresh_target_required")
        targets[target_ids[label]] = RestoreTargetConfig(
            label=f"本轮{label}隔离恢复",
            database_url=target_values["FLOWTRACE_TEST_DATABASE_URL"],
            data_directory=directory,
            pg_restore_executable=root
            / "work/flowtrace-dev/postgresql/pgsql/bin/pg_restore.exe",
        )
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url=values["FLOWTRACE_TEST_DATABASE_URL"],
        data_directory=Path(values["FLOWTRACE_DATA_DIRECTORY"]),
        diagnostics_enabled=False,
        restore_targets=targets,
    )
    output = source_fixture.parent / f"rehearsal-stages-{uuid4()}"
    output.mkdir()
    report = {
        "kind": "real-staged-restore-and-production-worker",
        "scope": "real-backend-no-browser",
        "phase": "starting",
        "targets": {key: str(value) for key, value in target_ids.items()},
        "backup_id": str(args.backup_id),
        "checks": [],
    }

    def persist():
        (output / "receipt.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
        )

    persist()
    engine = build_engine(settings)
    check_database(engine)
    actual_restore = backups.restore_isolated
    actual_complete = store.complete
    restore_calls = []
    principal = None
    try:
        for target in targets.values():
            rehearsal._probe_empty(settings, target)
        report["checks"].append(
            "both-actual-loopback-test-databases-empty-and-data-roots-absent"
        )
        with Session(engine) as session, session.begin():
            owner = session.get(User, UUID(admin["identities"]["owner"]["user_id"]))
            record, _ = issue_session(
                session,
                owner,
                uuid4(),
                "Synthetic isolated restore acceptance",
                "admin",
            )
            principal = Principal(
                owner.id,
                record.id,
                record.client_id,
                "admin",
                roles_for(session, owner.id),
            )
        with Session(engine) as session:
            assert session.get(ConfigurationHead, 1).current_version == 5

        def enqueue(label):
            report["phase"] = f"prepare-{label}"
            persist()
            with Session(engine) as session:
                authority = rehearsal.precheck_restore_request(
                    session, principal, credentials["owner"]["password"]
                )
                session.commit()
                preview = rehearsal.build_restore_preview(
                    settings,
                    authority=authority,
                    backup_id=args.backup_id,
                    target_id=target_ids[label],
                )
                public = rehearsal.authorize_restore_preview(
                    session,
                    principal,
                    settings,
                    preview,
                    credentials["owner"]["password"],
                )
                session.commit()
                with rehearsal.prepare_restore_submission(
                    settings,
                    owner_user_id=principal.user_id,
                    session_id=principal.session_id,
                    preview_id=public.preview_id,
                ) as prepared:
                    job = rehearsal.enqueue_restore_rehearsal(
                        session,
                        principal,
                        settings,
                        prepared=prepared,
                        password=credentials["owner"]["password"],
                    )
                    session.commit()
                report[label + "_job_id"] = job["job_id"]
                report[label + "_preview_id"] = str(public.preview_id)
                persist()
                return UUID(job["job_id"])

        normal_job_id = enqueue("normal")

        def counted(*arguments, **keywords):
            restore_calls.append(1)
            return actual_restore(*arguments, **keywords)

        backups.restore_isolated = counted

        def lose_completion(session, lease, effect):
            raise store.LeaseLost("synthetic-lost-source-completion")

        store.complete = lose_completion
        report["phase"] = "real-target-restore-before-lost-source-completion"
        persist()
        assert Worker(engine, settings).run_once()
        store.complete = actual_complete
        control = rehearsal._control(settings, target_ids["normal"])
        assert (control / "verified.json").is_file()
        normal = targets[target_ids["normal"]]

        def files():
            return {
                item.relative_to(normal.data_directory).as_posix(): hashlib.sha256(
                    item.read_bytes()
                ).hexdigest()
                for item in normal.data_directory.rglob("*")
                if item.is_file()
            }

        before = files()
        with Session(engine) as session, session.begin():
            job = session.get(BackgroundJob, normal_job_id)
            assert job.status == "running" and job.lease_generation == 1
            job.lease_until = store.stamp(session) - timedelta(seconds=1)
        report["phase"] = "fresh-second-generation-reverifies-existing-private-receipt"
        persist()
        assert Worker(engine, settings).run_once()
        with Session(engine) as session:
            job = session.get(BackgroundJob, normal_job_id)
            assert job.status == "succeeded" and job.lease_generation == 2
            assert job.result["code"] == "restore_rehearsal_verified"
            assert job.result["artifact_id"] == str(target_ids["normal"])
            assert job.attempt == 2
        assert restore_calls == [1] and files() == before
        report["checks"].extend(
            [
                "real-pg-restore-plus-entire-target-db-session-epoch-balance-and-file-verification",
                "lost-source-completion-retains-private-verified-receipt",
                "generation-two-independently-reverifies-receipt-and-performs-no-second-restore",
            ]
        )
        partial_job_id = enqueue("partial")
        partial = targets[target_ids["partial"]]
        partial_root = private_directory(partial.data_directory)
        witness = b"synthetic-partial-target-must-remain"
        with private_open(
            partial_root / "partial-witness.bin", partial_root, create=True
        ) as stream:
            stream.write(witness)
        report["phase"] = "nonempty-partial-target-refuses-restore"
        persist()
        assert Worker(engine, settings).run_once()
        with Session(engine) as session:
            job = session.get(BackgroundJob, partial_job_id)
            assert (
                job.status == "failed" and job.error_code == "restore_target_not_empty"
            )
            administration.control_job(
                session,
                principal,
                job_id=partial_job_id,
                action="retry",
                password=credentials["owner"]["password"],
                settings=settings,
            )
            session.commit()
        assert Worker(engine, settings).run_once()
        with Session(engine) as session:
            job = session.get(BackgroundJob, partial_job_id)
            assert (
                job.status == "failed" and job.error_code == "restore_target_not_empty"
            )
            assert job.manual_retries == 1
        assert (partial_root / "partial-witness.bin").read_bytes() == witness
        assert not (
            rehearsal._control(settings, target_ids["partial"]) / "verified.json"
        ).exists()
        with backups._connection(rehearsal._target_settings(partial)) as connection:
            assert (
                connection.execute(
                    "SELECT count(*) FROM pg_tables WHERE schemaname='public'"
                ).fetchone()[0]
                == 0
            )
        assert restore_calls == [1]
        report["checks"].extend(
            [
                "partial-target-is-permanently-preserved-and-normal-retry-does-not-overwrite",
                "partial-target-database-remains-empty-no-verified-receipt",
            ]
        )
        report["phase"] = "passed"
        report["actual_pg_restore_calls"] = len(restore_calls)
        report["target_data_preserved"] = True
        report["source_config_version_preserved"] = 5
        persist()
        print(
            json.dumps(
                {
                    "receipt": str(output / "receipt.json"),
                    "phase": report["phase"],
                    "checks": len(report["checks"]),
                    "actual_pg_restore_calls": len(restore_calls),
                }
            )
        )
    except Exception as error:  # noqa: BLE001 - Native errors may contain private connection details.
        report["failed_phase"] = report["phase"]
        report["phase"] = "failed"
        report["failure"] = {
            "name": type(error).__name__,
            "code": getattr(error, "code", "unexpected_failure"),
        }
        persist()
        print(
            json.dumps(
                {
                    "receipt": str(output / "receipt.json"),
                    "phase": "failed",
                    **report["failure"],
                }
            )
        )
        raise SystemExit(1) from None
    finally:
        backups.restore_isolated = actual_restore
        store.complete = actual_complete
        if principal is not None:
            with Session(engine) as session, session.begin():
                session.get(UserSession, principal.session_id).revoked_at = now()
        engine.dispose()


if __name__ == "__main__":
    main()
