from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import Field

from flowtrace_server.api.schemas import StrictModel


class UploadDeclaration(StrictModel):
    attachment_id: UUID
    scope_id: UUID
    sha256: str = Field(pattern="^[a-f0-9]{64}$")
    size_bytes: int = Field(ge=1, le=10 * 1024 * 1024, strict=True)
    media_type: Literal["image/jpeg", "image/png", "image/webp"]


class UploadResult(StrictModel):
    upload_id: UUID
    attachment_id: UUID
    status: Literal["pending", "uploaded", "ready"]
    expires_at: datetime
    replayed: bool


class AttachmentInfo(StrictModel):
    attachment_id: UUID
    scope_id: UUID
    sha256: str
    size_bytes: int
    media_type: Literal["image/jpeg", "image/png", "image/webp"]
    width: int
    height: int
    status: Literal["ready"]
