"""Closed group-sync-v1 wire, separate from all existing sync-v1 DTOs.

Hashes cover exact canonical raw projections: validation never inserts missing
legacy projection defaults. All envelopes, including descriptors, are byte
bounded. A manifest's opaque IDs are scoped to one fixed pull, not publication
UUID5 namespaces and not an authorization credential.
"""

from typing import Annotated, Any, Literal

from pydantic import Field, StringConstraints, field_validator, model_validator

from .canonical import canonical_bytes, content_hash
from .responses import ChangeEvent
from .schemas import ClosedModel, Identifier, Instant, Revision

GROUP_PROTOCOL = "group-sync-v1"
MAX_SCOPES = 1000
MAX_PAGE_BYTES = 512 * 1024
MAX_SESSION_BYTES = 512 * 1024 * 1024
MAX_UNITS = 10000
MAX_PAGES = 8192
MAX_INDEX_PAGES = 1024
MAX_MANIFEST_PARTS = 128
MAX_COMMITS_PER_UNIT = 2000
MAX_EVENTS = MAX_COMMITS_PER_UNIT * 200
MAX_RETAINED_SESSIONS = 2
MAX_STEP_SECONDS = 5

Digest = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
Token = Annotated[str, StringConstraints(min_length=20, max_length=128)]
Vector = Annotated[dict[Identifier, Revision], Field(max_length=MAX_SCOPES)]


def validate_vector(vector):
    if any(int(value) > 2**63 - 1 for value in vector.values()):
        raise ValueError("group_revision_out_of_range")
    return vector


def validate_group_event(value):
    ChangeEvent.model_validate(value)
    canonical_bytes(value)
    if value["deleted"] != (value["data"] is None):
        raise ValueError("group_event_projection_invalid")
    if any(int(value[key]) > 2**63 - 1 for key in ("scope_revision", "revision")):
        raise ValueError("group_revision_out_of_range")
    return value


class BoundedWire(ClosedModel):
    @model_validator(mode="after")
    def byte_bound(self):
        if len(canonical_bytes(self.model_dump(mode="json"))) > MAX_PAGE_BYTES:
            raise ValueError("group_wire_bytes_exceeded")
        return self


class GroupPullCreate(BoundedWire):
    protocol_version: Literal[1]
    request_id: Identifier
    client_id: Identifier
    sync_epoch: Identifier
    # Empty means new-reader bootstrap, not the old snapshot fallback.
    cursors: Vector

    @field_validator("protocol_version", mode="before")
    @classmethod
    def integer_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_protocol_version")
        return value

    _revisions = field_validator("cursors")(validate_vector)


class GroupPullStep(BoundedWire):
    client_id: Identifier
    step_token: Token


class GroupPullDiscard(BoundedWire):
    client_id: Identifier


class GroupPullDiscarded(BoundedWire):
    pull_id: Identifier
    status: Literal["collected"]


class GroupPullSummary(BoundedWire):
    pull_id: Identifier
    request_id: Identifier
    client_id: Identifier
    sync_epoch: Identifier
    status: Literal["planning", "materializing", "ready", "failed"]
    expires_at: Instant


class GroupPullListing(BoundedWire):
    pulls: Annotated[list[GroupPullSummary], Field(max_length=MAX_RETAINED_SESSIONS)]


class GroupPullPageRequest(BoundedWire):
    client_id: Identifier
    page_token: Token


class GroupPageDescriptor(BoundedWire):
    # Counts units for index pages, descriptors for manifest parts, events for data.
    page_index: int = Field(ge=0, lt=MAX_PAGES)
    item_count: int = Field(ge=0, le=200)
    sha256: Digest


class GroupCommitDescriptor(BoundedWire):
    commit_index: int = Field(ge=0, lt=MAX_COMMITS_PER_UNIT)
    commit_id: Identifier
    event_count: int = Field(ge=1, le=200)
    events_sha256: Digest


class GroupFragment(BoundedWire):
    commit_index: int = Field(ge=0, lt=MAX_COMMITS_PER_UNIT)
    event_offset: int = Field(ge=0, le=199)
    events: list[dict[str, Any]] = Field(min_length=1, max_length=200)

    @field_validator("events")
    @classmethod
    def exact_events(cls, values):
        for value in values:
            validate_group_event(value)
        return values

    @model_validator(mode="after")
    def bounded_commit_fragment(self):
        if self.event_offset + len(self.events) > 200:
            raise ValueError("group_fragment_outside_commit")
        return self


class GroupUnitDescriptor(BoundedWire):
    unit_index: int = Field(ge=0, lt=MAX_UNITS)
    group_id: Identifier
    kind: Literal["commit", "publication"]
    commit_count: int = Field(ge=1, le=MAX_COMMITS_PER_UNIT)
    event_count: int = Field(ge=1, le=MAX_EVENTS)
    end_cursors: Vector
    manifest_parts: list[GroupPageDescriptor] = Field(min_length=1, max_length=MAX_MANIFEST_PARTS)
    manifest_sha256: Digest

    _revisions = field_validator("end_cursors")(validate_vector)

    @model_validator(mode="after")
    def complete_unit(self):
        if (
            not self.commit_count <= self.event_count <= self.commit_count * 200
            or (self.kind == "commit" and self.commit_count != 1)
            or [part.page_index for part in self.manifest_parts]
            != list(range(len(self.manifest_parts)))
        ):
            raise ValueError("group_unit_descriptor_invalid")
        return self


