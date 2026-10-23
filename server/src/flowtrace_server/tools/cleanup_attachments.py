import argparse
import json

from flowtrace_server.attachments.gc import collect
from flowtrace_server.attachments.storage import AttachmentStore
from flowtrace_server.config import Settings
from flowtrace_server.diagnostics import configure_logging
from flowtrace_server.diagnostics.policy import bind_diagnostics, build_diagnostic_policy
from flowtrace_server.persistence.database import build_engine, check_database


def main():
    parser = argparse.ArgumentParser(
        description="Collect confirmed unreferenced private attachments"
    )
    parser.add_argument("--limit", type=int, default=100)
    args = parser.parse_args()
    settings = Settings()
    configure_logging(settings.log_level)
    policy = build_diagnostic_policy(settings)
    engine = build_engine(settings)
    try:
        check_database(engine)
        with bind_diagnostics(policy):
            result = collect(
                engine, AttachmentStore(settings.data_directory / "attachments"), args.limit
            )
        print(json.dumps(result, separators=(",", ":")))
    except Exception:
        raise SystemExit("attachment_cleanup_failed") from None
    finally:
        policy.close()
        if engine is not None:
            engine.dispose()


if __name__ == "__main__":
    main()
