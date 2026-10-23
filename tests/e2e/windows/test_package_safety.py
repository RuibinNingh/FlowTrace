"""Exercise ZIP/path/checksum guards with synthetic files, never executable input."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import zipfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    shell = shutil.which('pwsh.exe') or shutil.which('powershell.exe')
    if shell is None:
        raise RuntimeError('PowerShell is required')
    environment = dict(os.environ)
    if Path(shell).name.lower() == 'powershell.exe':
        environment['PSModulePath'] = str(Path(environment['SystemRoot']) / 'System32/WindowsPowerShell/v1.0/Modules')
    repository = Path(__file__).resolve().parents[3]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    script = repository / "deployment/windows/Expand-FlowTrace.ps1"
    payload = b"synthetic non-executable release checksum fixture\n"
    manifest = {"product": "FlowTrace", "version": "0.0.0+0", "platform": "windows-x64", "data_in_package": False, "signature_status": "SyntheticFixture", "files": [{"path": "flowtrace.exe", "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}]}
    checks = []
    cases = {
        "valid": {},
        "traversal": {"FlowTrace/../../outside.txt": b"must never escape"},
        "case-duplicate": {"flowtrace/FLOWTRACE.EXE": payload},
        "unmanifested": {"FlowTrace/unexpected.dll": b"not listed"},
        "checksum": {"FlowTrace/flowtrace.exe": b"changed payload"},
        "wrong-zip-sha": {},
    }
    for name, additions in cases.items():
        archive = output / f"{name}.zip"
        entries = {"FlowTrace/flowtrace.exe": payload, "FlowTrace/release-manifest.json": json.dumps(manifest).encode()}
        entries.update(additions)
        with zipfile.ZipFile(archive, "w") as package:
            for path, content in entries.items():
                package.writestr(path, content)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if name == "wrong-zip-sha":
            digest = "0" * 64
        install = output / f"install-{name}"
        result = subprocess.run([shell, "-NoProfile", "-NonInteractive", "-File", str(script), "-Package", str(archive), "-Sha256", digest, "-InstallDirectory", str(install)], env=environment, text=True, encoding='utf-8', errors='replace', stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (output / f"{name}.log").write_text(result.stdout, encoding="utf-8")
        if name == "valid":
            assert result.returncode == 0, result.stdout
        else:
            assert result.returncode != 0, f"Unsafe case accepted: {name}"
        assert not (output / "outside.txt").exists()
        checks.append({"case": name, "exit_code": result.returncode, "expected": "accepted" if name == "valid" else "rejected"})
    receipt = {"status": "passed", "checks": checks, "actual_app_runtime_tested": False}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")
    print(json.dumps(receipt))


if __name__ == "__main__":
    main()
