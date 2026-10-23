"""Seal a NEW Flutter web build with a complete SHA-256 offline shell.

No SDK or third-party Python modules are required. Existing sealed builds cannot
be overwritten. The release identifier covers the pre-seal input and shell code;
the generated manifest covers the final bytes of every runtime resource.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re

SCHEMA = 1
EXCLUDED = {"flutter_service_worker.js", "flowtrace_service_worker.js", "flowtrace-release.json", ".last_build_id"}
REQUIRED = {"index.html", "flowtrace_shell.js", "flutter_bootstrap.js", "main.dart.js", "sqlite3.wasm", "drift_worker.js"}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def seal(build: Path, source: Path) -> dict:
    build = build.resolve(strict=True)
    source = source.resolve(strict=True)
    if (build / "flowtrace-release.json").exists():
        raise ValueError("A sealed release is immutable; create a new build directory")
    resources = {}
    for file in sorted(build.rglob("*")):
        if file.is_symlink():
            raise ValueError("Symlinks are forbidden in release resources")
        if file.is_file() and file.name not in EXCLUDED:
            rel = file.relative_to(build).as_posix()
            if any(char in rel for char in ("?", "#", "%", "\\")):
                raise ValueError("Release filenames must have unambiguous URL paths")
            resources[rel] = file.read_bytes()
    if missing := REQUIRED - resources.keys():
        raise ValueError(f"Missing required build resources: {sorted(missing)}")
    shell = (source / "flowtrace_shell.js").read_text(encoding="utf-8")
    worker = (source / "flowtrace_service_worker.js").read_text(encoding="utf-8")
    if "__FLOWTRACE_RELEASE__" not in shell or "__FLOWTRACE_MANIFEST__" not in worker:
        raise ValueError("Shell templates do not contain their release markers")
    if b"flowtrace_shell.js" not in resources["index.html"]:
        raise ValueError("index.html must boot through FlowTraceShell")
    bootstrap = resources["flutter_bootstrap.js"].decode("utf-8")
    # Flutter inlines its generic loader implementation, whose supported
    # parameter names include serviceWorkerSettings even when unused. Inspect
    # the actual global load invocation, rather than rejecting that definition.
    calls = re.findall(
        r"_flutter\s*\.\s*loader\s*\.\s*(?:load|loadEntrypoint)\s*\(([\s\S]*)\)\s*;?\s*\Z",
        bootstrap,
    )
    if any(re.search(r"\bserviceWorker(?:Settings)?\b", call) for call in calls):
        raise ValueError("Flutter loader must not register its default service worker")
    seed = json.dumps({name: digest(data) for name, data in resources.items()}, sort_keys=True)
    release_id = digest((str(SCHEMA) + seed + shell + worker).encode())
    resources["flowtrace_shell.js"] = shell.replace("__FLOWTRACE_RELEASE__", release_id).encode()
    manifest = {"schema": SCHEMA, "release_id": release_id, "resources": {
        name: {"sha256": digest(data), "bytes": len(data)} for name, data in resources.items()
    }}
    encoded = json.dumps(manifest, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
    (build / "flowtrace_shell.js").write_bytes(resources["flowtrace_shell.js"])
    # Replaces only this candidate build's generated worker at the same scope.
    # That pathname also upgrades an existing Flutter worker safely after all
    # old tabs close; legacy pages cannot approve the new hot-upgrade protocol.
    (build / "flutter_service_worker.js").write_text(
        worker.replace("__FLOWTRACE_MANIFEST__", encoded), encoding="utf-8", newline="\n"
    )
    (build / "flowtrace_service_worker.js").unlink(missing_ok=True)
    for name, data in resources.items():
        if (build / name).read_bytes() != data:
            raise ValueError(f"Build changed while sealing: {name}")
    (build / "flowtrace-release.json").write_text(encoded + "\n", encoding="utf-8", newline="\n")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path, help="New Flutter --output directory")
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[2] / "web")
    args = parser.parse_args()
    try:
        manifest = seal(args.build, args.source)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Release not sealed: {error}\n")
    print(json.dumps({"release_id": manifest["release_id"], "resources": len(manifest["resources"])}))


if __name__ == "__main__":
    main()
