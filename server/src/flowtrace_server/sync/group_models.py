"""Independent group-sync-v1 staging metadata, not registered or migrated here.

Existing v1 pull/snapshot tables and stored JSON remain unchanged. Services must
serialize per-user reservations, bind current sessions and publish ready only
after every immutable descriptor/page has been verified; CHECKs alone cannot
prove these cross-row invariants. Expired rows still occupy reserved quota until
their bytes have actually been removed. A future change GC must respect each
non-collected session's base/target revision retention pins.
"""

from datetime import datetime
from uuid import UUID

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    DateTime,
    ForeignKey,
    ForeignKeyConstraint,
    Index,
    String,
    UniqueConstraint,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from flowtrace_server.persistence.models import Base


class GroupPullSession(Base):
    __tablename__ = "group_pull_sessions"
    __table_args__ = (
        UniqueConstraint(
            "user_id", "client_id", "sync_epoch", "request_id", name="uq_group_pull_intent"
        ),
        CheckConstraint(
            "status IN ('planning','materializing','ready','failed')", name="ck_group_pull_status"
        ),
        CheckConstraint("origin_purpose IN ('api_native','api_web')", name="ck_group_pull_purpose"),
        CheckConstraint("control_version >= 0", name="ck_group_pull_control"),
        CheckConstraint("reserved_bytes BETWEEN 0 AND 536870912", name="ck_group_pull_bytes"),
        CheckConstraint(
            "unit_count BETWEEN 0 AND 10000 AND page_count BETWEEN 0 AND 8192",
            name="ck_group_pull_counts",
        ),
        CheckConstraint("intent_hash ~ '^[0-9a-f]{64}$'", name="ck_group_pull_hash"),
        CheckConstraint(
            "(manifest_sha256 IS NULL OR manifest_sha256 ~ '^[0-9a-f]{64}$') "
            "AND (next_step_token_hash IS NULL OR next_step_token_hash ~ '^[0-9a-f]{64}$')",
            name="ck_group_pull_optional_hashes",
        ),
        CheckConstraint(
            "(status='ready' AND manifest IS NOT NULL AND jsonb_typeof(manifest)='object' "
            "AND manifest_sha256 IS NOT NULL AND next_step_token_hash IS NULL) "
            "OR (status<>'ready' AND manifest IS NULL AND manifest_sha256 IS NULL)",
            name="ck_group_pull_ready_manifest",
        ),
        CheckConstraint(
            "jsonb_typeof(base_cursors)='object' AND jsonb_typeof(checkpoint)='object' "
            "AND jsonb_typeof(permission_versions)='object' AND jsonb_typeof(build_state)='object'",
            name="ck_group_pull_objects",
        ),
        Index("ix_group_pull_owner_expiry", "user_id", "expires_at"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"))
    client_id: Mapped[UUID]
    request_id: Mapped[UUID]
    sync_epoch: Mapped[UUID]
    origin_session_id: Mapped[UUID] = mapped_column(ForeignKey("sessions.id"))
    origin_purpose: Mapped[str] = mapped_column(String(16))
    control_version: Mapped[int] = mapped_column(BigInteger)
    intent_hash: Mapped[str] = mapped_column(String(64))
    base_cursors: Mapped[dict] = mapped_column(JSONB)
    checkpoint: Mapped[dict] = mapped_column(JSONB)
    permission_versions: Mapped[dict] = mapped_column(JSONB)
    status: Mapped[str] = mapped_column(String(16))
    # Bounded, trusted finite-step positions/plan; never a public status body.
    build_state: Mapped[dict] = mapped_column(JSONB)
    next_step_token_hash: Mapped[str | None] = mapped_column(String(64))
    reserved_bytes: Mapped[int] = mapped_column(BigInteger)
    unit_count: Mapped[int]
    page_count: Mapped[int]
    manifest: Mapped[dict | None] = mapped_column(JSONB(none_as_null=True))
    manifest_sha256: Mapped[str | None] = mapped_column(String(64))
    first_page_token: Mapped[str | None] = mapped_column(String(128))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class GroupPullUnit(Base):
    __tablename__ = "group_pull_units"
    __table_args__ = (
        UniqueConstraint("pull_id", "group_id", name="uq_group_pull_opaque_unit"),
        UniqueConstraint("pull_id", "topological_index", name="uq_group_pull_topological_unit"),
        ForeignKeyConstraint(
            ["source_scope_id", "source_scope_revision", "source_event_index"],
            ["sync_changes.scope_id", "sync_changes.scope_revision", "sync_changes.event_index"],
            name="fk_group_unit_source_change",
        ),
        CheckConstraint("unit_index BETWEEN 0 AND 9999", name="ck_group_unit_index"),
        CheckConstraint(
            "topological_index IS NULL OR topological_index BETWEEN 0 AND 9999",
            name="ck_group_unit_topology",
        ),
        CheckConstraint(
            "status IN ('planning','planned','materializing','ready')",
            name="ck_group_unit_status",
        ),
        CheckConstraint("kind IN ('commit','publication')", name="ck_group_unit_kind"),
        CheckConstraint(
            "commit_count BETWEEN 0 AND 2000 "
            "AND event_count BETWEEN commit_count AND commit_count*200 "
            "AND (status='planning' OR commit_count>=1)",
            name="ck_group_unit_counts",
        ),
        CheckConstraint(
            "(kind='commit' AND publication_id IS NULL AND commit_count<=1 "
            "AND source_commit_id IS NOT NULL AND source_scope_id IS NOT NULL "
            "AND source_scope_revision IS NOT NULL AND source_event_index IS NOT NULL) "
            "OR (kind='publication' AND publication_id IS NOT NULL AND source_commit_id IS NULL "
            "AND source_scope_id IS NULL AND source_scope_revision IS NULL "
            "AND source_event_index IS NULL)",
            name="ck_group_unit_publication",
        ),
        CheckConstraint(
            "jsonb_typeof(end_cursors)='object' AND jsonb_typeof(manifest_parts)='array'",
            name="ck_group_unit_objects",
        ),
        CheckConstraint(
            "jsonb_array_length(manifest_parts)<=128 AND "
            "(manifest_sha256 IS NULL OR manifest_sha256 ~ '^[0-9a-f]{64}$')",
            name="ck_group_unit_manifest_bounds",
        ),
        CheckConstraint(
            "jsonb_typeof(plan_state)='object' AND jsonb_typeof(predecessor_ids)='array' "
            "AND jsonb_array_length(predecessor_ids)<=1000 "
            "AND remaining_predecessors BETWEEN 0 AND 1000",
            name="ck_group_unit_plan",
        ),
        Index("ix_group_unit_plan_step", "pull_id", "status", "unit_index"),
        Index("ix_group_unit_predecessors", "predecessor_ids", postgresql_using="gin"),
    )
    pull_id: Mapped[UUID] = mapped_column(ForeignKey("group_pull_sessions.id"), primary_key=True)
    unit_index: Mapped[int] = mapped_column(primary_key=True)
    # Discovery key remains stable for page FKs; only this ordinal enters wire.
    topological_index: Mapped[int | None]
    group_id: Mapped[UUID]
    kind: Mapped[str] = mapped_column(String(16))
    status: Mapped[str] = mapped_column(String(16))
    # Internal UUID5 namespace. It MUST NOT enter a public DTO, hash or log.
    publication_id: Mapped[UUID | None] = mapped_column(ForeignKey("import_publications.id"))
    # commit_id is not unique in sync_changes. The actual FK is the immutable
    # representative change PK; services also verify its commit_id matches.
    source_commit_id: Mapped[UUID | None]
    source_scope_id: Mapped[UUID | None]
    source_scope_revision: Mapped[int | None] = mapped_column(BigInteger)
    source_event_index: Mapped[int | None]
    plan_state: Mapped[dict] = mapped_column(JSONB)
    predecessor_ids: Mapped[list] = mapped_column(JSONB)
    remaining_predecessors: Mapped[int]
    commit_count: Mapped[int]
    event_count: Mapped[int]
    end_cursors: Mapped[dict] = mapped_column(JSONB)
    manifest_parts: Mapped[list] = mapped_column(JSONB)
    manifest_sha256: Mapped[str | None] = mapped_column(String(64))


class GroupPullPage(Base):
    __tablename__ = "group_pull_pages"
    __table_args__ = (
        ForeignKeyConstraint(
            ["pull_id", "unit_index"],
            ["group_pull_units.pull_id", "group_pull_units.unit_index"],
            name="fk_group_page_unit",
        ),
        CheckConstraint(
            "kind IN ('index','manifest','data','step','plan')", name="ck_group_page_kind"
        ),
        CheckConstraint(
            "page_index BETWEEN 0 AND 8191 AND size_bytes BETWEEN 1 AND 524288",
            name="ck_group_page_bounds",
        ),
        CheckConstraint(
            "sha256 ~ '^[0-9a-f]{64}$' AND token_hash ~ '^[0-9a-f]{64}$'",
            name="ck_group_page_hashes",
        ),
        CheckConstraint(
            "((kind IN ('index','step')) AND unit_index IS NULL) "
            "OR ((kind IN ('manifest','data','plan')) AND unit_index IS NOT NULL)",
            name="ck_group_page_unit_binding",
        ),
        CheckConstraint("jsonb_typeof(response)='object'", name="ck_group_page_response"),
        Index(
            "uq_group_page_session_position",
            "pull_id",
            "kind",
            "page_index",
            unique=True,
            postgresql_where=text("unit_index IS NULL"),
        ),
        Index(
            "uq_group_page_unit_position",
            "pull_id",
            "unit_index",
            "kind",
            "page_index",
            unique=True,
            postgresql_where=text("unit_index IS NOT NULL"),
        ),
    )
    token_hash: Mapped[str] = mapped_column(String(64), primary_key=True)
    pull_id: Mapped[UUID] = mapped_column(ForeignKey("group_pull_sessions.id"))
    unit_index: Mapped[int | None]
    kind: Mapped[str] = mapped_column(String(16))
    page_index: Mapped[int]
    response: Mapped[dict] = mapped_column(JSONB)
    sha256: Mapped[str] = mapped_column(String(64))
    size_bytes: Mapped[int]
