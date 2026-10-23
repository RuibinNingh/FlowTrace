"""Pure I/O only on new pytest UUID trees; callbacks are synthetic policy.

No job/permission/PG success is claimed. The module is not mounted anywhere.
"""

import hashlib
from types import SimpleNamespace
from uuid import uuid4

import pytest
from pydantic import ValidationError

from flowtrace_server.backups import quarantine, retention
from flowtrace_server.backups.leases import (
    BackupLeaseError,
    backup_exclusive_lease,
    backup_read_lease,
)
from flowtrace_server.backups.quarantine_schemas import QuarantinePlan, QuarantineSubmission
from flowtrace_server.config import Settings
from flowtrace_server.imports.parsers import canonical

from .test_retention_io import package, snapshot


@pytest.fixture
def io_case(tmp_path):
    settings = Settings(_env_file=None, environment="test", data_directory=tmp_path / "runtime")
    instance, epoch = uuid4(), uuid4()
    selected = [package(settings, instance=instance, epoch=epoch) for _ in range(2)]
    selected.sort(key=lambda item: str(item[0]))
    stamps = tuple(retention._verify_stamp(settings, item[0]) for item in selected)
    witness = package(settings, instance=instance, epoch=epoch)
    plan = QuarantinePlan(
        intent_id=uuid4(),
        job_id=uuid4(),
        actor_id=uuid4(),
        source_instance_id=instance,
        source_epoch=epoch,
        config_version=0,
        packages=stamps,
        selection_sha256=hashlib.sha256(
            canonical([stamp.model_dump(mode="json") for stamp in stamps])
        ).hexdigest(),
    )
    return SimpleNamespace(
        settings=settings,
        plan=plan,
        selected=selected,
        witness=retention._verify_stamp(settings, witness[0]),
        witness_path=witness[1],
    )


def prepare(case):
    return quarantine.prepare_quarantine(case.settings, plan=case.plan, witness=case.witness)


def destination(case):
    return case.settings.data_directory / "backup-quarantine" / str(case.plan.intent_id)


def test_closed_plan_and_submission_reject_paths_changed_source_and_noncanonical_selection(io_case):
    case = io_case
    values = case.plan.model_dump()
    for bad in (
        {**values, "path": "../private-sentinel"},
        {**values, "url": "https://sentinel.invalid"},
        {**values, "selection_sha256": "0" * 64},
        {**values, "packages": tuple(reversed(case.plan.packages))},
        {**values, "source_epoch": uuid4()},
        {**values, "packages": case.plan.packages * 11},
    ):
        with pytest.raises(ValidationError):
            QuarantinePlan.model_validate(bad)
    with pytest.raises(ValidationError):
        QuarantineSubmission.model_validate(
            {
                "preview_id": uuid4(),
                "request_id": uuid4(),
                "selection_sha256": case.plan.selection_sha256,
                "shell": "sentinel",
            }
        )


def test_atomic_moves_exact_bytes_and_lost_completion_reuses_original_receipts(io_case):
    case = io_case
    before = {identifier: snapshot(path) for identifier, path, _ in case.selected}
    witness_before = snapshot(case.witness_path)
    with prepare(case) as prepared:
        result = quarantine.execute_quarantine(prepared, check_authority=lambda: None)
        assert len(result.receipts) == 2
        for identifier, original, _ in case.selected:
            assert not original.exists()
            assert snapshot(destination(case) / "backups" / str(identifier)) == before[identifier]
            with pytest.raises(BackupLeaseError):
                with backup_read_lease(case.settings, identifier, timeout_seconds=0):
                    pytest.fail("selected EX was not retained through caller completion")
        with backup_read_lease(case.settings, case.witness.backup_id, timeout_seconds=0):
            pass
        with pytest.raises(BackupLeaseError):
            with backup_exclusive_lease(
                case.settings, (case.witness.backup_id,), timeout_seconds=0
            ):
                pytest.fail("witness SH was not retained")
    frozen = snapshot(destination(case))
    with prepare(case) as reopened:
        replay = quarantine.execute_quarantine(reopened, check_authority=lambda: None)
    assert replay == result and snapshot(destination(case)) == frozen
    assert snapshot(case.witness_path) == witness_before
    with backup_exclusive_lease(
        case.settings,
        (*[item.backup_id for item in case.plan.packages], case.witness.backup_id),
        timeout_seconds=0,
    ):
        pass


