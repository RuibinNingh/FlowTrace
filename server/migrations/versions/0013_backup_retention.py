"""Backup controls, append-only intents and irreversible protection release."""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0013_backup_retention"
down_revision = "0012_group_pulls"
branch_labels = None
depends_on = None

LIFECYCLE_UP = r"""-- Frozen review candidate only: not an installed migration or runtime hook.
-- Root owns migration registration. Application CAS still authorizes releases.
-- These guards preserve history; they do not execute any backup file effect.

CREATE FUNCTION public.flowtrace_backup_intent_immutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $guard$
BEGIN
    RAISE EXCEPTION USING
        ERRCODE = '55000', MESSAGE = 'backup_retention_intent_immutable';
END;
$guard$;

CREATE FUNCTION public.flowtrace_backup_pin_lifecycle()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $guard$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.version IS DISTINCT FROM 1
           OR NEW.released_at IS NOT NULL
           OR NEW.released_by IS NOT NULL
           OR NEW.release_request_id IS NOT NULL
           OR NEW.release_request_hash IS NOT NULL THEN
            RAISE EXCEPTION USING
                ERRCODE = '55000', MESSAGE = 'backup_pin_lifecycle_invalid';
        END IF;
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.version IS DISTINCT FROM 1
           OR NEW.version IS DISTINCT FROM 2
           OR OLD.released_at IS NOT NULL
           OR OLD.released_by IS NOT NULL
           OR OLD.release_request_id IS NOT NULL
           OR OLD.release_request_hash IS NOT NULL
           OR NEW.released_at IS NULL
           OR NEW.released_by IS NULL
           OR NEW.release_request_id IS NULL
           OR NEW.release_request_hash IS NULL
           OR (to_jsonb(NEW) - ARRAY[
               'version', 'released_at', 'released_by',
               'release_request_id', 'release_request_hash'
           ]::text[]) IS DISTINCT FROM (to_jsonb(OLD) - ARRAY[
               'version', 'released_at', 'released_by',
               'release_request_id', 'release_request_hash'
           ]::text[]) THEN
            RAISE EXCEPTION USING
                ERRCODE = '55000', MESSAGE = 'backup_pin_lifecycle_invalid';
        END IF;
        RETURN NEW;
    END IF;
    RAISE EXCEPTION USING
        ERRCODE = '55000', MESSAGE = 'backup_pin_immutable';
END;
$guard$;

CREATE FUNCTION public.flowtrace_backup_hold_lifecycle()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $guard$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.version IS DISTINCT FROM 1
           OR NEW.released_at IS NOT NULL
           OR NEW.release_proof IS NOT NULL THEN
            RAISE EXCEPTION USING
                ERRCODE = '55000', MESSAGE = 'backup_hold_lifecycle_invalid';
        END IF;
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.version IS DISTINCT FROM 1
           OR NEW.version IS DISTINCT FROM 2
           OR OLD.released_at IS NOT NULL
           OR OLD.release_proof IS NOT NULL
           OR NEW.released_at IS NULL
           OR NEW.release_proof IS NULL
           OR (to_jsonb(NEW) - ARRAY[
               'version', 'released_at', 'release_proof'
           ]::text[]) IS DISTINCT FROM (to_jsonb(OLD) - ARRAY[
               'version', 'released_at', 'release_proof'
           ]::text[]) THEN
            RAISE EXCEPTION USING
                ERRCODE = '55000', MESSAGE = 'backup_hold_lifecycle_invalid';
        END IF;
        RETURN NEW;
    END IF;
    RAISE EXCEPTION USING
        ERRCODE = '55000', MESSAGE = 'backup_hold_immutable';
END;
$guard$;

CREATE FUNCTION public.flowtrace_backup_protection_truncate_rejected()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $guard$
BEGIN
    RAISE EXCEPTION USING
        ERRCODE = '55000', MESSAGE = 'backup_protection_truncate_rejected';
END;
$guard$;

CREATE TRIGGER tr_backup_retention_intent_immutable
BEFORE UPDATE OR DELETE ON public.backup_retention_intents
FOR EACH ROW EXECUTE FUNCTION public.flowtrace_backup_intent_immutable();

CREATE TRIGGER tr_backup_retention_intent_no_truncate
BEFORE TRUNCATE ON public.backup_retention_intents
FOR EACH STATEMENT EXECUTE FUNCTION public.flowtrace_backup_intent_immutable();

CREATE TRIGGER tr_backup_pin_lifecycle
BEFORE INSERT OR UPDATE OR DELETE ON public.backup_pins
FOR EACH ROW EXECUTE FUNCTION public.flowtrace_backup_pin_lifecycle();

CREATE TRIGGER tr_backup_pin_no_truncate
BEFORE TRUNCATE ON public.backup_pins
FOR EACH STATEMENT
EXECUTE FUNCTION public.flowtrace_backup_protection_truncate_rejected();

CREATE TRIGGER tr_backup_hold_lifecycle
BEFORE INSERT OR UPDATE OR DELETE ON public.backup_holds
FOR EACH ROW EXECUTE FUNCTION public.flowtrace_backup_hold_lifecycle();

CREATE TRIGGER tr_backup_hold_no_truncate
BEFORE TRUNCATE ON public.backup_holds
FOR EACH STATEMENT
EXECUTE FUNCTION public.flowtrace_backup_protection_truncate_rejected();
"""

