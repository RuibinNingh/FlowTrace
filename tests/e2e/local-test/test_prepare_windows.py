"""Only Prepare/Status and a short owned sleeper; never Install/Start/task APIs."""

import ensurepip
import hashlib
import importlib.resources
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import zipfile
from pathlib import Path
from types import SimpleNamespace

import pytest

REPOSITORY = Path(__file__).resolve().parents[3]
SCRIPTS = REPOSITORY / "deployment/local-test/windows"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def shell():
    result = shutil.which("pwsh.exe")
    if not result:
        pytest.skip("PowerShell7 on Windows is required")
    return result


def seed_python():
    explicit = os.environ.get("FLOWTRACE_TEST_SEED_PYTHON")
    if explicit:
        return Path(explicit).resolve()
    version = ensurepip.version()
    if (
        importlib.resources.files(ensurepip)
        .joinpath("_bundled", f"pip-{version}-py3-none-any.whl")
        .is_file()
    ):
        return Path(sys._base_executable)
    uv = shutil.which("uv")
    if uv:
        found = subprocess.run(
            [uv, "python", "find", "--managed-python", "3.13"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
            env={**os.environ, "UV_OFFLINE": "1"},
        )
        if not found.returncode:
            return Path(found.stdout.strip()).resolve()
    pytest.skip("Explicit Python3.12/3.13 with complete ensurepip bundle required")


def invoke(script, arguments):
    return subprocess.run(
        [
            shell(),
            "-NoProfile",
            "-NonInteractive",
            "-File",
            str(script),
            *map(str, arguments),
        ],
        check=False,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=30,
    )


@pytest.fixture
def prepared_inputs(tmp_path, sealed_web):
    source = tmp_path / "explicit-inputs"
    source.mkdir()
    wheel = source / "flowtrace_server-0.1.0-py3-none-any.whl"
    with zipfile.ZipFile(wheel, "w") as archive:
        archive.writestr(
            "flowtrace_server-0.1.0.dist-info/METADATA",
            "Name: flowtrace-server\nVersion: 0.1.0\n",
        )
        archive.writestr(
            "flowtrace_server/tools/local_test_service.py",
            "# synthetic, never installed",
        )
    dependency = source / "synthetic_dependency-1.0-py3-none-any.whl"
    with zipfile.ZipFile(dependency, "w") as archive:
        archive.writestr("synthetic_dependency.py", "# synthetic, never installed")
    lock = source / "requirements.lock"
    lock.write_text(
        f"synthetic-dependency==1.0 \\\n    --hash=sha256:{sha(dependency)}\n",
        encoding="utf-8",
    )
    wheelhouse = source / "wheelhouse.zip"
    with zipfile.ZipFile(wheelhouse, "w") as archive:
        archive.write(dependency, dependency.name)
    web = source / "sealed-web.zip"
    with zipfile.ZipFile(web, "w") as archive:
        for path in sealed_web[0].iterdir():
            archive.write(path, "FlowTrace-Web/" + path.name)
    pg = source / "postgresql-distribution"
    (pg / "bin").mkdir(parents=True)
    files = []
    for name in ("initdb.exe", "pg_ctl.exe", "postgres.exe", "pg_dump.exe"):
        path = pg / "bin" / name
        path.write_bytes(b"synthetic non-executable PG fixture; must never run")
        files.append(
            {"path": "bin/" + name, "bytes": path.stat().st_size, "sha256": sha(path)}
        )
    pg_manifest = source / "postgres.json"
    pg_manifest.write_text(
        json.dumps({"format": "flowtrace-postgresql-distribution-v1", "files": files}),
        encoding="utf-8",
    )
    http_port, database_port = free_port(), free_port()
    while database_port == http_port:
        database_port = free_port()
    return {
        "Python": seed_python(),
        "ServerWheel": wheel,
        "RequirementsLock": lock,
        "WheelhouseZip": wheelhouse,
        "WebZip": web,
        "PostgresDistribution": pg,
        "PostgresManifest": pg_manifest,
        "HttpPort": http_port,
        "DatabasePort": database_port,
    }


def free_port():
    with socket.socket() as server:
        server.bind(("127.0.0.1", 0))
        return server.getsockname()[1]


def prepare_arguments(inputs, root, version="synthetic-1", *, override=None):
    names = {
        "Python": "PythonSha256",
        "ServerWheel": "ServerWheelSha256",
        "RequirementsLock": "RequirementsLockSha256",
        "WheelhouseZip": "WheelhouseSha256",
        "WebZip": "WebSha256",
        "PostgresManifest": "PostgresManifestSha256",
    }
    values = {
        "Root": root,
        "Version": version,
    }
    values.update(inputs)
    values.update(
        {names[name]: sha(path) for name, path in inputs.items() if name in names}
    )
    values.update(override or {})
    return [item for key, value in values.items() for item in ("-" + key, value)]


def tree_hashes(root):
    return {
        path.relative_to(root).as_posix(): sha(path)
        for path in root.rglob("*")
        if path.is_file()
    }


def test_prepare_stages_exact_inputs_and_status_does_not_install(
    prepared_inputs, tmp_path
):
    root = tmp_path / "new-service-root"
    result = invoke(
        SCRIPTS / "Prepare-FlowTraceLocalTest.ps1",
        prepare_arguments(prepared_inputs, root),
    )
    assert result.returncode == 0, result.stdout
    receipt = json.loads((root / "versions/synthetic-1/prepared.json").read_bytes())
    assert (
        not receipt["installed"]
        and not receipt["started"]
        and not receipt["task_registered"]
    )
    assert receipt["python_seed_preflight"]["bundle_resource_verified"] is True
    assert receipt["python_seed_preflight"]["actual_venv_seeded"] is False
    for entry in receipt["files"]:
        path = root / "versions/synthetic-1" / entry["path"]
        assert sha(path) == entry["sha256"] and path.stat().st_size == entry["bytes"]
    for absent in (
        "private",
        "data",
        "postgresql/data",
        "versions/synthetic-1/venv",
        "installed.json",
    ):
        assert not (root / absent).exists()
    status = invoke(
        SCRIPTS / "Manage-FlowTraceLocalTest.ps1", ["-Action", "Status", "-Root", root]
    )
    assert status.returncode == 0, status.stdout
    assert json.loads(status.stdout)["status"] == "prepared-not-installed"


@pytest.mark.parametrize(
    "unsafe", ["hash", "traversal", "unmanifested", "bad-resource", "reserved-port"]
)
def test_bad_prepare_preserves_existing_version(prepared_inputs, tmp_path, unsafe):
    root = tmp_path / "new-service-root"
    first = invoke(
        SCRIPTS / "Prepare-FlowTraceLocalTest.ps1",
        prepare_arguments(prepared_inputs, root),
    )
    assert first.returncode == 0, first.stdout
    original = tree_hashes(root)
    overrides = {}
    if unsafe == "hash":
        overrides["WebSha256"] = "0" * 64
    elif unsafe == "reserved-port":
        overrides["DatabasePort"] = 55432
    else:
        if unsafe == "bad-resource":
            with zipfile.ZipFile(prepared_inputs["WebZip"]) as archive:
                content = {name: archive.read(name) for name in archive.namelist()}
            content["FlowTrace-Web/main.dart.js"] = (
                b"changed but manifest hash retained"
            )
            with zipfile.ZipFile(prepared_inputs["WebZip"], "w") as archive:
                for name, value in content.items():
                    archive.writestr(name, value)
        else:
            with zipfile.ZipFile(prepared_inputs["WebZip"], "a") as archive:
                if unsafe == "traversal":
                    archive.writestr(
                        "FlowTrace-Web/../../outside.txt", "must not escape"
                    )
                else:
                    archive.writestr("FlowTrace-Web/private.env", "synthetic private")
        overrides["WebSha256"] = sha(prepared_inputs["WebZip"])
    rejected = invoke(
        SCRIPTS / "Prepare-FlowTraceLocalTest.ps1",
        prepare_arguments(prepared_inputs, root, "synthetic-2", override=overrides),
    )
    assert rejected.returncode != 0
    assert tree_hashes(root) == original
    assert not (root / "versions/synthetic-2").exists()
    assert not (tmp_path / "outside.txt").exists()


def test_pid_reuse_executable_or_config_mismatch_never_terminates_other_process(
    tmp_path,
):
    script = tmp_path / "owned-sleeper-probe.ps1"
    script.write_text(
        r"""
param([string]$Common,[string]$Python,[string]$Work)
. $Common
$marker=[Guid]::NewGuid().ToString()
$child=Start-LocalChild $Python @('-c','import time;time.sleep(20)','--flowtrace-local-test-probe',$marker) $Work
$record=$null
try{
  $record=Get-ProcessRecord $child.Id @($marker)
  if(-not(Test-OwnedProcess $record)){throw 'owned identity missing'}
  foreach($changed in @('time','exe','marker')){
    $wrong=$record.Clone()
    switch($changed){'time'{$wrong.start_ticks++};'exe'{$wrong.exe=$wrong.exe+'.unrelated'};'marker'{$wrong.markers=@('unrelated-guid')}}
    if(Test-OwnedProcess $wrong -Terminate){throw 'unrelated identity accepted'}
    if($child.HasExited){throw 'unrelated identity terminated sleeper'}
  }
  if(-not(Test-OwnedProcess $record -Terminate)){throw 'owned termination failed'}
  if(-not $child.WaitForExit(3000)){throw 'owned sleeper did not exit'}
  @{checks=4;status='passed';only_temporary_sleeper=$true}|ConvertTo-Json -Compress
}finally{
  if($null -ne $record -and -not $child.HasExited){$null=Test-OwnedProcess $record -Terminate}
}
""",
        encoding="utf-8",
    )
    result = invoke(
        script,
        [
            "-Common",
            SCRIPTS / "common.ps1",
            "-Python",
            sys._base_executable,
            "-Work",
            tmp_path,
        ],
    )
    assert result.returncode == 0, result.stdout
    assert json.loads(result.stdout)["status"] == "passed"


def test_staged_copy_must_match_originally_authorized_hash(
    prepared_inputs, tmp_path, monkeypatch
):
    root = tmp_path / "new-service-root"
    result = invoke(
        SCRIPTS / "Prepare-FlowTraceLocalTest.ps1",
        prepare_arguments(prepared_inputs, root),
    )
    assert result.returncode == 0, result.stdout
    before = tree_hashes(root)
    spec = importlib.util.spec_from_file_location(
        "local_artifact_guard", SCRIPTS / "artifact_guard.py"
    )
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)
    names = {
        "python": "Python",
        "wheel": "ServerWheel",
        "lock": "RequirementsLock",
        "wheelhouse": "WheelhouseZip",
        "web": "WebZip",
        "postgres_manifest": "PostgresManifest",
    }
    values = {
        "root": str(root),
        "version": "synthetic-late-mutation",
        "user_sid": json.loads((root / "service-owner.json").read_bytes())["user_sid"],
        "postgres": str(prepared_inputs["PostgresDistribution"]),
        "http_port": prepared_inputs["HttpPort"],
        "database_port": prepared_inputs["DatabasePort"],
    }
    for name, parameter in names.items():
        values[name] = str(prepared_inputs[parameter])
        values[name + "_sha256"] = sha(prepared_inputs[parameter])
    copy = guard.shutil.copyfile

    def mutate_between_validation_and_copy(source, destination):
        if source == prepared_inputs["ServerWheel"]:
            source.write_bytes(b"different bytes after initial validation")
        return copy(source, destination)

    monkeypatch.setattr(guard.shutil, "copyfile", mutate_between_validation_and_copy)
    with pytest.raises(ValueError, match="staged_artifact_changed"):
        guard.prepare(SimpleNamespace(**values))
    after = tree_hashes(root)
    assert all(after[name] == value for name, value in before.items())
    assert not (root / "versions/synthetic-late-mutation/prepared.json").exists()


