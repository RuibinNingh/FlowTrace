"""Compile actual Windows runner directory logic and exercise OS boundaries."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import uuid
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    source = repository / "apps/flowtrace/windows/runner"
    vswhere = Path(os.environ["ProgramFiles(x86)"]) / "Microsoft Visual Studio/Installer/vswhere.exe"
    visual_studio = subprocess.check_output([str(vswhere), "-latest", "-products", "*", "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"], text=True).strip()
    devcmd = Path(visual_studio) / "Common7/Tools/VsDevCmd.bat"
    # The fixed developer command only exports the compiler environment. User
    # paths/arguments never become shell code; compilation below uses argv.
    raw = subprocess.check_output(f'cmd.exe /d /s /c ""{devcmd}" -arch=x64 -host_arch=x64 >nul && set"', text=True)
    environment = {key.upper(): value for key, value in os.environ.items()}
    for line in raw.splitlines():
        if "=" in line and not line.startswith("="):
            key, value = line.split("=", 1)
            environment[key.upper()] = value
    probe = output / "data_directory_probe.exe"
    compiler = shutil.which("cl.exe", path=environment["PATH"])
    if compiler is None:
        raise RuntimeError("The configured Visual Studio C++ compiler is unavailable")
    command = [compiler, "/nologo", "/std:c++17", "/EHsc", "/W4", "/WX", "/utf-8", "/DUNICODE", "/D_UNICODE", "/DNOMINMAX", f"/I{source}", str(repository / "tests/e2e/windows/data_directory_probe.cpp"), str(source / "data_directory.cpp"), f"/Fe:{probe}", "/link", "shell32.lib", "ole32.lib"]
    compile_result = subprocess.run(command, cwd=output, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (output / "compile.log").write_text(compile_result.stdout, encoding="utf-8")
    compile_result.check_returncode()
    run = str(uuid.uuid4())
    data = output.parent / f"native-data-{run}"
    first = subprocess.Popen([str(probe), str(data)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    checks = []
    try:
        assert first.stdout.readline().strip() == "leased"
        second = subprocess.run([str(probe), str(data)], input="", text=True, capture_output=True, timeout=10)
        assert second.returncode == 73 and second.stdout.strip() == "busy"
        checks.append("second_writer_rejected_by_live_os_handle")
        first.kill()
        first.wait(timeout=10)
        third = subprocess.run([str(probe), str(data)], input="exit\n", text=True, capture_output=True, timeout=10)
        assert third.returncode == 0 and third.stdout.strip() == "leased"
        checks.append("os_termination_releases_lease_despite_persisted_lock_file")
        for value in ("relative", r"\\server\share\flowtrace", str(output / "must-not-create")):
            denied = subprocess.run([str(probe), value], input="", text=True, capture_output=True, timeout=10)
            assert denied.returncode == 1 and denied.stdout.strip() == "denied", value
        assert not (output / "must-not-create").exists()
        checks.append("relative_unc_installation_paths_rejected_before_creation")
        alias = output.parent / f"native-alias-{run}"
        junction = subprocess.run(["cmd.exe", "/d", "/c", "mklink", "/J", str(alias), str(output)], text=True, capture_output=True)
        junction.check_returncode()
        denied = subprocess.run([str(probe), str(alias / "must-not-create")], input="", text=True, capture_output=True, timeout=10)
        assert denied.returncode == 1 and not (output / "must-not-create").exists()
        checks.append("junction_to_installation_rejected_before_child_creation")
        receipt = {"status": "passed", "checks": checks, "source": "apps/flowtrace/windows/runner/data_directory.cpp", "native_gui_tested": False}
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")
        print(json.dumps(receipt))
    finally:
        if first.poll() is None:
            first.kill()
            first.wait(timeout=10)


if __name__ == "__main__":
    main()