@pytest.mark.parametrize("stop", ["false_authority", "budget"])
def test_before_effect_refusal_retains_every_source_and_releases_leases(io_case, stop):
    case = io_case
    before = [snapshot(path) for _, path, _ in case.selected]
    with pytest.raises((quarantine.QuarantineError, RuntimeError)), prepare(case) as prepared:

        def budget():
            raise RuntimeError("synthetic budget exhausted")

        quarantine.execute_quarantine(
            prepared,
            check_authority=lambda: False if stop == "false_authority" else None,
            check_budget=budget if stop == "budget" else None,
        )
    assert [snapshot(path) for _, path, _ in case.selected] == before
    with backup_exclusive_lease(
        case.settings, tuple(item.backup_id for item in case.plan.packages), timeout_seconds=0
    ):
        pass


def test_only_verified_receipted_prefix_can_continue_after_interruption(io_case):
    case = io_case
    first, second = case.plan.packages
    second_before = snapshot(case.selected[1][1])

    def stop_after_first_receipt():
        if (destination(case) / "receipts" / f"{first.backup_id}.json").exists():
            raise RuntimeError("synthetic stop after one durable effect")

    with pytest.raises(RuntimeError), prepare(case) as prepared:
        quarantine.execute_quarantine(prepared, check_authority=stop_after_first_receipt)
    receipt_path = destination(case) / "receipts" / f"{first.backup_id}.json"
    first_receipt = receipt_path.read_bytes()
    assert snapshot(case.selected[1][1]) == second_before
    assert not case.selected[0][1].exists()
    with prepare(case) as prepared:
        result = quarantine.execute_quarantine(prepared, check_authority=lambda: None)
    assert receipt_path.read_bytes() == first_receipt
    assert result.receipts[0].package == first and result.receipts[1].package == second


def test_rename_before_receipt_failure_keeps_partial_and_refuses_to_guess_success(
    io_case, monkeypatch
):
    case = io_case
    actual = quarantine._write_record

    def fail_receipt(path, root, value):
        if isinstance(value, quarantine.QuarantineReceipt):
            raise OSError("synthetic record write failure")
        return actual(path, root, value)

    monkeypatch.setattr(quarantine, "_write_record", fail_receipt)
    with pytest.raises(OSError), prepare(case) as prepared:
        quarantine.execute_quarantine(prepared, check_authority=lambda: None)
    frozen = snapshot(destination(case))
    assert not case.selected[0][1].exists() and case.selected[1][1].exists()
    monkeypatch.setattr(quarantine, "_write_record", actual)
    with pytest.raises(quarantine.QuarantineError, match="backup_quarantine_partial"):
        prepare(case)
    assert snapshot(destination(case)) == frozen


@pytest.mark.parametrize("bad", ["both_exist", "both_missing", "unexpected_directory"])
def test_ambiguous_source_target_or_unknown_tree_is_retained(io_case, bad, tmp_path):
    case = io_case
    first = case.plan.packages[0]
    target = destination(case) / "backups" / str(first.backup_id)
    if bad == "both_exist":
        target.mkdir(parents=True)
        (target / "sentinel.txt").write_bytes(b"preserve preexisting target")
    elif bad == "both_missing":
        case.selected[0][1].rename(tmp_path / "preserved-missing-source-evidence")
    else:
        (destination(case) / "unknown").mkdir(parents=True)
    source_before = snapshot(case.settings.data_directory / "backups")
    target_before = snapshot(destination(case)) if destination(case).exists() else {}
    with pytest.raises(quarantine.QuarantineError):
        prepare(case)
    assert snapshot(case.settings.data_directory / "backups") == source_before
    for name, value in target_before.items():
        assert (destination(case) / name).read_bytes() == value


