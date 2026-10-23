"""Current-scope downloads, with authenticated image reads and no URL fetches."""

from uuid import UUID

from fastapi import APIRouter, Depends, Request, Response
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool

from flowtrace_server.attachments.service import attachment_for_read
from flowtrace_server.attachments.storage import AttachmentStore
from flowtrace_server.auth.dependencies import authenticated_request, get_session
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import assert_active_principal
from flowtrace_server.books.permissions import authorize_scope
from flowtrace_server.imports.router import strict_model
from flowtrace_server.sync.common import lock_scopes, run_transaction

from .schemas import ExportEnvelope, ExportRequest
from .service import export_document, json_bytes, xlsx_bytes

router = APIRouter(prefix="/api/v1/data-tools", tags=["data-tools"])
JSON_DOWNLOAD = {
    200: {
        "content": {
            "application/json": {"schema": {"$ref": "#/components/schemas/ExportEnvelope"}}
        },
        "description": "Current-authorized JSON export attachment",
    }
}
XLSX_DOWNLOAD = {
    200: {
        "content": {
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": {
                "schema": {"type": "string", "format": "binary"}
            }
        },
        "description": "Current-authorized XLSX export attachment",
    }
}


def download(content, media_type, filename):
    return Response(
        content,
        media_type=media_type,
        headers={
            "Content-Disposition": f'attachment; filename="{filename}"',
            "Cache-Control": "private, no-store",
            "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": "default-src 'none'; sandbox",
        },
    )


def make_xlsx(session, principal, body, directory):
    document = ExportEnvelope.model_validate(export_document(session, principal, body)).model_dump()
    if body.include_images != "embedded":
        return xlsx_bytes(document)
    store = AttachmentStore(directory / "attachments")

    def read():
        assert_active_principal(session, principal, lock=True)
        # Recheck the exact exported scopes and cut before reading any bytes.
        scopes = lock_scopes(session, {UUID(value) for value in document["scope_versions"]})
        for identifier, expected in document["scope_versions"].items():
            scope = scopes[UUID(identifier)]
            authorize_scope(session, principal, UUID(identifier))
            if (str(scope.revision), str(scope.permission_version)) != (
                expected["revision"],
                expected["permission_version"],
            ):
                raise ApiError("export_changed_retry", 409)

        def image_loader(item):
            record = attachment_for_read(session, principal, UUID(item["attachment_id"]))
            if (record.sha256, record.size_bytes, record.media_type) != (
                item["sha256"],
                item["size_bytes"],
                item["media_type"],
            ):
                raise ApiError("export_changed_retry", 409)
            try:
                return store.content(record.storage_key)
            except OSError:
                raise ApiError("attachment_storage_unavailable", 503) from None

        content = xlsx_bytes(document, image_loader=image_loader, embed_images=True)
        assert_active_principal(session, principal, lock=True)
        return content

    return run_transaction(session, read, repeatable=True)


@router.post(
    "/exports/json",
    response_model=ExportEnvelope,
    operation_id="data_export_json",
    responses=JSON_DOWNLOAD,
)
async def json_route(
    body: ExportRequest, request: Request, session: Session = Depends(get_session)
):
    principal = authenticated_request(session, request)
    validated = await strict_model(request, ExportRequest)
    if validated.include_images == "embedded":
        raise ApiError("json_embedded_images_not_supported", 422)
    document = await run_in_threadpool(export_document, session, principal, validated)
    validated_document = ExportEnvelope.model_validate(document)
    return download(
        json_bytes(validated_document.model_dump()), "application/json", "flowtrace-export.json"
    )


@router.post(
    "/exports/xlsx",
    response_class=Response,
    operation_id="data_export_xlsx",
    responses=XLSX_DOWNLOAD,
)
async def xlsx_route(
    body: ExportRequest, request: Request, session: Session = Depends(get_session)
):
    principal = authenticated_request(session, request)
    validated = await strict_model(request, ExportRequest)
    content = await run_in_threadpool(
        make_xlsx, session, principal, validated, request.app.state.settings.data_directory
    )
    return download(
        content,
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "flowtrace-export.xlsx",
    )
