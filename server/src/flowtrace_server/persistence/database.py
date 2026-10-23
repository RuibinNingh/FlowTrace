from pathlib import Path
from uuid import UUID

from alembic.config import Config
from alembic.migration import MigrationContext
from alembic.script import ScriptDirectory
from sqlalchemy import Engine, create_engine, select, text
from sqlalchemy.exc import SQLAlchemyError

from flowtrace_server.api.errors import ServiceUnavailable
from flowtrace_server.config import Settings
from flowtrace_server.diagnostics import event
from flowtrace_server.persistence.maintenance import install_transaction_fence
from flowtrace_server.persistence.models import ServerState


def migration_directory() -> Path:
    packaged = Path(__file__).resolve().parents[1] / "migrations"
    return packaged if packaged.is_dir() else Path(__file__).resolve().parents[3] / "migrations"


def migration_config() -> Config:
    config = Config()
    config.set_main_option("script_location", str(migration_directory()))
    return config


def build_engine(settings: Settings) -> Engine | None:
    if settings.database_url is None:
        return None
    engine = create_engine(
        settings.database_url.get_secret_value(),
        pool_pre_ping=True,
        hide_parameters=True,
        connect_args={"connect_timeout": settings.database_connect_timeout},
        pool_size=5,
        max_overflow=5,
        pool_timeout=5,
    )
    install_transaction_fence(engine)
    return engine


def check_database(engine: Engine | None) -> tuple[UUID, UUID]:
    if engine is None:
        raise ServiceUnavailable
    try:
        heads = set(ScriptDirectory.from_config(migration_config()).get_heads())
        with engine.connect() as connection:
            connection.execute(text("SELECT 1"))
            actual = set(MigrationContext.configure(connection).get_current_heads())
            if actual != heads or not heads:
                event("readiness_failed", code="migration_mismatch")
                raise ServiceUnavailable
            state = connection.execute(
                select(ServerState.instance_id, ServerState.sync_epoch)
            ).one()
            return state.instance_id, state.sync_epoch
    except SQLAlchemyError:
        event("readiness_failed", code="database_unavailable")
        raise ServiceUnavailable from None
