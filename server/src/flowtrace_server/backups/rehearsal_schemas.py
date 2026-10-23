"""Closed private records and public metadata for isolated restore rehearsals."""

from typing import Annotated, Literal
from uuid import UUID

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, model_validator

Hash = Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]
Version = Annotated[int, Field(ge=0, le=2**63 - 1)]


class ClosedRecord(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True, hide_input_in_errors=True)


class RestoreRehearsalPayload(ClosedRecord):
    target_id: UUID
    backup_id: UUID
    preview_id: UUID
    manifest_sha256: Hash
    target_fingerprint: Hash
    config_version: Version


class RestorePreviewRecord(ClosedRecord):
    format: Literal["flowtrace-restore-preview-v1"] = "flowtrace-restore-preview-v1"
    preview_id: UUID
    actor_id: UUID
    session_id: UUID
    target_id: UUID
    backup_id: UUID
    source_epoch: UUID
    config_version: Version
    manifest_sha256: Hash
    target_fingerprint: Hash
    empty_fingerprint: Hash
    target_identity: Hash
    issued_at: AwareDatetime
    expires_at: AwareDatetime

    @model_validator(mode="after")
    def bounded_lifetime(self):
        if not 0 < (self.expires_at - self.issued_at).total_seconds() <= 300:
            raise ValueError("restore_preview_lifetime_invalid")
        return self


class RestorePreview(ClosedRecord):
    preview_id: UUID
    target_id: UUID
    target_label: str
    backup_id: UUID
    config_version: Version
    expires_at: AwareDatetime
    target_empty: Literal[True] = True
    sessions_will_be_revoked: Literal[True] = True
    epoch_will_change: Literal[True] = True
    private_secrets_must_be_provisioned_separately: Literal[True] = True


class RestoreVerifiedReceipt(ClosedRecord):
    format: Literal["flowtrace-restore-verified-v1"] = "flowtrace-restore-verified-v1"
    job_id: UUID
    owner_user_id: UUID
    preview_id: UUID
    target_id: UUID
    backup_id: UUID
    config_version: Version
    manifest_sha256: Hash
    target_fingerprint: Hash
    target_identity: Hash
    restored_epoch: UUID
    restored_instance: UUID
    database_summary_sha256: Hash
    object_summary_sha256: Hash
    object_count: Annotated[int, Field(ge=0, le=100000)]
    verified_at: AwareDatetime
