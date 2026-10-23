import argparse
import json
from pathlib import Path

from flowtrace_server.config import Settings
from flowtrace_server.main import create_app


def main() -> None:
    parser = argparse.ArgumentParser(description="Export schemas from real routes only")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    app = create_app(Settings(_env_file=None, database_url=None))
    schema = app.openapi()
    schema["x-flowtrace-status"] = "implemented-routes"
    args.output.write_text(
        json.dumps(schema, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
