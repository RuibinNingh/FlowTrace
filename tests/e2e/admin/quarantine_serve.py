"""Owned temporary quarantine API, fixed loopback 18096, no automatic worker."""

import argparse
from pathlib import Path

import uvicorn
from flowtrace_server.main import create_app
from flowtrace_server.persistence.database import build_engine, check_database
from quarantine_fixture import load_fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    args = parser.parse_args()
    fixture, settings = load_fixture(args.fixture)
    engine = build_engine(settings)
    try:
        instance, epoch = check_database(engine)
        if (str(instance), str(epoch)) != (
            fixture["source_instance"],
            fixture["source_epoch"],
        ):
            raise ValueError("quarantine_source_changed")
    finally:
        engine.dispose()
    print("owned_quarantine_api_ready", flush=True)
    uvicorn.run(
        create_app(settings),
        host="127.0.0.1",
        port=18096,
        access_log=False,
        log_level="warning",
        reload=False,
        workers=1,
    )


if __name__ == "__main__":
    main()
