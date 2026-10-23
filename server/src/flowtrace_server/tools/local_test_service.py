"""Explicit local-test entry: ordinary API/admin and a verified fixed Web release.

This module never installs packages, registers tasks, or initializes a cluster.
Its provision command is an explicit final-install step against an already new,
owned loopback cluster. Configuration and credentials remain outside static Web.
"""

import argparse
import hashlib
import json
import logging
import mimetypes
import os
import re
import threading
from contextlib import contextmanager
from datetime import UTC, datetime
from logging.handlers import RotatingFileHandler
from pathlib import Path, PurePosixPath
from time import monotonic
from uuid import UUID

from starlette.responses import JSONResponse, Response

from flowtrace_server.config import Settings
from flowtrace_server.persistence.private_files import (
    prepare_file,
    private_directory,
    private_open,
    regular_file,
)

MAX_RESOURCE = 128 * 1024 * 1024
MAX_RELEASE = 512 * 1024 * 1024
HASH = re.compile(r"[0-9a-f]{64}\Z")
RESERVED = {"api", "admin", "auth", "health"}


class ExplicitLocalSettings(Settings):
    @classmethod
    def settings_customise_sources(
        cls, settings_cls, init_settings, env_settings, dotenv_settings, file_secret_settings
    ):
        # This OS-owned entry uses exactly its private JSON. In particular an
        # explicit empty mapping must not deep-merge an inherited provider map.
        return (init_settings,)


def plain_path(value):
    path = Path(os.path.abspath(value))
    for item in (path, *path.parents):
        if item.is_symlink() or item.is_junction():
            raise ValueError("local_test_linked_path")
    return path


def resource_name(value):
    if not isinstance(value, str) or not value or any(char in value for char in "\\%?#:"):
        raise ValueError("web_resource_path_invalid")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in value.split("/")):
        raise ValueError("web_resource_path_invalid")
    if value.split("/", 1)[0] in RESERVED:
        raise ValueError("web_business_route_reserved")
    return value


