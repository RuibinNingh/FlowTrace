"""Windows aliases on new pytest trees; UNC goldens never access a network."""

import os
from pathlib import Path
from types import SimpleNamespace

import pytest

from flowtrace_server.backups import quarantine, retention
from flowtrace_server.backups.leases import (
    BackupLeaseError,
    backup_exclusive_lease,
    backup_read_lease,
)

from .test_quarantine_io import io_case as io_case
from .test_retention_io import snapshot

pytestmark = pytest.mark.skipif(os.name != "nt", reason="Actual Windows alias semantics")


@pytest.mark.parametrize(
    "configured,expected",
    [
        (r"C:\flowtrace-root\private", "\\\\?\\C:\\flowtrace-root\\private"),
        (r"\\?\C:\flowtrace-root\private", "\\\\?\\C:\\flowtrace-root\\private"),
        (r"C:\flowtrace-root\part\..\private", "\\\\?\\C:\\flowtrace-root\\private"),
        (
            r"\\flowtrace-no-network.invalid\share\private",
            "\\\\?\\UNC\\flowtrace-no-network.invalid\\share\\private",
        ),
        (
            r"\\?\UNC\flowtrace-no-network.invalid\share\private",
            "\\\\?\\UNC\\flowtrace-no-network.invalid\\share\\private",
        ),
    ],
)
def test_io_root_canonical_alias_goldens_do_not_double_prefix_or_access_unc(configured, expected):
    # Only pure path/abspath operations. Do not invoke _paths/private_directory,
    # stat, resolve, mkdir or any network share for these reserved host strings.
    settings = SimpleNamespace(data_directory=Path(configured))
    assert str(quarantine._io_root(settings)) == expected
    assert str(quarantine._io_root(SimpleNamespace(data_directory=Path(expected)))) == expected


def extended_settings(case):
    return case.settings.model_copy(update={"data_directory": quarantine._io_root(case.settings)})


def test_alias_file_leases_are_same_entity_but_prepared_settings_keys_are_distinct(io_case):
    case = io_case
    extended = extended_settings(case)
    assert retention._settings_key(case.settings) != retention._settings_key(extended)
    originals = [snapshot(item[1]) for item in case.selected]
    witness = snapshot(case.witness_path)
    with quarantine.prepare_quarantine(
        case.settings, plan=case.plan, witness=case.witness
    ) as prepared:
        # Both path spellings address the same real Windows package.lock files.
        for identifier, _, _ in case.selected:
            with pytest.raises(BackupLeaseError, match="backup_busy"):
                with backup_read_lease(extended, identifier, timeout_seconds=0):
                    pytest.fail("extended spelling bypassed an existing selected EX")
        with pytest.raises(BackupLeaseError, match="backup_busy"):
            with backup_exclusive_lease(extended, (case.witness.backup_id,), timeout_seconds=0):
                pytest.fail("extended spelling bypassed an existing witness SH")
        target = quarantine._io_root(case.settings) / "backup-quarantine" / str(case.plan.intent_id)
        before = snapshot(target)
        prepared.settings = extended
        with pytest.raises(quarantine.QuarantineError, match="backup_quarantine_input_invalid"):
            quarantine.execute_quarantine(
                prepared, check_authority=lambda: pytest.fail("rebound settings reached policy")
            )
        assert snapshot(target) == before
    assert [snapshot(item[1]) for item in case.selected] == originals
    assert snapshot(case.witness_path) == witness
    with backup_exclusive_lease(
        extended,
        (*[item[0] for item in case.selected], case.witness.backup_id),
        timeout_seconds=0,
    ):
        pass


def test_already_extended_configuration_keeps_one_root_through_move_receipts_and_replay(io_case):
    case = io_case
    extended = extended_settings(case)
    root = quarantine._io_root(extended)
    assert root == extended.data_directory
    originals = {item[0]: snapshot(item[1]) for item in case.selected}
    witness = snapshot(case.witness_path)
    with quarantine.prepare_quarantine(extended, plan=case.plan, witness=case.witness) as prepared:
        assert prepared.settings_key == retention._settings_key(extended)
        source, destination, target, receipts = quarantine._paths(extended, case.plan)
        assert source == root / "backups"
        assert destination == root / "backup-quarantine" / str(case.plan.intent_id)
        assert target == destination / "backups" and receipts == destination / "receipts"
        for identifier, _, _ in case.selected:
            with pytest.raises(BackupLeaseError, match="backup_busy"):
                with backup_read_lease(case.settings, identifier, timeout_seconds=0):
                    pytest.fail("ordinary spelling bypassed extended selected EX")
        result = quarantine.execute_quarantine(prepared, check_authority=lambda: None)
    assert all(not item[1].exists() for item in case.selected)
    assert all(snapshot(target / str(identifier)) == data for identifier, data in originals.items())
    frozen = snapshot(destination)
    with quarantine.prepare_quarantine(extended, plan=case.plan, witness=case.witness) as prepared:
        replay = quarantine.execute_quarantine(prepared, check_authority=lambda: None)
    assert replay == result and snapshot(destination) == frozen
    assert snapshot(case.witness_path) == witness