class GroupPullManifest(BoundedWire):
    protocol: Literal["group-sync-v1"]
    pull_id: Identifier
    request_id: Identifier
    instance_id: Identifier
    user_id: Identifier
    client_id: Identifier
    sync_epoch: Identifier
    control_version: Revision
    permission_versions: Vector
    base_cursors: Vector
    checkpoint: Vector
    unit_count: int = Field(ge=0, le=MAX_UNITS)
    index_pages: list[GroupPageDescriptor] = Field(max_length=MAX_INDEX_PAGES)

    _revisions = field_validator("permission_versions", "base_cursors", "checkpoint")(
        validate_vector
    )

    @model_validator(mode="after")
    def coherent_pull_manifest(self):
        validate_vector({self.user_id: self.control_version})
        if (
            not self.permission_versions
            or set(self.checkpoint) != set(self.permission_versions)
            or not set(self.base_cursors).issubset(self.checkpoint)
            or any(
                int(value) > int(self.checkpoint[key]) for key, value in self.base_cursors.items()
            )
            or [page.page_index for page in self.index_pages] != list(range(len(self.index_pages)))
            or sum(page.item_count for page in self.index_pages) != self.unit_count
            or bool(self.unit_count) != bool(self.index_pages)
        ):
            raise ValueError("group_pull_manifest_invalid")
        return self


class GroupPullStatus(BoundedWire):
    pull_id: Identifier
    request_id: Identifier
    sync_epoch: Identifier
    expires_at: Instant
    status: Literal["planning", "materializing", "ready", "failed", "expired"]
    progress_code: Literal["planning", "materializing", "ready", "limit", "expired", "unavailable"]
    next_step_token: Token | None
    manifest: GroupPullManifest | None
    manifest_sha256: Digest | None
    first_page_token: Token | None

    @model_validator(mode="after")
    def ready_only_manifest(self):
        if self.status == "ready":
            if (
                self.manifest is None
                or self.manifest.pull_id != self.pull_id
                or self.manifest.request_id != self.request_id
                or self.manifest.sync_epoch != self.sync_epoch
                or content_hash(self.manifest.model_dump(mode="json")) != self.manifest_sha256
                or self.next_step_token is not None
                or bool(self.manifest.unit_count) != bool(self.first_page_token)
                or self.progress_code != "ready"
            ):
                raise ValueError("group_ready_status_invalid")
        elif any(
            value is not None
            for value in (self.manifest, self.manifest_sha256, self.first_page_token)
        ):
            raise ValueError("group_manifest_not_ready")
        elif self.status in {"failed", "expired"} and self.next_step_token is not None:
            raise ValueError("group_terminal_step_invalid")
        elif self.status in {"planning", "materializing"} and (
            self.next_step_token is None or self.progress_code != self.status
        ):
            raise ValueError("group_pending_step_invalid")
        return self


def page_hash_payload(body):
    return {
        key: value for key, value in body.items() if key not in {"page_sha256", "next_page_token"}
    }


def unit_manifest_hash(pull_id, descriptor):
    return content_hash(
        {
            "pull_id": pull_id,
            **{key: value for key, value in descriptor.items() if key != "manifest_sha256"},
        }
    )


class HashedGroupPage(BoundedWire):
    pull_id: Identifier
    page_index: int = Field(ge=0, lt=MAX_PAGES)
    page_sha256: Digest
    next_page_token: Token | None

    @model_validator(mode="after")
    def verified_page_hash(self):
        if content_hash(page_hash_payload(self.model_dump(mode="json"))) != self.page_sha256:
            raise ValueError("group_page_hash_invalid")
        return self


class GroupUnitIndexPage(HashedGroupPage):
    kind: Literal["index"]
    units: list[GroupUnitDescriptor] = Field(min_length=1, max_length=200)

    @model_validator(mode="after")
    def ordered_bound_units(self):
        start = self.units[0].unit_index
        if (
            [unit.unit_index for unit in self.units] != list(range(start, start + len(self.units)))
            or len({unit.group_id for unit in self.units}) != len(self.units)
            or any(
                unit_manifest_hash(self.pull_id, unit.model_dump(mode="json"))
                != unit.manifest_sha256
                for unit in self.units
            )
        ):
            raise ValueError("group_unit_manifest_invalid")
        return self


class GroupUnitManifestPage(HashedGroupPage):
    kind: Literal["manifest"]
    group_id: Identifier
    commits: list[GroupCommitDescriptor] = Field(max_length=200)
    data_pages: list[GroupPageDescriptor] = Field(max_length=200)

    @model_validator(mode="after")
    def bounded_metadata_items(self):
        if not 1 <= len(self.commits) + len(self.data_pages) <= 200:
            raise ValueError("group_manifest_part_invalid")
        return self


class GroupDataPage(HashedGroupPage):
    kind: Literal["data"]
    group_id: Identifier
    fragments: list[GroupFragment] = Field(min_length=1, max_length=200)

    @model_validator(mode="after")
    def bounded_page_events(self):
        if sum(len(fragment.events) for fragment in self.fragments) > 200:
            raise ValueError("group_page_event_limit")
        indices = [fragment.commit_index for fragment in self.fragments]
        if indices != sorted(set(indices)):
            raise ValueError("group_fragment_order_invalid")
        return self
