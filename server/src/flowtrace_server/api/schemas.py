from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ErrorDetail(StrictModel):
    code: str
    message: str
    request_id: str
    details: dict = {}


class ErrorResponse(StrictModel):
    error: ErrorDetail


class Health(StrictModel):
    status: Literal["ok"] = "ok"


class ServerInfo(StrictModel):
    name: str = "FlowTrace"
    version: str
    instance_id: UUID
    sync_epoch: UUID
    minimum_protocol: int = 1
    capabilities: list[str]
