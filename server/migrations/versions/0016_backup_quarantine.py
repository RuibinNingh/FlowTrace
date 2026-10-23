"""Allow the independent, controlled backup quarantine job kind.

No rows are rewritten and no file operation runs during this migration.
Downgrade deliberately fails if quarantine jobs remain, retaining their
immutable intents and recovery evidence instead of deleting them.
"""

from alembic import op

revision = "0016_backup_quarantine"
down_revision = "0015_import_requirements"
branch_labels = None
depends_on = None

_PREVIOUS = (
    "kind IN ('recurring_occurrence','installment_occurrence','import_preview',"
    "'import_apply','export','backup_create','backup_verify','restore_rehearsal')"
)
_CURRENT = (
    "kind IN ('recurring_occurrence','installment_occurrence','import_preview',"
    "'import_apply','export','backup_create','backup_verify','restore_rehearsal',"
    "'backup_quarantine')"
)


def upgrade():
    op.drop_constraint("ck_job_kind", "background_jobs", type_="check")
    op.create_check_constraint("ck_job_kind", "background_jobs", _CURRENT)


def downgrade():
    op.drop_constraint("ck_job_kind", "background_jobs", type_="check")
    op.create_check_constraint("ck_job_kind", "background_jobs", _PREVIOUS)
