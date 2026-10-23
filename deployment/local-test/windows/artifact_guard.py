"""Standard-library-only staging; never installs or starts a service."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import zipfile
from datetime import UTC, datetime
from email.parser import BytesParser
from pathlib import Path, PurePosixPath
from uuid import uuid4

MAX_BYTES = 2 * 1024**3
SHA = re.compile(r"[0-9a-fA-F]{64}\Z")
VERSION = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,63}\Z")
RESERVED = re.compile(
    r"(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?\Z", re.IGNORECASE
)

SEED_RESOURCE_PROBE = r"""
import ensurepip, importlib.resources, json, sys, zipfile
from email.parser import BytesParser
try:
    if sys.version_info[:2] not in {(3, 12), (3, 13)}:
        raise ValueError
    version = ensurepip.version()
    resource = importlib.resources.files(ensurepip).joinpath('_bundled', f'pip-{version}-py3-none-any.whl')
    if not resource.is_file():
        raise ValueError
    with importlib.resources.as_file(resource) as wheel:
        with zipfile.ZipFile(wheel) as archive:
            names = archive.namelist()
            metadata_names = [name for name in names if name.endswith('.dist-info/METADATA')]
            if len(metadata_names) != 1 or 'pip/__main__.py' not in names or archive.testzip() is not None:
                raise ValueError
            metadata = BytesParser().parsebytes(archive.read(metadata_names[0]))
            if metadata['Name'] != 'pip' or metadata['Version'] != version:
                raise ValueError
    print(json.dumps({'python_version': sys.version.split()[0], 'bundled_pip_version': version,
                      'bundle_resource_verified': True, 'actual_venv_seeded': False}))
except Exception:
    sys.exit('python_ensurepip_bundle_unavailable: declared bundled pip wheel is missing or invalid; choose a complete Python runtime; no global Python was modified')
