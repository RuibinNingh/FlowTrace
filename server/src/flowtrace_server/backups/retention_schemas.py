"""Closed commands and metadata for future protected backup maintenance.

These DTOs do not authorize a file effect. UUIDs and immutable package stamps
cross the boundary; paths, connection strings, commands and free text do not.
"""

from typing import Annotated, Literal
from uuid import UUID

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, model_validator

MAX_PACKAGE_BYTES = 1078984704  # 1GiB package data plus a 5MiB manifest.
MAX_PACKAGE_FILES = 100002
MAX_SELECTION = 20
Version = Annotated[int, Field(strict=True, ge=1, le=2**63 - 1)]
ConfigVersion = Annotated[int, Field(strict=True, ge=0, le=2**63 - 1)]
Hash = Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]
PackageState = Literal["available", "reserved", "quarantined", "partial", "destroyed"]
HolderKind = Literal["job", "download", "restore_intent"]
ReleaseProof = Literal["archive_built", "job_terminal_verified", "explicit_reconcile"]
ProtectionReason = Literal[
    "unregistered",
    "pinned",
    "active_hold",
    "active_job",
    "restore_intent",
    "last_recovery_point",
    "not_old",
    "package_unavailable",
    "partial",
    "reserved",
    "quarantined",
    "destroyed",
]


class Closed(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True, hide_input_in_errors=True)


class RetentionSelection(Closed):
    backup_ids: Annotated[tuple[UUID, ...], Field(min_length=1, max_length=MAX_SELECTION)]
    request_id: UUID
    expected_config_version: ConfigVersion

    @model_validator(mode="after")
    def canonical_unique(self):
        if len(set(self.backup_ids)) != len(self.backup_ids):
            raise ValueError("backup_selection_duplicate")
        if self.backup_ids != tuple(sorted(self.backup_ids, key=str)):
            raise ValueError("backup_selection_order_invalid")
        return self


class PinCreateCommand(Closed):
    pin_id: UUID
    backup_id: UUID
    expected_control_version: Version
    request_id: UUID


class PinReleaseCommand(Closed):
    pin_id: UUID
    expected_pin_version: Version
    expected_control_version: Version
    request_id: UUID


class HoldCreateCommand(Closed):
    hold_id: UUID
    backup_id: UUID
    expected_control_version: Version
    holder_kind: HolderKind
    holder_id: UUID
    job_id: UUID | None = None

    @model_validator(mode="after")
    def holder_binding(self):
        if self.holder_kind in {"job", "restore_intent"}:
            if self.job_id != self.holder_id:
                raise ValueError("backup_hold_job_binding_invalid")
        elif self.job_id is not None:
            raise ValueError("backup_hold_job_binding_invalid")
        return self


class HoldReleaseCommand(Closed):
    hold_id: UUID
    expected_hold_version: Version
    expected_control_version: Version
    proof: ReleaseProof


class PackageStamp(Closed):
    backup_id: UUID
    control_version: Version
    manifest_sha256: Hash
    tree_sha256: Hash
    size_bytes: Annotated[int, Field(strict=True, ge=1, le=MAX_PACKAGE_BYTES)]
    file_count: Annotated[int, Field(strict=True, ge=3, le=MAX_PACKAGE_FILES)]
    created_at: AwareDatetime
    instance_id: UUID
    sync_epoch: UUID


class RetentionPreviewRecord(Closed):
    format: Literal["flowtrace-backup-retention-preview-v1"] = (
        "flowtrace-backup-retention-preview-v1"
    )
    preview_id: UUID
    actor_id: UUID
    session_id: UUID
    request_id: UUID
    config_version: ConfigVersion
    source_instance_id: UUID
    source_epoch: UUID
    retention_days: Annotated[int, Field(strict=True, ge=1, le=3650)]
    cutoff: AwareDatetime
    packages: Annotated[tuple[PackageStamp, ...], Field(min_length=1, max_length=MAX_SELECTION)]
    selection_sha256: Hash
    issued_at: AwareDatetime
    expires_at: AwareDatetime

    @model_validator(mode="after")
    def bounded_selection(self):
        identities = tuple(item.backup_id for item in self.packages)
        if len(set(identities)) != len(identities) or identities != tuple(
            sorted(identities, key=str)
        ):
            raise ValueError("backup_selection_order_invalid")
        if sum(item.size_bytes for item in self.packages) > MAX_PACKAGE_BYTES:
            raise ValueError("backup_selection_too_large")
        if sum(item.file_count for item in self.packages) > MAX_PACKAGE_FILES:
            raise ValueError("backup_selection_too_many_files")
        if not 0 < (self.expires_at - self.issued_at).total_seconds() <= 300:
            raise ValueError("backup_preview_lifetime_invalid")
        if any(item.created_at >= self.cutoff for item in self.packages):
            raise ValueError("backup_package_not_old")
        return self


class QuarantinePayload(Closed):
    intent_id: UUID
    selection_sha256: Hash


class BackupCandidate(Closed):
    backup_id: UUID
    state: PackageState | Literal["unregistered"]
    eligible: bool
    protection_reasons: tuple[ProtectionReason, ...]
    created_at: AwareDatetime | None = None
    size_bytes: Annotated[int, Field(strict=True, ge=0, le=MAX_PACKAGE_BYTES)] | None = None
    file_count: Annotated[int, Field(strict=True, ge=0, le=MAX_PACKAGE_FILES)] | None = None

    @model_validator(mode="after")
    def conservative_eligibility(self):
        if self.eligible and (self.state != "available" or self.protection_reasons):
            raise ValueError("backup_candidate_protected")
        if not self.eligible and not self.protection_reasons:
            raise ValueError("backup_candidate_reason_required")
        return self
