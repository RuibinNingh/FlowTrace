"""Exercise offline Windows data copy/restore with a previously accepted QA root.

All destinations are new UUID paths; original data and failed scenes are kept.
The only original-file mutation is the non-authoritative instance PID metadata.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
from pathlib import Path


def sha(path: Path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    source = args.source.resolve(strict=True)
    if not source.is_relative_to(repository / "outputs/validation/P7"):
        raise ValueError("Only the isolated P7 QA root is permitted")
    if not (source / "qa-ready.json").is_file():
        raise ValueError("The original native QA acceptance receipt is required")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    shell = shutil.which("pwsh.exe") or shutil.which("powershell.exe")
    if shell is None:
        raise RuntimeError("PowerShell is required")
    environment = dict(os.environ)
    if Path(shell).name.lower() == "powershell.exe":
        environment["PSModulePath"] = str(Path(environment["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/Modules")
    checks = []

    def invoke(name, script, *parameters, passed=True):
        result = subprocess.run([shell, "-NoProfile", "-NonInteractive", "-File", str(repository / "deployment/windows" / script), *map(str, parameters)], env=environment, text=True, encoding="utf-8", errors="replace", stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (output / f"{name}.log").write_text(result.stdout, encoding="utf-8")
        assert (result.returncode == 0) == passed, result.stdout
        checks.append({"case": name, "exit_code": result.returncode, "expected": "accepted" if passed else "rejected"})

    original_sha = sha(source / "flowtrace.sqlite")
    # A real live Windows handle uses the runner's share mode. No GUI/process
    # inventory or personal app data is touched by this OS-file-lock probe.
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint, ctypes.c_uint, ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint, ctypes.c_void_p]
    kernel.CreateFileW.restype = ctypes.c_void_p
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel.CreateFileW(str(source / "flowtrace.instance.lock"), 0xC0000000, 1, None, 3, 0x80, None)
    assert handle not in (None, ctypes.c_void_p(-1).value)
    try:
        invoke("active-writer", "Snapshot-FlowTraceData.ps1", "-DataDirectory", source, "-SnapshotDirectory", output / "must-not-snapshot-live", passed=False)
        assert not (output / "must-not-snapshot-live").exists()
    finally:
        kernel.CloseHandle(handle)
    snapshot = output / "snapshot"
    invoke("offline-snapshot", "Snapshot-FlowTraceData.ps1", "-DataDirectory", source, "-SnapshotDirectory", snapshot)
    manifest = json.loads((snapshot / "snapshot-manifest.json").read_text(encoding="utf-8-sig"))
    assert manifest["system_credentials_included"] is False
    assert len(manifest["files"]) >= 2
    assert (snapshot / "flowtrace.sqlite").is_file()
    assert not (snapshot / "qa-manifest.json").exists()
    assert not (snapshot / "flowtrace.instance.lock").exists()
    for entry in manifest["files"]:
        assert sha(source / entry["path"]) == entry["sha256"]
        assert sha(snapshot / entry["path"]) == entry["sha256"]
    restored = output / "restored"
    invoke("restore-new-root", "Restore-FlowTraceData.ps1", "-SnapshotDirectory", snapshot, "-DataDirectory", restored)
    assert sha(restored / "flowtrace.sqlite") == original_sha
    with sqlite3.connect((restored / "flowtrace.sqlite").as_uri() + "?mode=ro", uri=True) as connection:
        assert connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        table_names = [row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
        assert "local_entities" in table_names and "pending_operations" in table_names
        table_counts = {name: connection.execute(f'SELECT count(*) FROM "{name}"').fetchone()[0] for name in table_names}
    assert table_counts["local_entities"] == 3
    assert table_counts["pending_operations"] == 3
    invoke("existing-snapshot", "Snapshot-FlowTraceData.ps1", "-DataDirectory", source, "-SnapshotDirectory", snapshot, passed=False)
    invoke("existing-data-root", "Restore-FlowTraceData.ps1", "-SnapshotDirectory", snapshot, "-DataDirectory", restored, passed=False)
    assert sha(restored / "flowtrace.sqlite") == original_sha
    damaged = output / "damaged-snapshot"
    shutil.copytree(snapshot, damaged)
    with (damaged / "flowtrace.sqlite").open("ab") as file:
        file.write(b"intentional-test-damage")
    invoke("damaged-snapshot", "Restore-FlowTraceData.ps1", "-SnapshotDirectory", damaged, "-DataDirectory", output / "must-not-restore-damaged", passed=False)
    assert not (output / "must-not-restore-damaged").exists()
    invalid = output / "invalid-manifest"
    shutil.copytree(snapshot, invalid)
    bad_manifest = dict(manifest)
    bad_manifest["files"] = [{"path": "../outside.sqlite", "bytes": 0, "sha256": "0" * 64}]
    (invalid / "snapshot-manifest.json").write_text(json.dumps(bad_manifest), encoding="utf-8")
    invoke("traversing-manifest", "Restore-FlowTraceData.ps1", "-SnapshotDirectory", invalid, "-DataDirectory", output / "must-not-traverse", passed=False)
    assert not (output / "must-not-traverse").exists()
    empty = output / "empty-source"
    empty.mkdir()
    invoke("missing-database", "Snapshot-FlowTraceData.ps1", "-DataDirectory", empty, "-SnapshotDirectory", output / "must-not-copy-empty", passed=False)
    assert not (output / "must-not-copy-empty").exists()
    alias = output / "snapshot-alias"
    junction = subprocess.run(["cmd.exe", "/d", "/c", "mklink", "/J", str(alias), str(snapshot)], text=True, capture_output=True)
    junction.check_returncode()
    invoke("junction-source", "Restore-FlowTraceData.ps1", "-SnapshotDirectory", alias, "-DataDirectory", output / "must-not-follow-junction", passed=False)
    assert not (output / "must-not-follow-junction").exists()
    malicious = output / "nested-junction-snapshot"
    malicious.mkdir()
    shutil.copyfile(snapshot / "flowtrace.sqlite", malicious / "flowtrace.sqlite")
    (malicious / "attachments").mkdir()
    outside = output / "outside-synthetic-assets"
    outside.mkdir()
    (outside / "ordinary-child").mkdir()
    outside_file = outside / "ordinary-child/synthetic.blob"
    outside_file.write_bytes(b"must not copy through a non-immediate attachment ancestor alias")
    nested = subprocess.run(["cmd.exe", "/d", "/c", "mklink", "/J", str(malicious / "attachments/alias"), str(outside)], text=True, capture_output=True)
    nested.check_returncode()
    malicious_manifest = dict(manifest)
    malicious_manifest["files"] = [entry for entry in manifest["files"] if entry["path"] == "flowtrace.sqlite"] + [{"path": "attachments/alias/ordinary-child/synthetic.blob", "bytes": outside_file.stat().st_size, "sha256": sha(outside_file)}]
    (malicious / "snapshot-manifest.json").write_text(json.dumps(malicious_manifest), encoding="utf-8")
    invoke("nested-attachment-junction", "Restore-FlowTraceData.ps1", "-SnapshotDirectory", malicious, "-DataDirectory", output / "must-not-follow-nested-junction", passed=False)
    assert not (output / "must-not-follow-nested-junction").exists()
    assert sha(source / "flowtrace.sqlite") == original_sha
    receipt = {"status": "passed", "checks": checks, "original_database_unchanged": True, "restored_integrity_check": "ok", "entity_count": table_counts["local_entities"], "outbox_count": table_counts["pending_operations"], "snapshot_files": len(manifest["files"]), "credentials_copied": False, "network_tested": False, "full_business_journey_tested": False}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")
    print(json.dumps(receipt))


if __name__ == "__main__":
    main()
