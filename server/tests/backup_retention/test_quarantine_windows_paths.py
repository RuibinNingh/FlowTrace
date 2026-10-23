"""Actual Windows long object paths, only new pytest-owned synthetic packages."""

import hashlib
import os
from pathlib import Path
from uuid import uuid4

import pytest

from flowtrace_server.backups import quarantine, retention
from flowtrace_server.backups.quarantine_schemas import QuarantinePlan
from flowtrace_server.config import Settings
from flowtrace_server.imports.parsers import canonical

from .test_retention_io import package, snapshot


@pytest.mark.skipif(os.name != "nt", reason="Actual Windows path API regression")
def test_windows_long_member(tmp_path):
    base = tmp_path / ("p" * max(1, 113 - len(str(tmp_path)) - 1))
    settings = Settings(_env_file=None, environment="test", data_directory=base)
    instance, epoch = uuid4(), uuid4()
    backup_id, source, manifest = package(settings, instance=instance, epoch=epoch)
    data = b"Synthetic original object; preserve exact bytes."
    digest = hashlib.sha256(data).hexdigest()
    member = f"objects/{digest}.bin"
    (source / "objects").mkdir()
    (source / member).write_bytes(data)
    manifest["files"].append({"path": member, "size_bytes": len(data), "sha256": digest})
    (source / "manifest.json").write_bytes(canonical(manifest))
    witness_id, witness_path, _ = package(settings, instance=instance, epoch=epoch)
    stamp = retention._verify_stamp(settings, backup_id)
    witness = retention._verify_stamp(settings, witness_id)
    plan = QuarantinePlan(
        intent_id=uuid4(),
        job_id=uuid4(),
        actor_id=uuid4(),
        source_instance_id=instance,
        source_epoch=epoch,
        config_version=0,
        packages=(stamp,),
        selection_sha256=hashlib.sha256(canonical([stamp.model_dump(mode="json")])).hexdigest(),
    )
    target = base / "backup-quarantine" / str(plan.intent_id) / "backups" / str(backup_id)
    assert len(str(source / member)) < 260 < len(str(target / member))
    original, protected = snapshot(source), snapshot(witness_path)
    with quarantine.prepare_quarantine(settings, plan=plan, witness=witness) as prepared:
        result = quarantine.execute_quarantine(prepared, check_authority=lambda: None)
    assert not source.exists()
    extended = Path("\\\\?\\" + str(target))
    assert snapshot(extended) == original
    assert (extended / member).read_bytes() == data
    with quarantine.prepare_quarantine(settings, plan=plan, witness=witness) as prepared:
        replay = quarantine.execute_quarantine(prepared, check_authority=lambda: None)
    assert replay == result and snapshot(extended) == original
    assert snapshot(witness_path) == protected
