"""Versioned closed service configuration, without secret values."""

from datetime import datetime, timezone

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0011_service_configuration"
down_revision = "0010_import_staging"
branch_labels = None
depends_on = None


def upgrade():

    op.create_table(
        "service_configuration",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("current_version", sa.BigInteger(), nullable=False),
        sa.Column("public_values", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("secret_refs", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "(jsonb_typeof(secret_refs->'ocr_api_key')='null' OR (jsonb_typeof"
            "(secret_refs->'ocr_api_key')='string' AND secret_refs->>'ocr_api_"
            "key' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]"
            "{12}$')) AND (jsonb_typeof(secret_refs->'ai_api_key')='null' OR ("
            "jsonb_typeof(secret_refs->'ai_api_key')='string' AND secret_refs-"
            ">>'ai_api_key' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4"
            "}-[0-9a-f]{12}$'))",
            name="ck_configuration_head_secret_uuids",
        ),
        sa.CheckConstraint(
            "jsonb_typeof(public_values)='object' AND public_values ?& ARRAY['"
            "registration_enabled','invitation_default_days','attachment_max_b"
            "ytes','per_user_attachment_quota_bytes','orphan_retention_days','"
            "diagnostics_enabled','worker_poll_seconds','backup_retention_days"
            "','ocr_provider','ai_provider']::text[] AND public_values - ARRAY"
            "['registration_enabled','invitation_default_days','attachment_max"
            "_bytes','per_user_attachment_quota_bytes','orphan_retention_days'"
            ",'diagnostics_enabled','worker_poll_seconds','backup_retention_da"
            "ys','ocr_provider','ai_provider']::text[] = '{}'::jsonb",
            name="ck_configuration_head_public_keys",
        ),
        sa.CheckConstraint(
            "jsonb_typeof(secret_refs)='object' AND secret_refs ?& ARRAY['ocr_"
            "api_key','ai_api_key']::text[] AND secret_refs - ARRAY['ocr_api_k"
            "ey','ai_api_key']::text[] = '{}'::jsonb",
            name="ck_configuration_head_secret_keys",
        ),
        sa.CheckConstraint("current_version >= 0", name="ck_configuration_head_version"),
        sa.CheckConstraint("id=1", name="ck_configuration_singleton"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "service_configuration_revisions",
        sa.Column("version", sa.BigInteger(), nullable=False),
        sa.Column("base_version", sa.BigInteger(), nullable=False),
        sa.Column("request_id", sa.Uuid(), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("actor_user_id", sa.Uuid(), nullable=False),
        sa.Column("change_kind", sa.String(length=12), nullable=False),
        sa.Column("rollback_target_version", sa.BigInteger(), nullable=True),
        sa.Column("public_values", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("secret_refs", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "(change_kind='update' AND rollback_target_version IS NULL) OR (ch"
            "ange_kind='rollback' AND rollback_target_version IS NOT NULL AND "
            "rollback_target_version >= 0 AND rollback_target_version < versio"
            "n)",
            name="ck_configuration_rollback_target",
        ),
        sa.CheckConstraint(
            "(jsonb_typeof(secret_refs->'ocr_api_key')='null' OR (jsonb_typeof"
            "(secret_refs->'ocr_api_key')='string' AND secret_refs->>'ocr_api_"
            "key' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]"
            "{12}$')) AND (jsonb_typeof(secret_refs->'ai_api_key')='null' OR ("
            "jsonb_typeof(secret_refs->'ai_api_key')='string' AND secret_refs-"
            ">>'ai_api_key' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4"
            "}-[0-9a-f]{12}$'))",
            name="ck_configuration_revision_secret_uuids",
        ),
        sa.CheckConstraint(
            "change_kind IN ('update','rollback')", name="ck_configuration_change_kind"
        ),
        sa.CheckConstraint(
            "jsonb_typeof(public_values)='object' AND public_values ?& ARRAY['"
            "registration_enabled','invitation_default_days','attachment_max_b"
            "ytes','per_user_attachment_quota_bytes','orphan_retention_days','"
            "diagnostics_enabled','worker_poll_seconds','backup_retention_days"
            "','ocr_provider','ai_provider']::text[] AND public_values - ARRAY"
            "['registration_enabled','invitation_default_days','attachment_max"
            "_bytes','per_user_attachment_quota_bytes','orphan_retention_days'"
            ",'diagnostics_enabled','worker_poll_seconds','backup_retention_da"
            "ys','ocr_provider','ai_provider']::text[] = '{}'::jsonb",
            name="ck_configuration_revision_public_keys",
        ),
        sa.CheckConstraint(
            "jsonb_typeof(secret_refs)='object' AND secret_refs ?& ARRAY['ocr_"
            "api_key','ai_api_key']::text[] AND secret_refs - ARRAY['ocr_api_k"
            "ey','ai_api_key']::text[] = '{}'::jsonb",
            name="ck_configuration_revision_secret_keys",
        ),
        sa.CheckConstraint("request_hash ~ '^[0-9a-f]{64}$'", name="ck_configuration_request_hash"),
        sa.CheckConstraint(
            "version >= 1 AND base_version >= 0 AND base_version < version",
            name="ck_configuration_revision_versions",
        ),
        sa.ForeignKeyConstraint(
            ["actor_user_id"],
            ["users.id"],
        ),
        sa.PrimaryKeyConstraint("version"),
        sa.UniqueConstraint("request_id"),
    )
    op.create_index(
        "ix_configuration_actor_created",
        "service_configuration_revisions",
        ["actor_user_id", "created_at", "version"],
        unique=False,
    )

    op.bulk_insert(
        sa.table(
            "service_configuration",
            sa.column("id", sa.Integer()),
            sa.column("current_version", sa.BigInteger()),
            sa.column("public_values", postgresql.JSONB()),
            sa.column("secret_refs", postgresql.JSONB()),
            sa.column("updated_at", sa.DateTime(timezone=True)),
        ),
        [
            {
                "id": 1,
                "current_version": 0,
                "public_values": {
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
                },
                "secret_refs": {"ocr_api_key": None, "ai_api_key": None},
                "updated_at": datetime.now(timezone.utc),
            }
        ],
    )


def downgrade():

    op.drop_index("ix_configuration_actor_created", table_name="service_configuration_revisions")
    op.drop_table("service_configuration_revisions")
    op.drop_table("service_configuration")
