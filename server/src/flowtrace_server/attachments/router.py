import asyncio
import hashlib
from uuid import UUID

from fastapi import APIRouter, Depends, Request, Response
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool

from flowtrace_server.auth.dependencies import authenticated_request, get_session
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import assert_active_principal
from flowtrace_server.diagnostics import event
from flowtrace_server.diagnostics.store import DiagnosticStore
from flowtrace_server.persistence.private_files import private_unlink

from .schemas import AttachmentInfo, UploadDeclaration, UploadResult
from .service import (
    attachment_for_read,
    complete_record,
    declare_upload,
    upload_for_write,
    usable_upload,
)
from .storage import AttachmentStore

router = APIRouter(prefix="/api/v1/attachments", tags=["attachments"])


def store(request: Request) -> AttachmentStore:
    try:
        return AttachmentStore(request.app.state.settings.data_directory / "attachments")
    except OSError:
        raise ApiError("attachment_storage_unavailable", 503) from None


def metadata(record) -> dict:
    return {
        "attachment_id": record.id,
        "scope_id": record.scope_id,
        "sha256": record.sha256,
        "size_bytes": record.size_bytes,
        "media_type": record.media_type,
        "width": record.width,
        "height": record.height,
        "status": record.status,
    }


@router.post("/uploads", status_code=201, response_model=UploadResult)
def create_upload(
    body: UploadDeclaration, request: Request, session: Session = Depends(get_session)
):
    principal = authenticated_request(session, request)
    assert_active_principal(session, principal)
    try:
        record, replayed = declare_upload(session, principal, body, store(request))
    except OSError:
        raise ApiError("attachment_storage_unavailable", 503) from None
    session.commit()
    return {
        "upload_id": record.upload_id,
        "attachment_id": record.id,
        "status": record.status,
        "expires_at": record.upload_expires_at,
        "replayed": replayed,
    }


@router.put("/uploads/{upload_id}/content", response_model=UploadResult)
async def upload_content(
    upload_id: UUID, request: Request, session: Session = Depends(get_session)
):
    principal = authenticated_request(session, request)
    assert_active_principal(session, principal)
    record = upload_for_write(session, principal, upload_id)
    content_type = request.headers.get("content-type", "application/octet-stream").split(";", 1)[0]
    if content_type not in {record.media_type, "application/octet-stream"}:
        raise ApiError("image_format", 415)
    private = store(request)
    staged = None
    replayed = record.status in {"uploaded", "ready"}
    try:
        async with asyncio.timeout(60):
            staged = await private.receive(
                upload_id, request.stream(), record.size_bytes, record.sha256
            )
        usable_upload(record, upload_id)
        if record.status != "ready":
            info = await run_in_threadpool(
                private.publish, staged, record.storage_key, record.media_type
            )
            usable_upload(record, upload_id)
            record.status = "uploaded"
            record.width, record.height = info.width, info.height
        session.commit()
    except OSError:
        raise ApiError("attachment_storage_unavailable", 503) from None
    except TimeoutError:
        raise ApiError("upload_interrupted", 408) from None
    except ApiError as exc:
        if replayed and exc.code in {"hash_mismatch", "size_mismatch"}:
            raise ApiError("upload_mismatch", 409) from None
        raise
    finally:
        if staged is not None:
            try:
                private_unlink(staged, private.root)
            except OSError:
                DiagnosticStore.notice_failure()
    if not replayed:
        await run_in_threadpool(
            event, "attachment_staged", entity_id=str(record.id), size_bytes=record.size_bytes
        )
    return {
        "upload_id": record.upload_id,
        "attachment_id": record.id,
        "status": record.status,
        "expires_at": record.upload_expires_at,
        "replayed": replayed,
    }


@router.post("/uploads/{upload_id}/complete", response_model=AttachmentInfo)
def complete(upload_id: UUID, request: Request, session: Session = Depends(get_session)):
    principal = authenticated_request(session, request)
    assert_active_principal(session, principal)
    record = upload_for_write(session, principal, upload_id)
    if record.status not in {"uploaded", "ready"}:
        raise ApiError("attachment_not_ready", 409)
    replayed = record.status == "ready"
    try:
        info = store(request).verify(
            record.storage_key, record.size_bytes, record.sha256, record.media_type
        )
    except OSError:
        raise ApiError("attachment_storage_unavailable", 503) from None
    complete_record(session, principal, record, info.width, info.height)
    usable_upload(record, upload_id)
    session.commit()
    if not replayed:
        event("attachment_completed", entity_id=str(record.id))
    return metadata(record)


@router.get("/{attachment_id}", response_model=AttachmentInfo)
def read_metadata(attachment_id: UUID, request: Request, session: Session = Depends(get_session)):
    return metadata(
        attachment_for_read(session, authenticated_request(session, request), attachment_id)
    )


def download(attachment_id: UUID, request: Request, session: Session, *, thumbnail: bool):
    principal = authenticated_request(session, request)
    record = attachment_for_read(session, principal, attachment_id)
    try:
        content = store(request).content(record.storage_key, thumbnail=thumbnail)
    except OSError:
        raise ApiError("attachment_storage_unavailable", 503) from None
    if not thumbnail and hashlib.sha256(content).hexdigest() != record.sha256:
        raise ApiError("attachment_storage_unavailable", 503)
    media_type = "image/webp" if thumbnail else record.media_type
    suffix = {"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp"}[media_type]
    return Response(
        content,
        media_type=media_type,
        headers={
            "Content-Disposition": f'inline; filename="{attachment_id}.{suffix}"',
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "private,no-store",
            "Content-Security-Policy": "default-src 'none'; sandbox",
        },
    )


@router.get("/{attachment_id}/content", response_class=Response)
def original_content(
    attachment_id: UUID, request: Request, session: Session = Depends(get_session)
):
    return download(attachment_id, request, session, thumbnail=False)


@router.get("/{attachment_id}/thumbnail", response_class=Response)
def thumbnail_content(
    attachment_id: UUID, request: Request, session: Session = Depends(get_session)
):
    return download(attachment_id, request, session, thumbnail=True)
