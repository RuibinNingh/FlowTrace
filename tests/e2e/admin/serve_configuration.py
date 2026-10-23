"""Owned A06 loopback QA host with one fixed synthetic provider, never production."""

import argparse
import json
import secrets
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

import uvicorn
from dotenv import dotenv_values
from flowtrace_server.config import Settings
from flowtrace_server.main import create_app
from flowtrace_server.persistence.testing import require_isolated_database
from pydantic import SecretStr
from restore_fixture import load_restore_targets


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--backup-create", action="store_true")
    parser.add_argument("--restore-fixture", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    fixture_path = args.fixture.resolve()
    if not fixture_path.is_relative_to(root / "outputs/validation/P5/admin"):
        raise SystemExit("unexpected_fixture_location")
    fixture = json.loads(fixture_path.read_text(encoding="utf-8-sig"))
    if fixture.get("configuration_fixture") is not True:
        raise SystemExit("configuration_fixture_required")
    credential_path = Path(fixture["credentials_path"]).resolve()
    if not credential_path.is_relative_to(root / "work/flowtrace-dev"):
        raise SystemExit("unexpected_credential_location")
    credentials = json.loads(credential_path.read_text(encoding="utf-8-sig"))
    values = dotenv_values(fixture["env_file"])
    url = values["FLOWTRACE_TEST_DATABASE_URL"]
    parsed = require_isolated_database(url, values["FLOWTRACE_ENVIRONMENT"])
    if not parsed.database.startswith("flowtrace_test_p5_admin_"):
        raise SystemExit("admin_fixture_database_required")
    events = fixture_path.parent / "configuration-provider-events.jsonl"

    class Provider(BaseHTTPRequestHandler):
        def do_GET(self):
            route = self.path == "/v1/models"
            authorized = secrets.compare_digest(
                self.headers.get("Authorization", ""),
                "Bearer " + credentials["configuration_ai_secret"],
            )
            status = 200 if route and authorized else 403
            with events.open("a", encoding="utf-8") as stream:
                stream.write(
                    json.dumps(
                        {
                            "fixed_models_path": route,
                            "authorized": authorized,
                            "status": status,
                        }
                    )
                    + "\n"
                )
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"{}")

        def log_message(self, *args):
            return

    provider = ThreadingHTTPServer(("127.0.0.1", 18088), Provider)
    Thread(target=provider.serve_forever, daemon=True).start()
    settings = Settings(
        _env_file=fixture["env_file"],
        database_url=url,
        environment="test",
        data_directory=Path(values["FLOWTRACE_DATA_DIRECTORY"]),
        provider_endpoints={"ai_primary": SecretStr("http://127.0.0.1:18088/v1")},
        pg_dump_executable=(
            root / "work/flowtrace-dev/postgresql/pgsql/bin/pg_dump.exe"
        )
        if args.backup_create
        else None,
        restore_targets=load_restore_targets(args.restore_fixture)
        if args.restore_fixture
        else {},
    )
    try:
        uvicorn.run(
            create_app(settings),
            host="127.0.0.1",
            port=18087,
            access_log=False,
            log_level="warning",
        )
    finally:
        provider.shutdown()
        provider.server_close()


if __name__ == "__main__":
    main()
