"""Package real preserved candidates; verify profile metadata without running them."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--production-build", type=Path, required=True)
    parser.add_argument("--production-version", required=True)
    parser.add_argument("--production-qa", action="store_true")
    parser.add_argument("--local-test-build", type=Path, required=True)
    parser.add_argument("--local-test-version", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    shell = shutil.which("pwsh.exe") or shutil.which("powershell.exe")
    if shell is None:
        raise RuntimeError("PowerShell is required")
    environment = dict(os.environ)
    if Path(shell).name.lower() == "powershell.exe":
        environment["PSModulePath"] = str(
            Path(environment["SystemRoot"]) / "System32/WindowsPowerShell/v1.0/Modules"
        )
    repository = Path(__file__).resolve().parents[3]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    package_script = repository / "deployment/windows/Package-FlowTrace.ps1"
    expand_script = repository / "deployment/windows/Expand-FlowTrace.ps1"
    checks = []
    candidates = (
        ("production", args.production_build.resolve(), args.production_version, args.production_qa),
        ("local-test", args.local_test_build.resolve(), args.local_test_version, False),
    )

    def run(script: Path, arguments: list[str], log: str) -> subprocess.CompletedProcess:
        result = subprocess.run(
            [shell, "-NoProfile", "-NonInteractive", "-File", str(script), *arguments],
            check=False, env=environment, text=True, encoding="utf-8", errors="replace",
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        (output / log).write_text(result.stdout, encoding="utf-8")
        return result

    for profile, source, version, qa in candidates:
        original_exe_hash = digest(source / "flowtrace.exe")
        destination = output / f"package-{profile}"
        arguments = ["-BuildDirectory", str(source), "-OutputDirectory", str(destination), "-Version", version]
        if profile == "local-test":
            arguments += ["-BuildProfile", profile]
        if qa:
            arguments += ["-Qa"]
        result = run(package_script, arguments, f"package-{profile}.log")
        assert result.returncode == 0, result.stdout
        archive = destination / f"FlowTrace-{version}-windows-x64.zip"
        archive_hash = digest(archive)
        assert archive.with_suffix(".zip.sha256").read_text().split()[0] == archive_hash
        installed = output / f"installed-{profile}"
        result = run(expand_script, ["-Package", str(archive), "-Sha256", archive_hash, "-InstallDirectory", str(installed)], f"expand-{profile}.log")
        assert result.returncode == 0, result.stdout
        bundle = installed / "FlowTrace"
        manifest = json.loads((bundle / "release-manifest.json").read_text(encoding="utf-8-sig"))
        assert manifest["build_profile"] == profile
        assert manifest["qa"] is qa
        assert manifest["build_profile_file"] == "BUILD-PROFILE.txt"
        description = (bundle / manifest["build_profile_file"]).read_text(encoding="utf-8-sig")
        assert f"build_profile={profile}" in description
        assert f"qa_entry={qa}" in description
        assert "packaging does not inspect or change" in description
        assert "FLOWTRACE_LOCAL_TEST=true" in description
        assert any(item["path"] == "BUILD-PROFILE.txt" for item in manifest["files"])
        assert digest(bundle / "flowtrace.exe") == original_exe_hash
        assert digest(source / "flowtrace.exe") == original_exe_hash
        checks.append({"case": profile, "status": "passed", "version": version, "qa": qa, "zip": str(archive), "sha256": archive_hash, "file_count": len(manifest["files"]), "signature_status": manifest["signature_status"]})

    rejected = output / "invalid-profile-must-not-exist"
    result = run(package_script, ["-BuildDirectory", str(args.production_build.resolve()), "-OutputDirectory", str(rejected), "-Version", args.production_version, "-BuildProfile", "public-http"], "invalid-profile.log")
    assert result.returncode != 0, "Invalid profile was accepted"
    assert not rejected.exists(), "Invalid profile created output"
    checks.append({"case": "invalid-profile", "status": "rejected-before-output"})
    receipt = {"status": "passed", "checks": checks, "compile_defines_verified_by_this_script": False, "actual_app_runtime_tested": False, "final_delivery_package": False}
    (output / "receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(receipt, ensure_ascii=False))


if __name__ == "__main__":
    main()
