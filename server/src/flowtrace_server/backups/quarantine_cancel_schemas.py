"""Closed per-job command for cancellation before the first lease."""

from typing import Annotated
from uuid import UUID

from pydantic import Field

from .retention_schemas import Closed, Hash


class UnclaimedQuarantineCancellation(Closed):
    job_id: UUID
    intent_id: UUID
    selection_sha256: Hash
    request_id: UUID
    expected_generation: Annotated[int, Field(strict=True, ge=0, le=0)] = 0