"""


class InvalidPreparation(ValueError):
    pass


def fail(code):
    raise InvalidPreparation(code)


def plain_path(value, *, file=False, directory=False):
    path = Path(os.path.abspath(value))
    for ancestor in (path, *path.parents):
        if ancestor.is_symlink() or ancestor.is_junction():
            fail("linked_path_rejected")
    if file and not path.is_file():
        fail("input_file_missing")
    if directory and not path.is_dir():
        fail("input_directory_missing")
    return path


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            checksum.update(chunk)
    return checksum.hexdigest()


def checked_file(value, expected):
    path = plain_path(value, file=True)
    if not SHA.fullmatch(expected) or digest(path) != expected.lower():
        fail("artifact_hash_mismatch")
    return path


def python_seed_preflight(executable):
    result = subprocess.run(
        [str(executable), "-I", "-c", SEED_RESOURCE_PROBE],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=15,
        check=False,
    )
    if result.returncode:
        fail("python_ensurepip_bundle_unavailable")
    metadata = json.loads(result.stdout)
    if (
        metadata.get("bundle_resource_verified") is not True
        or metadata.get("actual_venv_seeded") is not False
    ):
        fail("python_ensurepip_preflight_invalid")
    return metadata


def relative_name(name):
    if not isinstance(name, str) or not name or "\\" in name:
        fail("artifact_path_invalid")
    path = PurePosixPath(name)
    if path.is_absolute() or any(
        part in {".", "..", ""}
        or ":" in part
        or part.endswith((".", " "))
        or RESERVED.fullmatch(part)
        for part in name.split("/")
    ):
        fail("artifact_path_invalid")
    return path.as_posix()


def archive_entries(path):
    entries, names, total = [], set(), 0
    with zipfile.ZipFile(path) as archive:
        for item in archive.infolist():
            name = relative_name(item.filename.rstrip("/"))
            if name.casefold() in names or stat.S_ISLNK(item.external_attr >> 16):
                fail("archive_duplicate_or_link")
            names.add(name.casefold())
            if item.is_dir():
                continue
            total += item.file_size
            if total > MAX_BYTES or len(entries) >= 100000 or item.flag_bits & 1:
                fail("archive_budget_or_encryption")
            entries.append(name)
    if not entries:
        fail("archive_empty")
    return entries


def extract(path, destination, *, prefix=""):
    names = archive_entries(path)
    with zipfile.ZipFile(path) as archive:
        for name in names:
            if prefix and not name.startswith(prefix):
                fail("archive_unexpected_root")
            relative = relative_name(name[len(prefix) :])
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(name) as source, target.open("xb") as output:
                shutil.copyfileobj(source, output, 1024 * 1024)


def web_manifest(archive_path):
    names = archive_entries(archive_path)
    manifests = [
        name for name in names if PurePosixPath(name).name == "flowtrace-release.json"
    ]
    if len(manifests) != 1:
        fail("web_manifest_missing_or_ambiguous")
    prefix = manifests[0][: -len("flowtrace-release.json")]
    if any(not name.startswith(prefix) for name in names):
        fail("web_unexpected_root")
    with zipfile.ZipFile(archive_path) as archive:
        manifest = json.loads(archive.read(manifests[0]))
        if (
            set(manifest) != {"schema", "release_id", "resources"}
            or manifest["schema"] != 1
        ):
            fail("web_manifest_invalid")
        if not SHA.fullmatch(manifest["release_id"]) or not isinstance(
            manifest["resources"], dict
        ):
            fail("web_manifest_invalid")
        required = {
            "index.html",
            "main.dart.js",
            "sqlite3.wasm",
            "drift_worker.js",
            "flowtrace_shell.js",
            "flutter_bootstrap.js",
        }
        if not required.issubset(manifest["resources"]):
            fail("web_resource_missing")
        for name, metadata in manifest["resources"].items():
            relative_name(name)
            if any(char in name for char in "%?#") or set(metadata) != {
                "sha256",
                "bytes",
            }:
                fail("web_resource_invalid")
            content = archive.read(prefix + name)
            if (
                len(content) != metadata["bytes"]
                or hashlib.sha256(content).hexdigest() != metadata["sha256"]
            ):
                fail("web_resource_hash_mismatch")
        expected = set(manifest["resources"]) | {
            "flowtrace-release.json",
            "flutter_service_worker.js",
        }
        if {name[len(prefix) :] for name in names} - expected - {".last_build_id"}:
            fail("web_unmanifested_file")
        worker = archive.read(prefix + "flutter_service_worker.js").decode("utf-8")
        embedded = re.search(r"const RELEASE = (\{[^\n]*\});", worker)
        if not embedded or json.loads(embedded.group(1)) != manifest:
            fail("web_worker_manifest_mismatch")
    return prefix, manifest


def prepare(args):
    root = plain_path(args.root)
    if not VERSION.fullmatch(args.version) or ".." in args.version:
        fail("deployment_version_invalid")
    if args.http_port == args.database_port or any(
        not 1024 <= port <= 65535 or port in {18080, 55432}
        for port in (args.http_port, args.database_port)
    ):
        fail("deployment_ports_invalid")
    paths = {}
    for name in ("python", "wheel", "lock", "wheelhouse", "web", "postgres_manifest"):
        paths[name] = checked_file(getattr(args, name), getattr(args, name + "_sha256"))
    seed_preflight = python_seed_preflight(paths["python"])
    postgres = plain_path(args.postgres, directory=True)
    scripts = plain_path(Path(__file__).parent, directory=True)
    if any(
        path.is_relative_to(root) or root.is_relative_to(path)
        for path in (postgres, scripts)
    ):
        fail("deployment_source_overlap")
    if any(path.is_relative_to(root) for path in paths.values()):
        fail("deployment_source_overlap")
    owner_path = root / "service-owner.json"
    if root.exists():
        if not owner_path.is_file():
            fail("existing_root_not_owned")
        owner = json.loads(owner_path.read_bytes())
        if (
            owner.get("format") != "flowtrace-local-test-owner-v1"
            or owner.get("user_sid") != args.user_sid
        ):
            fail("existing_root_not_owned")
    else:
        owner = {
            "format": "flowtrace-local-test-owner-v1",
            "service_id": str(uuid4()),
            "user_sid": args.user_sid,
        }
    target = root / "versions" / args.version
    if target.exists():
        fail("version_already_exists")
    with zipfile.ZipFile(paths["wheel"]) as wheel:
        metadata_names = [
            name
            for name in archive_entries(paths["wheel"])
            if name.endswith(".dist-info/METADATA")
        ]
        if (
            len(metadata_names) != 1
            or "flowtrace_server/tools/local_test_service.py" not in wheel.namelist()
        ):
            fail("server_wheel_invalid")
        metadata = BytesParser().parsebytes(wheel.read(metadata_names[0]))
        if (
            not metadata["Name"]
            or metadata["Name"].replace("_", "-").lower() != "flowtrace-server"
        ):
            fail("server_wheel_invalid")
        server_version = metadata["Version"]
    lock_text = paths["lock"].read_text(encoding="utf-8-sig")
    allowed_hashes = set(re.findall(r"--hash=sha256:([0-9a-f]{64})", lock_text))
    if not allowed_hashes or any(
        line.lstrip().startswith(("--index", "--extra-index", "--find-links", "-e "))
        for line in lock_text.splitlines()
    ):
        fail("production_hash_lock_invalid")
    for raw_line in lock_text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "://" in line or "@" in line:
            fail("production_hash_lock_invalid")
        if line.startswith("--hash=sha256:"):
            if not re.fullmatch(r"--hash=sha256:[0-9a-f]{64}\s*\\?", line):
                fail("production_hash_lock_invalid")
        elif not re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9_.-]*(?:\[[A-Za-z0-9_,.-]+\])?==[A-Za-z0-9._+!-]+(?:\s*;[^\\]*)?\s*\\?",
            line,
        ):
            fail("production_hash_lock_invalid")
    with zipfile.ZipFile(paths["wheelhouse"]) as archive:
        wheel_names = archive_entries(paths["wheelhouse"])
        if any("/" in name or not name.endswith(".whl") for name in wheel_names):
            fail("wheelhouse_must_be_flat_wheels")
        if any(
            hashlib.sha256(archive.read(name)).hexdigest() not in allowed_hashes
            for name in wheel_names
        ):
            fail("wheelhouse_hash_not_locked")
    prefix, manifest = web_manifest(paths["web"])
    pg = json.loads(paths["postgres_manifest"].read_bytes())
    if pg.get("format") != "flowtrace-postgresql-distribution-v1" or not isinstance(
        pg.get("files"), list
    ):
        fail("postgres_manifest_invalid")
    pg_files = {}
    for item in pg["files"]:
        name = relative_name(item["path"])
        if name.casefold() in {entry.casefold() for entry in pg_files}:
            fail("postgres_duplicate_path")
        path = checked_file(postgres / name, item["sha256"])
        if path.stat().st_size != item["bytes"]:
            fail("postgres_file_size_mismatch")
        pg_files[name] = item
    actual_pg = set()
    for path in postgres.rglob("*"):
        plain_path(path)
        if path.is_file():
            actual_pg.add(path.relative_to(postgres).as_posix())
    if actual_pg != set(pg_files) or not {
        "bin/initdb.exe",
        "bin/pg_ctl.exe",
        "bin/postgres.exe",
        "bin/pg_dump.exe",
    }.issubset(pg_files):
        fail("postgres_distribution_incomplete")
    required_scripts = {
        "Prepare-FlowTraceLocalTest.ps1",
        "Manage-FlowTraceLocalTest.ps1",
        "Supervisor.ps1",
        "common.ps1",
        "artifact_guard.py",
        "README.md",
    }
    if any(not (scripts / name).is_file() for name in required_scripts):
        fail("management_scripts_incomplete")
    root.mkdir(parents=True, exist_ok=True)
    if not owner_path.exists():
        owner_path.write_text(json.dumps(owner, indent=2), encoding="utf-8")
    target.mkdir(parents=True)
    artifacts = target / "artifacts"
    artifacts.mkdir()
    staged = {}
    for name, filename in (
        ("wheel", paths["wheel"].name),
        ("lock", "requirements.lock"),
        ("web", "sealed-web.zip"),
        ("wheelhouse", "wheelhouse.zip"),
        ("postgres_manifest", "postgresql-manifest.json"),
    ):
        staged[name] = artifacts / filename
        shutil.copyfile(paths[name], staged[name])
        if digest(staged[name]) != getattr(args, name + "_sha256").lower():
            fail("staged_artifact_changed")
    extract(staged["wheelhouse"], target / "wheelhouse")
    extract(staged["web"], target / "web", prefix=prefix)
    for name, item in pg_files.items():
        destination = target / "postgresql" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(postgres / name, destination)
        if digest(destination) != item["sha256"]:
            fail("staged_postgres_changed")
    for name in required_scripts:
        destination = target / "management" / name
        destination.parent.mkdir(exist_ok=True)
        shutil.copyfile(scripts / name, destination)
    receipt = {
        **owner,
        "format": "flowtrace-local-test-prepared-v1",
        "version": args.version,
        "server_version": server_version,
        "root": str(root),
        "version_directory": str(target),
        "python": str(paths["python"]),
        "python_sha256": digest(paths["python"]),
        "python_base": str(plain_path(sys._base_executable, file=True)),
        "python_base_sha256": digest(plain_path(sys._base_executable, file=True)),
        "wheel": str(artifacts / paths["wheel"].name),
        "http_host": "127.0.0.1",
        "http_port": args.http_port,
        "database_port": args.database_port,
        "web_release_id": manifest["release_id"],
        "created_utc": datetime.now(UTC).isoformat(),
        "installed": False,
        "started": False,
        "task_registered": False,
        "dependency_resolution": "deferred_to_explicit_offline_install",
        "python_seed_preflight": seed_preflight,
        "inputs": {
            name: {
                "path": str(path),
                "sha256": getattr(args, name + "_sha256").lower(),
            }
            for name, path in paths.items()
        },
        "files": [
            {
                "path": path.relative_to(target).as_posix(),
                "bytes": path.stat().st_size,
                "sha256": digest(path),
            }
            for path in sorted(target.rglob("*"))
            if path.is_file()
        ],
    }
    (target / "prepared.json").write_text(
        json.dumps(receipt, indent=2), encoding="utf-8"
    )
    return {
        "status": "prepared",
        "service_id": owner["service_id"],
        "version_directory": str(target),
        "installed": False,
        "started": False,
        "task_registered": False,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("root", "version", "user-sid", "postgres"):
        parser.add_argument("--" + name, required=True)
    for name in ("python", "wheel", "lock", "wheelhouse", "web", "postgres-manifest"):
        parser.add_argument("--" + name, required=True)
        parser.add_argument("--" + name + "-sha256", required=True)
    parser.add_argument("--http-port", required=True, type=int)
    parser.add_argument("--database-port", required=True, type=int)
    args = parser.parse_args()
    try:
        print(json.dumps(prepare(args)))
    except InvalidPreparation as error:
        parser.exit(
            1, f"local_test_preparation_failed: {error}; existing versions preserved\n"
        )
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        zipfile.BadZipFile,
        subprocess.TimeoutExpired,
    ):
        parser.exit(
            1,
            "local_test_preparation_failed: inputs rejected; existing versions preserved\n",
        )


if __name__ == "__main__":
    main()