@pytest.mark.parametrize("change", ["receipt", "target_bytes", "other_job"])
def test_replay_never_accepts_changed_receipt_package_or_job_binding(io_case, change):
    case = io_case
    with prepare(case) as prepared:
        quarantine.execute_quarantine(prepared, check_authority=lambda: None)
    first = case.plan.packages[0]
    if change == "receipt":
        (destination(case) / "receipts" / f"{first.backup_id}.json").write_bytes(b"{partial")
    elif change == "target_bytes":
        (destination(case) / "backups" / str(first.backup_id) / "database.dump").write_bytes(
            b"PGDMPchanged-retain-this-evidence"
        )
    else:
        case.plan = case.plan.model_copy(update={"job_id": uuid4()})
    frozen = snapshot(destination(case))
    with pytest.raises((quarantine.QuarantineError, retention.ApiError)):
        prepare(case)
    assert snapshot(destination(case)) == frozen


def test_native_rename_noreplace_never_replaces_even_empty_target(tmp_path):
    source, target = tmp_path / "source", tmp_path / "target"
    source.mkdir()
    target.mkdir()
    (source / "sentinel").write_bytes(b"new isolated temporary evidence")
    with pytest.raises(quarantine.QuarantineError):
        quarantine._rename_noreplace(source, target)
    assert (source / "sentinel").read_bytes() == b"new isolated temporary evidence"
    assert target.is_dir() and list(target.iterdir()) == []


def test_closed_or_wrong_root_prepared_context_cannot_execute(io_case):
    case = io_case
    prepared = prepare(case)
    prepared.close()
    with pytest.raises(quarantine.QuarantineError, match="backup_quarantine_input_invalid"):
        quarantine.execute_quarantine(prepared, check_authority=lambda: None)
    with prepare(case) as prepared:
        prepared.settings = case.settings.model_copy(
            update={"data_directory": case.settings.data_directory / "other-root"}
        )
        with pytest.raises(quarantine.QuarantineError, match="backup_quarantine_input_invalid"):
            quarantine.execute_quarantine(prepared, check_authority=lambda: None)
    assert all(path.exists() for _, path, _ in case.selected)


@pytest.mark.parametrize("replacement", ["plan", "witness"])
def test_prepared_replacement_cannot_execute_packages_without_the_original_locks(
    io_case, replacement
):
    case = io_case
    identifier, path, _ = package(
        case.settings, instance=case.plan.source_instance_id, epoch=case.plan.source_epoch
    )
    new_stamp = retention._verify_stamp(case.settings, identifier)
    other = QuarantinePlan(
        intent_id=uuid4(),
        job_id=uuid4(),
        actor_id=case.plan.actor_id,
        source_instance_id=case.plan.source_instance_id,
        source_epoch=case.plan.source_epoch,
        config_version=0,
        packages=(new_stamp,),
        selection_sha256=hashlib.sha256(canonical([new_stamp.model_dump(mode="json")])).hexdigest(),
    )
    frozen = snapshot(case.settings.data_directory / "backups")
    with prepare(case) as prepared:
        if replacement == "plan":
            prepared.plan = other
        else:
            prepared.witness = new_stamp
        with pytest.raises(quarantine.QuarantineError, match="backup_quarantine_input_invalid"):
            quarantine.execute_quarantine(prepared, check_authority=lambda: None)
    assert snapshot(case.settings.data_directory / "backups") == frozen and path.exists()
    assert not (case.settings.data_directory / "backup-quarantine" / str(other.intent_id)).exists()
