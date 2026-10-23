"""Strict configuration DTOs; prepared references are internal facade outputs.

No secret value, URL, file path or executable name belongs in this schema.
The facade must bind prepared reference changes to actor/version/request/field
before passing the internal command to the transaction-owned store.
"""

from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator

MAX_VERSION = 2**63 - 1
MAX_FILE_BYTES = 10 * 1024 * 1024
MAX_QUOTA_BYTES = 1024**4

Version = Annotated[int, Field(strict=True, ge=0, le=MAX_VERSION)]
InviteDays = Annotated[int, Field(strict=True, ge=1, le=30)]
FileBytes = Annotated[int, Field(strict=True, ge=1, le=MAX_FILE_BYTES)]
QuotaBytes = Annotated[int, Field(strict=True, ge=1, le=MAX_QUOTA_BYTES)]
OrphanDays = Annotated[int, Field(strict=True, ge=1, le=365)]
RetentionDays = Annotated[int, Field(strict=True, ge=1, le=3650)]
PollSeconds = Annotated[float, Field(strict=True, ge=0.25, le=60, allow_inf_nan=False)]
OCRProvider = Literal["disabled", "ocr_primary"]
AIProvider = Literal["disabled", "ai_primary"]
ConfigurationKey = Literal[
    "registration_enabled",
    "invitation_default_days",
    "attachment_max_bytes",
    "per_user_attachment_quota_bytes",
    "orphan_retention_days",
    "diagnostics_enabled",
    "worker_poll_seconds",
    "backup_retention_days",
    "ocr_provider",
    "ai_provider",
]
SecretKey = Literal["ocr_api_key", "ai_api_key"]

# The migration copies these explicit values. It must not import live defaults.
INITIAL_PUBLIC_VALUES = {
    "registration_enabled": True,
    "invitation_default_days": 7,
    "attachment_max_bytes": 10485760,
    "per_user_attachment_quota_bytes": 1073741824,
    "orphan_retention_days": 7,
    "diagnostics_enabled": True,
    "worker_poll_seconds": 1.0,
    "backup_retention_days": 30,
    "ocr_provider": "disabled",
    "ai_provider": "disabled",
}
INITIAL_SECRET_REFS = {"ocr_api_key": None, "ai_api_key": None}


class ClosedDTO(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, hide_input_in_errors=True, frozen=True)


class PublicConfiguration(ClosedDTO):
    registration_enabled: bool = True
    invitation_default_days: InviteDays = 7
    attachment_max_bytes: FileBytes = MAX_FILE_BYTES
    per_user_attachment_quota_bytes: QuotaBytes = 1024**3
    orphan_retention_days: OrphanDays = 7
    diagnostics_enabled: bool = True
    worker_poll_seconds: PollSeconds = 1.0
    backup_retention_days: RetentionDays = 30
    ocr_provider: OCRProvider = "disabled"
    ai_provider: AIProvider = "disabled"

    @model_validator(mode="after")
    def quota_covers_one_file(self):
        if self.per_user_attachment_quota_bytes < self.attachment_max_bytes:
            raise ValueError("configuration_quota_below_file_limit")
        return self


class PublicConfigurationPatch(ClosedDTO):
    registration_enabled: bool | None = None
    invitation_default_days: InviteDays | None = None
    attachment_max_bytes: FileBytes | None = None
    per_user_attachment_quota_bytes: QuotaBytes | None = None
    orphan_retention_days: OrphanDays | None = None
    diagnostics_enabled: bool | None = None
    worker_poll_seconds: PollSeconds | None = None
    backup_retention_days: RetentionDays | None = None
    ocr_provider: OCRProvider | None = None
    ai_provider: AIProvider | None = None

    @model_validator(mode="before")
    @classmethod
    def explicit_null_is_not_a_configuration_value(cls, value):
        if isinstance(value, dict) and any(item is None for item in value.values()):
            raise ValueError("configuration_null_value_invalid")
        return value

    def apply(self, current: PublicConfiguration):
        return PublicConfiguration.model_validate(
            {
                **current.model_dump(),
                **self.model_dump(exclude_unset=True),
            }
        )


class SecretReferences(ClosedDTO):
    ocr_api_key: UUID | None = None
    ai_api_key: UUID | None = None


class PreparedSecretReferencePatch(ClosedDTO):
    """Trusted internal data: absent=keep, UUID=replace, explicit null=delete.

    UUID syntax is not authority. Only the root facade may create a command
    after checking vault ownership and its actor/version/request/field binding.
    This DTO is never accepted directly from an HTML form or public JSON route.
    """

    ocr_api_key: UUID | None = None
    ai_api_key: UUID | None = None

    def apply(self, current: SecretReferences):
        return SecretReferences.model_validate(
            {
                **current.model_dump(),
                **self.model_dump(exclude_unset=True),
            }
        )


class SecretPresence(ClosedDTO):
    ocr_api_key: bool
    ai_api_key: bool


class ConfigurationSaveCommand(ClosedDTO):
    base_version: Version
    request_id: UUID
    public_patch: PublicConfigurationPatch
    prepared_secret_refs: PreparedSecretReferencePatch = Field(
        default_factory=PreparedSecretReferencePatch
    )


class ConfigurationRollbackCommand(ClosedDTO):
    base_version: Version
    target_version: Version
    request_id: UUID


class ConfigurationView(ClosedDTO):
    version: Version
    public_values: PublicConfiguration
    secret_presence: SecretPresence
    effective_fields: tuple[ConfigurationKey, ...]
    editable_fields: tuple[ConfigurationKey, ...]


class ConfigurationMutationResult(ClosedDTO):
    version: Version
    replayed: bool