LIFECYCLE_DOWN = r"""-- Frozen downgrade companion. Drop guards before root drops their tables.
DROP TRIGGER tr_backup_hold_no_truncate ON public.backup_holds;
DROP TRIGGER tr_backup_hold_lifecycle ON public.backup_holds;
DROP TRIGGER tr_backup_pin_no_truncate ON public.backup_pins;
DROP TRIGGER tr_backup_pin_lifecycle ON public.backup_pins;
DROP TRIGGER tr_backup_retention_intent_no_truncate ON public.backup_retention_intents;
DROP TRIGGER tr_backup_retention_intent_immutable ON public.backup_retention_intents;

DROP FUNCTION public.flowtrace_backup_protection_truncate_rejected();
DROP FUNCTION public.flowtrace_backup_hold_lifecycle();
DROP FUNCTION public.flowtrace_backup_pin_lifecycle();
DROP FUNCTION public.flowtrace_backup_intent_immutable();
"""


def upgrade():
    op.create_table(
        "backup_retention_intents",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("preview_id", sa.Uuid(), nullable=False),
        sa.Column("actor_id", sa.Uuid(), nullable=False),
        sa.Column("origin_session_id", sa.Uuid(), nullable=False),
        sa.Column("request_id", sa.Uuid(), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("selection_sha256", sa.String(length=64), nullable=False),
        sa.Column("config_version", sa.BigInteger(), nullable=False),
        sa.Column("source_instance_id", sa.Uuid(), nullable=False),
        sa.Column("source_epoch", sa.Uuid(), nullable=False),
        sa.Column("packages", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("job_id", sa.Uuid(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "jsonb_typeof(packages)='array' AND jsonb_array_length(packages) BETWEEN 1 AND 20",
            name="ck_backup_intent_packages",
        ),
        sa.CheckConstraint(
            "request_hash ~ '^[0-9a-f]{64}$' AND selection_sha256 ~ '^[0-9a-f]{64}$'",
            name="ck_backup_intent_hashes",
        ),
        sa.CheckConstraint("config_version>=0", name="ck_backup_intent_version"),
        sa.ForeignKeyConstraint(
            ["actor_id"],
            ["users.id"],
        ),
        sa.ForeignKeyConstraint(
            ["job_id"],
            ["background_jobs.id"],
        ),
        sa.ForeignKeyConstraint(
            ["origin_session_id"],
            ["sessions.id"],
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("job_id"),
        sa.UniqueConstraint("preview_id"),
        sa.UniqueConstraint("request_id"),
    )
    op.create_index(
        "ix_backup_intent_actor_created",
        "backup_retention_intents",
        ["actor_id", "created_at"],
        unique=False,
    )
    op.create_table(
        "backup_controls",
        sa.Column("backup_id", sa.Uuid(), nullable=False),
        sa.Column("version", sa.BigInteger(), server_default="1", nullable=False),
        sa.Column(
            "state", sa.String(length=16), server_default="available", nullable=False
        ),
        sa.Column("intent_id", sa.Uuid(), nullable=True),
        sa.Column("manifest_sha256", sa.String(length=64), nullable=False),
        sa.Column("tree_sha256", sa.String(length=64), nullable=False),
        sa.Column("instance_id", sa.Uuid(), nullable=False),
        sa.Column("sync_epoch", sa.Uuid(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("size_bytes", sa.BigInteger(), nullable=False),
        sa.Column("file_count", sa.Integer(), nullable=False),
        sa.Column(
            "registered_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "(state='available' AND intent_id IS NULL) OR (state<>'available' AND intent_id IS NOT NULL)",
            name="ck_backup_control_intent",
        ),
        sa.CheckConstraint(
            "manifest_sha256 ~ '^[0-9a-f]{64}$' AND tree_sha256 ~ '^[0-9a-f]{64}$'",
            name="ck_backup_control_hashes",
        ),
        sa.CheckConstraint(
            "state IN ('available','reserved','quarantined','partial','destroyed')",
            name="ck_backup_control_state",
        ),
        sa.CheckConstraint(
            "size_bytes BETWEEN 1 AND 1078984704 AND file_count BETWEEN 3 AND 100002",
            name="ck_backup_control_capacity",
        ),
        sa.CheckConstraint("version>=1", name="ck_backup_control_version"),
        sa.ForeignKeyConstraint(
            ["intent_id"],
            ["backup_retention_intents.id"],
        ),
        sa.PrimaryKeyConstraint("backup_id"),
    )
    op.create_index(
        "ix_backup_control_created",
        "backup_controls",
        ["created_at", "backup_id"],
        unique=False,
    )
    op.create_table(
        "backup_holds",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("backup_id", sa.Uuid(), nullable=False),
        sa.Column("version", sa.BigInteger(), server_default="1", nullable=False),
        sa.Column("holder_kind", sa.String(length=24), nullable=False),
        sa.Column("holder_id", sa.Uuid(), nullable=False),
        sa.Column("job_id", sa.Uuid(), nullable=True),
        sa.Column("owner_user_id", sa.Uuid(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("released_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("release_proof", sa.String(length=32), nullable=True),
        sa.CheckConstraint(
            "(holder_kind='download' AND job_id IS NULL) OR (holder_kind IN ('job','restore_intent') AND job_id IS NOT NULL AND job_id=holder_id)",
            name="ck_backup_hold_job",
        ),
        sa.CheckConstraint(
            "(version=1 AND released_at IS NULL AND release_proof IS NULL) OR (version=2 AND released_at IS NOT NULL AND release_proof IS NOT NULL AND release_proof IN ('archive_built','job_terminal_verified','explicit_reconcile'))",
            name="ck_backup_hold_lifecycle",
        ),
        sa.CheckConstraint(
            "holder_kind IN ('job','download','restore_intent')",
            name="ck_backup_hold_kind",
        ),
        sa.CheckConstraint(
            "released_at IS NULL OR released_at>=created_at", name="ck_backup_hold_time"
        ),
        sa.ForeignKeyConstraint(
            ["backup_id"],
            ["backup_controls.backup_id"],
        ),
        sa.ForeignKeyConstraint(
            ["job_id"],
            ["background_jobs.id"],
        ),
        sa.ForeignKeyConstraint(
            ["owner_user_id"],
            ["users.id"],
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "backup_id", "holder_kind", "holder_id", name="uq_backup_hold_holder"
        ),
    )
    op.create_index(
        "ix_backup_hold_active",
        "backup_holds",
        ["backup_id", "released_at"],
        unique=False,
    )
    op.create_table(
        "backup_pins",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("backup_id", sa.Uuid(), nullable=False),
        sa.Column("version", sa.BigInteger(), server_default="1", nullable=False),
        sa.Column("created_by", sa.Uuid(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("create_request_id", sa.Uuid(), nullable=False),
        sa.Column("create_request_hash", sa.String(length=64), nullable=False),
        sa.Column("released_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("released_by", sa.Uuid(), nullable=True),
        sa.Column("release_request_id", sa.Uuid(), nullable=True),
        sa.Column("release_request_hash", sa.String(length=64), nullable=True),
        sa.CheckConstraint(
            "create_request_hash ~ '^[0-9a-f]{64}$' AND (release_request_hash IS NULL OR release_request_hash ~ '^[0-9a-f]{64}$')",
            name="ck_backup_pin_hashes",
        ),
        sa.CheckConstraint(
            "(version=1 AND released_at IS NULL AND released_by IS NULL AND release_request_id IS NULL AND release_request_hash IS NULL) OR (version=2 AND released_at IS NOT NULL AND released_by IS NOT NULL AND release_request_id IS NOT NULL AND release_request_hash IS NOT NULL)",
            name="ck_backup_pin_lifecycle",
        ),
        sa.CheckConstraint(
            "released_at IS NULL OR released_at>=created_at", name="ck_backup_pin_time"
        ),
        sa.ForeignKeyConstraint(
            ["backup_id"],
            ["backup_controls.backup_id"],
        ),
        sa.ForeignKeyConstraint(
            ["created_by"],
            ["users.id"],
        ),
        sa.ForeignKeyConstraint(
            ["released_by"],
            ["users.id"],
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("create_request_id"),
        sa.UniqueConstraint("release_request_id"),
    )
    op.create_index(
        "ix_backup_pin_active",
        "backup_pins",
        ["backup_id", "released_at"],
        unique=False,
    )
    op.execute(sa.text(LIFECYCLE_UP))


def downgrade():
    op.execute(sa.text(LIFECYCLE_DOWN))
    op.drop_table("backup_pins")
    op.drop_table("backup_holds")
    op.drop_table("backup_controls")
    op.drop_table("backup_retention_intents")
