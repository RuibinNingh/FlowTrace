"""Closed internal quarantine inputs; these values alone grant no authority."""

import hashlib
from typing import Annotated, Literal
from uuid import UUID

from pydantic import AwareDatetime, Field, model_validator

from flowtrace_server.imports.parsers import canonical

from .retention_schemas import MAX_PACKAGE_BYTES, MAX_PACKAGE_FILES, Closed, Hash, PackageStamp


class QuarantineSubmission(Closed):
    preview_id: UUID
    request_id: UUID
    selection_sha256: Hash


class QuarantinePlan(Closed):
    format: Literal["flowtrace-backup-quarantine-plan-v1"] = "flowtrace-backup-quarantine-plan-v1"
    intent_id: UUID
    job_id: UUID
    actor_id: UUID
    source_instance_id: UUID
    source_epoch: UUID
    config_version: Annotated[int, Field(strict=True, ge=0, le=2**63 - 1)]
    selection_sha256: Hash
    packages: Annotated[tuple[PackageStamp, ...], Field(min_length=1, max_length=20)]

    @model_validator(mode="after")
    def canonical_selection(self):
        identities = tuple(item.backup_id for item in self.packages)
        if len(set(identities)) != len(identities) or identities != tuple(
            sorted(identities, key=str)
        ):
            raise ValueError("backup_selection_order_invalid")
        if any(
            (item.instance_id, item.sync_epoch) != (self.source_instance_id, self.source_epoch)
            for item in self.packages
        ):
            raise ValueError("backup_source_changed")
        if (
            sum(item.size_bytes for item in self.packages) > MAX_PACKAGE_BYTES
            or sum(item.file_count for item in self.packages) > MAX_PACKAGE_FILES
        ):
            raise ValueError("backup_selection_too_large")
        actual = hashlib.sha256(
            canonical([item.model_dump(mode="json") for item in self.packages])
        ).hexdigest()
        if actual != self.selection_sha256:
            raise ValueError("backup_selection_changed")
        return self


class QuarantineReceipt(Closed):
    format: Literal["flowtrace-backup-quarantine-effect-v1"] = (
        "flowtrace-backup-quarantine-effect-v1"
    )
    intent_id: UUID
    job_id: UUID
    actor_id: UUID
    source_instance_id: UUID
    source_epoch: UUID
    config_version: Annotated[int, Field(strict=True, ge=0, le=2**63 - 1)]
    selection_sha256: Hash
    plan_sha256: Hash
    package: PackageStamp
    moved_at: AwareDatetime