def test_logon_task_identity_helper_never_calls_task_scheduler(tmp_path):
    script = tmp_path / "task-identity-only.ps1"
    script.write_text(
        r"""
param([string]$Common,[string]$Work)
. $Common
$config=@{root=$Work;version_directory=(Join-Path $Work 'versions/synthetic');service_id=[Guid]::NewGuid().ToString()}
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
function New-FakeTask {
  return @{TaskPath='\';Principal=@{UserId=$sid;RunLevel='Limited'};Actions=@(@{Execute=(Join-Path $PSHOME 'pwsh.exe');WorkingDirectory=$config.root;Arguments=(Get-LogonTaskArguments $config)})}
}
$task=New-FakeTask
if(-not(Test-OwnedLogonTask $task $config $sid)){throw 'valid task metadata rejected'}
if(-not $task.Actions[0].Arguments.Contains('-WindowStyle Hidden')){throw 'hidden argument missing'}
foreach($kind in @('user','elevated','exe','arguments','directory','folder')){
  $wrong=New-FakeTask
  switch($kind){
    'user'{$wrong.Principal.UserId='unrelated-user'}
    'elevated'{$wrong.Principal.RunLevel='Highest'}
    'exe'{$wrong.Actions[0].Execute='unrelated.exe'}
    'arguments'{$wrong.Actions[0].Arguments+=' --extra-action'}
    'directory'{$wrong.Actions[0].WorkingDirectory+='-unrelated'}
    'folder'{$wrong.TaskPath='\unrelated\'}
  }
  if(Test-OwnedLogonTask $wrong $config $sid){throw 'unrelated task metadata accepted'}
}
@{status='passed';metadata_checks=7;task_scheduler_called=$false}|ConvertTo-Json -Compress
""",
        encoding="utf-8",
    )
    result = invoke(script, ["-Common", SCRIPTS / "common.ps1", "-Work", tmp_path])
    assert result.returncode == 0, result.stdout
    assert json.loads(result.stdout)["task_scheduler_called"] is False


