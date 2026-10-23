from alembic import context

from flowtrace_server.config import Settings
from flowtrace_server.persistence.database import build_engine
from flowtrace_server.persistence.registry import Base

target_metadata = Base.metadata


def offline() -> None:
    context.configure(
        dialect_name="postgresql",
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )
    with context.begin_transaction():
        context.run_migrations()


def online() -> None:
    supplied = context.config.attributes.get("connection")
    engine = None
    if supplied is None:
        engine = build_engine(Settings())
        if engine is None:
            raise RuntimeError("FLOWTRACE_DATABASE_URL_required")
        supplied = engine.connect()
    try:
        context.configure(connection=supplied, target_metadata=target_metadata, compare_type=True)
        with context.begin_transaction():
            context.run_migrations()
    finally:
        if engine is not None:
            supplied.close()
            engine.dispose()


offline() if context.is_offline_mode() else online()
