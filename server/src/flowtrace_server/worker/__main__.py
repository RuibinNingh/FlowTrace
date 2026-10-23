"""python -m flowtrace_server.worker [--once]"""

import argparse
import signal
import threading

from sqlalchemy.orm import Session

from flowtrace_server.config import Settings
from flowtrace_server.configuration.runtime import read_runtime_configuration
from flowtrace_server.persistence.database import build_engine, check_database

from .runtime import Worker


def main():
    parser = argparse.ArgumentParser(description="FlowTrace independent fixed-kind worker")
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--poll-seconds", type=float, default=None)
    args = parser.parse_args()
    if args.poll_seconds is not None and not 0.25 <= args.poll_seconds <= 60:
        parser.error("poll-seconds must be between 0.25 and 60")
    settings = Settings()
    engine = build_engine(settings)
    if engine is None:
        parser.exit(1, "database_unconfigured\n")
    stopped = threading.Event()
    for name in ("SIGINT", "SIGTERM"):
        if hasattr(signal, name):
            signal.signal(getattr(signal, name), lambda *_: stopped.set())
    worker = None
    try:
        try:
            check_database(engine)
        except Exception:
            parser.exit(1, "worker_database_unavailable\n")
        worker = Worker(engine, settings)
        while not stopped.is_set():
            poll_seconds = args.poll_seconds
            try:
                if poll_seconds is None:
                    with Session(engine) as session:
                        poll_seconds = read_runtime_configuration(
                            session
                        ).values.worker_poll_seconds
                worker.run_once()
            except Exception:
                if args.once:
                    parser.exit(1, "worker_iteration_unavailable\n")
            if args.once:
                break
            stopped.wait(poll_seconds if poll_seconds is not None else 2)
    finally:
        if worker is not None:
            worker.close()
        engine.dispose()


if __name__ == "__main__":
    main()