def test_pg_time_rotation_policy_and_bootstrap_reset_preserve_unconfirmed_data(
    tmp_path,
):
    script = tmp_path / "pg-log-configuration-only.ps1"
    script.write_text(
        r"""
param([string]$Common,[string]$Work,[int]$Port)
. $Common
$rootPath=Join-Path $Work "own service's synthetic root"
foreach($relative in @('private','data','postgresql/data')){$null=New-Item -ItemType Directory -Path (Join-Path $rootPath $relative)}
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$config=@{root=$rootPath;service_id=[Guid]::NewGuid().ToString();database_port=$Port}
Write-LocalJson (Join-Path $rootPath 'service-owner.json') @{format='flowtrace-local-test-owner-v1';service_id=$config.service_id;user_sid=$sid}
$data=Join-Path $rootPath 'postgresql/data'
$configuration=Join-Path $data 'postgresql.conf'
[IO.File]::WriteAllText($configuration,'# synthetic configuration: no PostgreSQL executable exists')
Initialize-PostgresLogging $config
$policyPath=Join-Path $data 'flowtrace-local-logging.conf'
$policy=Get-Content -LiteralPath $policyPath -Raw
foreach($expected in @('logging_collector = on',"log_filename = 'postgresql-%H.log'",'log_rotation_age = 60','log_rotation_size = 0','log_truncate_on_rotation = on',"service''s synthetic root")){
  if(-not $policy.Contains($expected)){throw 'time rotation policy missing'}
}
$initialConfiguration=Get-Content -LiteralPath $configuration -Raw
try{Initialize-PostgresLogging $config;throw 'second initialization accepted'}catch{if($_.Exception.Message -eq 'second initialization accepted'){throw}}
if((Get-Content -LiteralPath $configuration -Raw) -cne $initialConfiguration){throw 'existing configuration overwritten'}
$log=Join-Path $rootPath 'data/postgresql-bootstrap.log'
[IO.File]::WriteAllText($log,'retain unconfirmed bootstrap bytes')
$statePath=Join-Path $rootPath 'private/database-process.json'
$pidPath=Join-Path $data 'postmaster.pid'
# An owned but live record must be preserved, even when it is this probe host.
Write-LocalJson $statePath @{service_id=$config.service_id;record=@{pid=$PID}}
try{Reset-PostgresBootstrapLog $config;throw 'live database accepted'}catch{if($_.Exception.Message -eq 'live database accepted'){throw}}
if((Get-Content -LiteralPath $log -Raw) -cne 'retain unconfirmed bootstrap bytes'){throw 'live bootstrap altered'}
Remove-Item -LiteralPath $statePath
# An unconfirmed PID file is never treated as an owned stopped database.
[IO.File]::WriteAllText($pidPath,"$PID`n$data`n")
try{Reset-PostgresBootstrapLog $config;throw 'unknown pid accepted'}catch{if($_.Exception.Message -eq 'unknown pid accepted'){throw}}
if((Get-Content -LiteralPath $log -Raw) -cne 'retain unconfirmed bootstrap bytes'){throw 'unconfirmed bootstrap altered'}
Remove-Item -LiteralPath $pidPath
# A changed policy must fail before truncation.
[IO.File]::WriteAllText($policyPath,$policy+'# changed')
try{Reset-PostgresBootstrapLog $config;throw 'changed policy accepted'}catch{if($_.Exception.Message -eq 'changed policy accepted'){throw}}
if((Get-Content -LiteralPath $log -Raw) -cne 'retain unconfirmed bootstrap bytes'){throw 'bad policy bootstrap altered'}
[IO.File]::WriteAllText($policyPath,$policy)
Reset-PostgresBootstrapLog $config
if((Get-Item -LiteralPath $log).Length -ne 0){throw 'owned stopped bootstrap not reset'}
Remove-Item -LiteralPath $log
$unrelated=Join-Path $Work 'synthetic unrelated bytes.txt'
[IO.File]::WriteAllText($unrelated,'never truncate a hardlink target')
$null=New-Item -ItemType HardLink -Path $log -Target $unrelated
try{Reset-PostgresBootstrapLog $config;throw 'hardlink accepted'}catch{if($_.Exception.Message -eq 'hardlink accepted'){throw}}
if((Get-Content -LiteralPath $unrelated -Raw) -cne 'never truncate a hardlink target'){throw 'hardlink target truncated'}
@{status='passed';pg_started=$false;only_synthetic_configuration=$true;byte_hard_limit=$false}|ConvertTo-Json -Compress
""",
        encoding="utf-8",
    )
    result = invoke(
        script,
        ["-Common", SCRIPTS / "common.ps1", "-Work", tmp_path, "-Port", free_port()],
    )
    assert result.returncode == 0, result.stdout
    receipt = json.loads(result.stdout)
    assert receipt["pg_started"] is False and receipt["byte_hard_limit"] is False


def test_missing_declared_seed_wheel_fails_without_changing_python_or_creating_venv(
    tmp_path,
):
    spec = importlib.util.spec_from_file_location(
        "local_seed_probe", SCRIPTS / "artifact_guard.py"
    )
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)
    executable = seed_python()
    before = sha(executable)
    result = subprocess.run(
        [
            str(executable),
            "-I",
            "-c",
            "import ensurepip; ensurepip.version=lambda: '0.0.missing'\n"
            + guard.SEED_RESOURCE_PROBE,
        ],
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
        cwd=tmp_path,
    )
    assert result.returncode != 0
    assert "python_ensurepip_bundle_unavailable" in result.stderr
    assert (
        "Traceback" not in result.stderr
        and "no global Python was modified" in result.stderr
    )
    assert sha(executable) == before
    assert not list(tmp_path.iterdir())
