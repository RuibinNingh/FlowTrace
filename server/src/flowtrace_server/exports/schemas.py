from typing import Literal

from pydantic import Field, model_validator

from flowtrace_server.imports.http_schemas import Digest
from flowtrace_server.imports.schemas import HistoricalPosting, ImportRow
from flowtrace_server.sync.schemas import BusinessDate, ClosedModel, Identifier, Revision


class ExportRequest(ClosedModel):
    scope_ids: list[Identifier] = Field(min_length=1, max_length=50)
    date_from: BusinessDate | None = None
    date_to: BusinessDate | None = None
    order: Literal["date_asc", "date_desc"] = "date_asc"
    include_configuration: bool = True
    include_images: Literal["links", "embedded"] = "links"

    @model_validator(mode="after")
    def valid(self):
        from flowtrace_server.domain.calendar_rules import business_date

        for value in (self.date_from, self.date_to):
            if value:
                business_date(value)
        if self.date_from and self.date_to and self.date_from > self.date_to:
            raise ValueError("invalid_date_range")
        if len(self.scope_ids) != len(set(self.scope_ids)):
            raise ValueError("duplicate_scope")
        return self


class ExportDocument(ClosedModel):
    format: Literal["flowtrace-data-v1"]
    source_namespace: str = Field(min_length=1, max_length=80)
    rows: list[ImportRow] = Field(max_length=1000)
    posting_hints: dict[Identifier, HistoricalPosting] = Field(
        default_factory=dict, max_length=1000
    )


class ExportAttachment(ClosedModel):
    attachment_id: Identifier
    sha256: Digest
    size_bytes: int = Field(ge=1, le=10 * 1024 * 1024)
    media_type: Literal["image/jpeg", "image/png", "image/webp"]
    href: str = Field(pattern=r"^/api/v1/attachments/[0-9a-f-]{36}/content$")
    authorization: Literal["current_session_and_scope_required"]


class ExportScopeVersion(ClosedModel):
    revision: Revision
    permission_version: Revision


class ExportEnvelope(ClosedModel):
    format: Literal["flowtrace-export-v1"]
    document: ExportDocument
    attachments: list[ExportAttachment] = Field(max_length=20000)
    scope_versions: dict[Identifier, ExportScopeVersion]
    filter: ExportRequest