def verified_web(directory, *, expected_release_id=None):
    root = plain_path(directory)
    manifest_path = root / "flowtrace-release.json"
    with private_open(manifest_path, root) as source:
        raw = source.read(5 * 1024 * 1024 + 1)
    if len(raw) > 5 * 1024 * 1024:
        raise ValueError("web_manifest_too_large")
    manifest = json.loads(raw)
    if (
        set(manifest) != {"schema", "release_id", "resources"}
        or manifest["schema"] != 1
        or not HASH.fullmatch(manifest["release_id"])
        or not isinstance(manifest["resources"], dict)
        or not 1 <= len(manifest["resources"]) <= 100000
        or (expected_release_id is not None and expected_release_id != manifest["release_id"])
    ):
        raise ValueError("web_manifest_invalid")
    required = {
        "index.html",
        "main.dart.js",
        "sqlite3.wasm",
        "drift_worker.js",
        "flowtrace_shell.js",
        "flutter_bootstrap.js",
    }
    if not required.issubset(manifest["resources"]):
        raise ValueError("web_resource_missing")
    files, total = {}, 0
    for name, metadata in manifest["resources"].items():
        resource_name(name)
        if (
            set(metadata) != {"sha256", "bytes"}
            or not isinstance(metadata["sha256"], str)
            or not HASH.fullmatch(metadata["sha256"])
            or type(metadata["bytes"]) is not int
            or not 0 <= metadata["bytes"] <= MAX_RESOURCE
        ):
            raise ValueError("web_resource_metadata_invalid")
        total += metadata["bytes"]
        if total > MAX_RELEASE:
            raise ValueError("web_release_too_large")
        files[name] = metadata
    with private_open(root / "flutter_service_worker.js", root) as source:
        worker = source.read(5 * 1024 * 1024 + 1)
    embedded = re.search(rb"const RELEASE = (\{[^\n]*\});", worker)
    if not embedded or json.loads(embedded.group(1)) != manifest:
        raise ValueError("web_worker_manifest_mismatch")
    files["flowtrace-release.json"] = {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
    files["flutter_service_worker.js"] = {
        "bytes": len(worker),
        "sha256": hashlib.sha256(worker).hexdigest(),
    }
    for name in files:
        read_resource(root, name, files[name])
    return root, manifest["release_id"], files


def read_resource(root, name, metadata):
    with private_open(root / name, root) as source:
        content = source.read(min(MAX_RESOURCE, metadata["bytes"]) + 1)
    if (
        len(content) != metadata["bytes"]
        or hashlib.sha256(content).hexdigest() != metadata["sha256"]
    ):
        raise ValueError("web_resource_integrity_failed")
    return content


class SealedWeb:
    def __init__(self, directory, expected_release_id=None):
        self.root, self.release_id, self.files = verified_web(
            directory, expected_release_id=expected_release_id
        )

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await send({"type": "websocket.close", "code": 1000})
            return
        path = scope["path"].lstrip("/") or "index.html"
        if path not in self.files or path.split("/", 1)[0] in RESERVED:
            response = JSONResponse({"error": {"code": "not_found"}}, status_code=404)
        elif scope["method"] not in {"GET", "HEAD"}:
            response = Response(status_code=405, headers={"Allow": "GET, HEAD"})
        else:
            try:
                content = read_resource(self.root, path, self.files[path])
                media_type = {
                    ".wasm": "application/wasm",
                    ".js": "application/javascript",
                    ".json": "application/json",
                    ".html": "text/html",
                }.get(
                    Path(path).suffix.lower(),
                    mimetypes.guess_type(path)[0] or "application/octet-stream",
                )
                headers = {"Content-Length": str(len(content))}
                if path == "flutter_service_worker.js":
                    headers["Service-Worker-Allowed"] = "/"
                response = Response(
                    b"" if scope["method"] == "HEAD" else content,
                    media_type=media_type,
                    headers=headers,
                )
            except (OSError, ValueError):
                response = JSONResponse(
                    {"error": {"code": "web_resource_unavailable"}}, status_code=503
                )
        await response(scope, receive, send)


class LocalHeaders:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        async def protected(message):
            if message["type"] == "http.response.start":
                fixed = {
                    b"cross-origin-opener-policy": b"same-origin",
                    b"cross-origin-embedder-policy": b"require-corp",
                    b"x-content-type-options": b"nosniff",
                    b"referrer-policy": b"no-referrer",
                    b"cache-control": b"no-store",
                }
                headers = [
                    (key, value)
                    for key, value in message.get("headers", [])
                    if key.lower() not in fixed
                ]
                message["headers"] = headers + list(fixed.items())
            await send(message)

        await self.app(scope, receive, protected)


def create_local_test_app(settings: Settings, web_directory: Path, *, expected_release_id=None):
    # Validate the immutable candidate before constructing any listening server.
    static = SealedWeb(web_directory, expected_release_id)
    from flowtrace_server.main import create_app

    app = create_app(settings)
    app.add_middleware(LocalHeaders)
    app.mount("/", static, name="sealed-local-test-web")
    return app


def load_configuration(path):
    path = plain_path(path)
    if path.stat().st_size > 65536:
        raise ValueError("local_test_configuration_invalid")
    config = json.loads(path.read_bytes())
    if config.get("format") != "flowtrace-local-test-service-v1":
        raise ValueError("local_test_configuration_invalid")
    root = plain_path(config["root"])
    if path != root / "private" / "service.json" or config["host"] != "127.0.0.1":
        raise ValueError("local_test_configuration_invalid")
    owner = json.loads((root / "service-owner.json").read_bytes())
    if (
        str(UUID(config["service_id"])) != config["service_id"]
        or owner["service_id"] != config["service_id"]
    ):
        raise ValueError("local_test_identity_mismatch")
    version_directory = plain_path(config["version_directory"])
    if version_directory.parent != root / "versions":
        raise ValueError("local_test_version_boundary")
    # Supply every field explicitly so inherited environment cannot fill a
    # missing setting. Reading configuration has no process-global side effect.
    settings = ExplicitLocalSettings(_env_file=None, **config["settings"])
    if settings.environment != "test" or plain_path(settings.data_directory) != root / "data":
        raise ValueError("local_test_settings_boundary")
    from sqlalchemy.engine import make_url

    url = make_url(settings.database_url.get_secret_value())
    short_id = config["service_id"].replace("-", "")[:16]
    if (
        url.host != "127.0.0.1"
        or url.query
        or type(config["database_port"]) is not int
        or not 1024 <= config["database_port"] <= 65535
        or type(config["http_port"]) is not int
        or not 1024 <= config["http_port"] <= 65535
        or url.port != config["database_port"]
        or url.port == 55432
        or config["http_port"] == 18080
        or config["http_port"] == url.port
        or url.database != config["postgresql"]["database"]
        or url.database != f"flowtrace_local_{short_id}"
        or url.username != config["postgresql"]["role"]
        or url.username != f"flowtrace_service_{short_id}"
        or plain_path(settings.pg_dump_executable)
        != version_directory / "postgresql" / "bin" / "pg_dump.exe"
    ):
        raise ValueError("local_test_database_boundary")
    return config, settings


class RuntimeFormatter(logging.Formatter):
    def format(self, record):
        # Uvicorn may attach raw exception text or request details. Keep this
        # private operational stream bounded and fixed-field like diagnostics.
        return json.dumps(
            {
                "timestamp": datetime.fromtimestamp(record.created, UTC).isoformat(),
                "level": record.levelname
                if record.levelname in {"INFO", "WARNING", "ERROR"}
                else "INFO",
                "event": "local_test_service_runtime",
            }
        )


@contextmanager
def runtime_lease(root, mode):
    import portalocker

    if mode not in {"serve", "worker", "backup", "provision"}:
        raise ValueError("local_test_mode_invalid")
    directory = private_directory(Path(root) / "private")
    path = directory / f"{mode}.lease"
    prepare_file(path, directory)
    with private_open(path, directory, append=True) as stream:
        portalocker.lock(stream, portalocker.LOCK_EX | portalocker.LOCK_NB)
        try:
            yield
        finally:
            portalocker.unlock(stream)


def configure_private_logs(root, mode):
    directory = private_directory(Path(root) / "data" / "service-logs")
    for suffix in ("", ".1", ".2", ".3"):
        path = directory / f"{mode}.log{suffix}"
        if path.exists() or path.is_symlink() or path.is_junction():
            regular_file(path, directory)
    handler = RotatingFileHandler(
        directory / f"{mode}.log", maxBytes=2 * 1024 * 1024, backupCount=3
    )
    handler.setFormatter(RuntimeFormatter())
    for name in ("uvicorn", "uvicorn.error"):
        logger = logging.getLogger(name)
        logger.handlers = [handler]
        logger.propagate = False


def run_worker(config, settings):
    from sqlalchemy.orm import Session

    from flowtrace_server.configuration.runtime import read_runtime_configuration
    from flowtrace_server.persistence.database import build_engine, check_database
    from flowtrace_server.worker.runtime import Worker

    engine = build_engine(settings)
    stop_file = Path(config["root"]) / "private" / "worker.stop"
    worker = None
    try:
        check_database(engine)
        worker = Worker(engine, settings)
        while not stop_file.exists():
            try:
                worker.run_once()
                with Session(engine) as session:
                    delay = read_runtime_configuration(session).values.worker_poll_seconds
            except Exception:
                delay = 2
            until = monotonic() + delay
            while not stop_file.exists() and monotonic() < until:
                threading.Event().wait(min(0.25, max(0, until - monotonic())))
    finally:
        if worker is not None:
            worker.close()
        engine.dispose()


def provision(config, settings):
    import psycopg
    from alembic import command
    from psycopg import sql
    from sqlalchemy.orm import Session

    from flowtrace_server.admin.service import bootstrap_admin
    from flowtrace_server.persistence.database import build_engine, check_database, migration_config

    pg = config["postgresql"]
    if not all(
        re.fullmatch(r"[a-z][a-z0-9_]{2,62}", pg[key])
        for key in ("administrator", "role", "database")
    ):
        raise ValueError("local_test_database_identity_invalid")
    with psycopg.connect(
        host="127.0.0.1",
        port=config["database_port"],
        dbname="postgres",
        user=pg["administrator"],
        password=pg["admin_password"],
        autocommit=True,
    ) as connection:
        if connection.execute("SELECT 1 FROM pg_roles WHERE rolname=%s", (pg["role"],)).fetchone():
            raise ValueError("local_test_role_already_exists")
        connection.execute(
            sql.SQL("CREATE ROLE {} LOGIN PASSWORD {}").format(
                sql.Identifier(pg["role"]), sql.Literal(pg["role_password"])
            )
        )
        connection.execute(
            sql.SQL("CREATE DATABASE {} OWNER {}").format(
                sql.Identifier(pg["database"]), sql.Identifier(pg["role"])
            )
        )
    engine = build_engine(settings)
    try:
        with engine.begin() as connection:
            migration = migration_config()
            migration.attributes["connection"] = connection
            command.upgrade(migration, "head")
        instance, epoch = check_database(engine)
        with Session(engine) as session, session.begin():
            bootstrap_admin(
                session, config["initial_admin"]["username"], config["initial_admin"]["password"]
            )
        (Path(config["root"]) / "private" / "server-identity.json").write_text(
            json.dumps({"instance_id": str(instance), "sync_epoch": str(epoch)}), encoding="utf-8"
        )
    finally:
        engine.dispose()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--service-id", required=True)
    parser.add_argument("--mode", choices=["serve", "worker", "backup", "provision"], required=True)
    args = parser.parse_args()
    try:
        config, settings = load_configuration(args.config)
        if args.service_id != config["service_id"]:
            raise ValueError("local_test_identity_mismatch")
        for key in list(os.environ):
            if key.startswith(("FLOWTRACE_", "PG")):
                del os.environ[key]
        for key, value in config["settings"].items():
            os.environ["FLOWTRACE_" + key.upper()] = (
                json.dumps(value) if isinstance(value, (list, dict, bool)) else str(value)
            )
        with runtime_lease(config["root"], args.mode):
            execute_mode(config, settings, args.mode)
    except Exception:
        parser.exit(1, "local_test_service_failed: inspect private service state\n")


def execute_mode(config, settings, mode):
    configure_private_logs(config["root"], mode)
    if mode == "serve":
        import uvicorn

        app = create_local_test_app(
            settings,
            Path(config["version_directory"]) / "web",
            expected_release_id=config["web_release_id"],
        )
        server = uvicorn.Server(
            uvicorn.Config(
                app,
                host=config["host"],
                port=config["http_port"],
                access_log=False,
                log_config=None,
            )
        )
        stop_file = Path(config["root"]) / "private" / "serve.stop"

        def watch_stop():
            while not server.should_exit:
                if stop_file.exists():
                    server.should_exit = True
                    return
                threading.Event().wait(0.25)

        threading.Thread(target=watch_stop, daemon=True).start()
        server.run()
    elif mode == "worker":
        run_worker(config, settings)
    elif mode == "backup":
        from flowtrace_server.backups.service import create_backup

        result = create_backup(
            settings,
            Path(config["root"]) / "data" / "backups",
            pg_dump=settings.pg_dump_executable,
        )
        print(json.dumps(result))
    else:
        provision(config, settings)
        print("local_test_database_provisioned")


if __name__ == "__main__":
    main()
