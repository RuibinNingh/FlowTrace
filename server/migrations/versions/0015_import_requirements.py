"""Persist source reference requirements without exposing financial text."""

import sqlalchemy as sa
from alembic import op

revision = "0015_import_requirements"
down_revision = "0014_import_source_release"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "import_stages",
        sa.Column("requirements_version", sa.BigInteger(), nullable=True),
    )
    op.add_column(
        "import_stages",
        sa.Column("requirements_hash", sa.String(length=64), nullable=True),
    )
    op.add_column(
        "import_stages",
        sa.Column(
            "requirements_count", sa.Integer(), server_default="0", nullable=False
        ),
    )
    op.add_column(
        "import_stage_source_releases",
        sa.Column(
            "deleted_requirement_rows", sa.Integer(), server_default="0", nullable=False
        ),
    )
    op.create_table(
        "import_stage_requirements",
        sa.Column("stage_id", sa.Uuid(), nullable=False),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.Column("parsed_version", sa.BigInteger(), nullable=False),
        sa.Column("kind", sa.String(length=16), nullable=False),
        sa.Column("source_kind", sa.String(length=16), nullable=False),
        sa.Column("source_key", sa.Text(), nullable=False),
        sa.Column("resource_type", sa.String(length=16), nullable=True),
        sa.Column("key_sha256", sa.String(length=64), nullable=False),
        sa.Column("first_line", sa.BigInteger(), nullable=False),
        sa.Column("attachment_sha256", sa.String(length=64), nullable=True),
        sa.Column("attachment_size_bytes", sa.Integer(), nullable=True),
        sa.Column("attachment_media_type", sa.String(length=16), nullable=True),
        sa.CheckConstraint(
            "(attachment_sha256 IS NULL AND attachment_size_bytes IS NULL AND attachment_media_type IS NULL) OR (kind='image' AND source_kind='identifier' AND resource_type IS NULL AND attachment_sha256 IS NOT NULL AND attachment_sha256 ~ '^[0-9a-f]{64}$' AND attachment_size_bytes IS NOT NULL AND attachment_size_bytes BETWEEN 1 AND 10485760 AND attachment_media_type IS NOT NULL AND attachment_media_type IN ('image/png','image/jpeg','image/webp'))",
            name="ck_stage_requirement_attachment",
        ),
        sa.CheckConstraint(
            "(source_kind='name' AND kind IN ('account','category','tag','image') AND resource_type IS NULL) OR (source_kind='identifier' AND kind IN ('scope','resource','image') AND source_key ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' AND ((kind='image' AND resource_type IS NULL) OR (kind='scope' AND resource_type IS NOT NULL AND resource_type IN ('book','user')) OR (kind='resource' AND resource_type IS NOT NULL AND resource_type IN ('book','account','category','tag','bill','budget','account_group'))))",
            name="ck_stage_requirement_source",
        ),
        sa.CheckConstraint(
            "char_length(source_key) BETWEEN 1 AND 2000 AND key_sha256 ~ '^[0-9a-f]{64}$'",
            name="ck_stage_requirement_key",
        ),
        sa.CheckConstraint(
            "kind IN ('account','category','tag','image','scope','resource') AND source_kind IN ('name','identifier') AND (resource_type IS NULL OR resource_type IN ('book','account','category','tag','bill','budget','account_group','user'))",
            name="ck_stage_requirement_types",
        ),
        sa.CheckConstraint(
            "position BETWEEN 1 AND 200000 AND first_line>=1 AND parsed_version BETWEEN 1 AND 2147483647",
            name="ck_stage_requirement_position",
        ),
        sa.ForeignKeyConstraint(
            ["stage_id"],
            ["import_stages.id"],
        ),
        sa.PrimaryKeyConstraint("stage_id", "position"),
        sa.UniqueConstraint(
            "stage_id", "parsed_version", "key_sha256", name="uq_stage_requirement_key"
        ),
    )
    op.create_check_constraint(
        "ck_stage_requirements",
        "import_stages",
        "requirements_count BETWEEN 0 AND 200000 AND ((requirements_version IS NULL AND requirements_hash IS NULL AND requirements_count=0) OR (requirements_version IS NOT NULL AND requirements_version BETWEEN 1 AND stage_version AND requirements_hash IS NOT NULL AND requirements_hash ~ '^[0-9a-f]{64}$'))",
    )
    op.create_check_constraint(
        "ck_stage_released_requirements",
        "import_stages",
        "source_released_at IS NULL OR (requirements_version IS NULL AND requirements_hash IS NULL AND requirements_count=0)",
    )
    op.create_check_constraint(
        "ck_source_release_requirements",
        "import_stage_source_releases",
        "deleted_requirement_rows BETWEEN 0 AND 200000",
    )


def downgrade():
    op.drop_table("import_stage_requirements")
    op.drop_constraint(
        "ck_source_release_requirements", "import_stage_source_releases", type_="check"
    )
    op.drop_constraint("ck_stage_released_requirements", "import_stages", type_="check")
    op.drop_constraint("ck_stage_requirements", "import_stages", type_="check")
    op.drop_column("import_stage_source_releases", "deleted_requirement_rows")
    op.drop_column("import_stages", "requirements_count")
    op.drop_column("import_stages", "requirements_hash")
    op.drop_column("import_stages", "requirements_version")
