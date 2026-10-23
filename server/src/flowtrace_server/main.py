from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException
from starlette.middleware.cors import CORSMiddleware
from starlette.middleware.trustedhost import TrustedHostMiddleware
from starlette.staticfiles import StaticFiles

from flowtrace_server import __version__
from flowtrace_server.admin.router import router as admin_router
from flowtrace_server.api.errors import (
    ServiceUnavailable,
    http_handler,
    unavailable_handler,
    validation_handler,
)
from flowtrace_server.api.middleware import RequestContextMiddleware
from flowtrace_server.api.schemas import ErrorResponse, Health, ServerInfo
from flowtrace_server.assets.router import router as assets_router
from flowtrace_server.attachments.router import router as attachments_router
from flowtrace_server.auth.errors import ApiError, api_error_handler
from flowtrace_server.auth.router import router as auth_router
from flowtrace_server.books.router import router as books_router
from flowtrace_server.config import Settings
from flowtrace_server.currencies.router import router as currencies_router
from flowtrace_server.diagnostics import configure_logging, register_routes
from flowtrace_server.diagnostics.policy import build_diagnostic_policy
from flowtrace_server.exports.router import router as exports_router
from flowtrace_server.imports.router import router as imports_router
from flowtrace_server.imports.staging_router import router as import_stages_router
from flowtrace_server.persistence.database import build_engine, check_database
from flowtrace_server.reports.router import router as reports_router
from flowtrace_server.sync.group_router import router as group_sync_router
from flowtrace_server.sync.router import router as sync_router


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings()
    configure_logging(settings.log_level)
    diagnostic_policy = build_diagnostic_policy(settings)
    engine = build_engine(settings)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        try:
            yield
        finally:
            diagnostic_policy.close()
            if engine is not None:
                engine.dispose()

    app = FastAPI(
        title="FlowTrace API",
        version=__version__,
        lifespan=lifespan,
        responses={
            status: {"model": ErrorResponse}
            for status in (400, 401, 403, 404, 408, 409, 410, 413, 415, 422, 500, 503)
        },
    )
    app.state.settings = settings
    app.state.engine = engine
    app.state.diagnostic_policy = diagnostic_policy
    app.add_exception_handler(ServiceUnavailable, unavailable_handler)
    app.add_exception_handler(RequestValidationError, validation_handler)
    app.add_exception_handler(HTTPException, http_handler)
    app.add_exception_handler(ApiError, api_error_handler)
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=settings.allowed_hosts)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=True,
        allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE"],
        allow_headers=["Authorization", "Content-Type", "X-CSRF-Token", "X-Chunk-SHA256"],
        expose_headers=["X-Request-ID"],
    )
    app.add_middleware(RequestContextMiddleware)
    app.include_router(auth_router)
    app.include_router(books_router)
    app.include_router(attachments_router)
    app.include_router(sync_router)
    app.include_router(group_sync_router)
    app.include_router(reports_router)
    app.include_router(assets_router)
    app.include_router(currencies_router)
    app.include_router(imports_router)
    app.include_router(import_stages_router)
    app.include_router(exports_router)
    app.include_router(admin_router)
    app.mount(
        "/admin/static",
        StaticFiles(directory=str(Path(__file__).parent / "admin/static")),
        name="admin-static",
    )

    @app.get("/health/live", response_model=Health, operation_id="health_live")
    def live() -> Health:
        return Health()

    @app.get(
        "/health/ready",
        response_model=Health,
        operation_id="health_ready",
        responses={503: {"model": ErrorResponse}},
    )
    def ready(request: Request) -> Health:
        check_database(request.app.state.engine)
        return Health()

    @app.get(
        "/api/v1/server-info",
        response_model=ServerInfo,
        operation_id="server_info",
        responses={503: {"model": ErrorResponse}},
    )
    def server_info(request: Request) -> ServerInfo:
        instance_id, sync_epoch = check_database(request.app.state.engine)
        return ServerInfo(
            version=__version__,
            instance_id=instance_id,
            sync_epoch=sync_epoch,
            capabilities=[
                "health",
                "server-info",
                "identity",
                "books",
                "admin-minimal",
                "sync-v1",
                "group-sync-v1",
                "import-stages-v1",
                "attachments",
                "diagnostics",
                "reports-v1",
                "bill-move-v1",
                "assets-v1",
                "currencies-v1",
            ],
        )

    register_routes(app.routes)
    return app


app = create_app()
