"""Static migration-review checks, deliberately not PostgreSQL behavior claims.

The explicit candidate is not imported by registry or installed at runtime.
Root must freeze it into a migration and test real SQL before claiming a DB guard.
"""

import re
from pathlib import Path

import pytest

from flowtrace_server.backups.retention_models import BackupHold, BackupPin

FIXTURES = Path(__file__).parent / "fixtures"
UP = (FIXTURES / "0013_retention_lifecycle_candidate.sql").read_text(encoding="utf-8")
DOWN = (FIXTURES / "0013_retention_lifecycle_candidate_down.sql").read_text(encoding="utf-8")


def function_body(name):
    return re.search(
        rf"CREATE FUNCTION public\.{name}\(\).*?AS \$guard\$(.*?)\$guard\$;", UP, re.S
    ).group(1)


def test_candidate_guards_cover_row_changes_and_truncation_without_file_or_table_effects():
    functions = re.findall(r"CREATE FUNCTION public\.(\w+)\(\)", UP)
    assert len(functions) == len(set(functions)) == 4
    assert UP.count("SECURITY INVOKER") == UP.count("SET search_path = pg_catalog") == 4
    assert "SECURITY DEFINER" not in UP
    assert not re.search(r"\b(?:CASCADE|DROP|TRUNCATE TABLE|DELETE FROM|UPDATE public\.)\b", UP)
    for table, row_guard in (
        ("backup_retention_intents", "UPDATE OR DELETE"),
        ("backup_pins", "INSERT OR UPDATE OR DELETE"),
        ("backup_holds", "INSERT OR UPDATE OR DELETE"),
    ):
        assert f"BEFORE {row_guard} ON public.{table}\nFOR EACH ROW" in UP
        assert f"BEFORE TRUNCATE ON public.{table}\nFOR EACH STATEMENT" in UP
    assert len(re.findall(r"CREATE TRIGGER \w+", UP)) == 6


@pytest.mark.parametrize(
    ("kind", "model", "mutable"),
    (
        (
            "pin",
            BackupPin,
            {
                "version",
                "released_at",
                "released_by",
                "release_request_id",
                "release_request_hash",
            },
        ),
        ("hold", BackupHold, {"version", "released_at", "release_proof"}),
    ),
)
def test_release_has_one_transition_and_null_safe_identity_comparison(kind, model, mutable):
    body = function_body(f"flowtrace_backup_{kind}_lifecycle")
    assert "IF TG_OP = 'INSERT' THEN" in body
    assert "ELSIF TG_OP = 'UPDATE' THEN" in body
    assert body.count("NEW.version IS DISTINCT FROM 1") == 1
    assert body.count("OLD.version IS DISTINCT FROM 1") == 1
    assert body.count("NEW.version IS DISTINCT FROM 2") == 1
    assert body.count("IS DISTINCT FROM (to_jsonb(OLD)") == 1
    arrays = re.findall(r"to_jsonb\((NEW|OLD)\) - ARRAY\[(.*?)\]::text\[\]", body, re.S)
    assert [record for record, _ in arrays] == ["NEW", "OLD"]
    assert all(set(re.findall(r"'([a-z_]+)'", values)) == mutable for _, values in arrays)
    columns = set(model.__table__.columns.keys())
    assert mutable < columns
    assert {"id", "backup_id", "created_at"} <= columns - mutable
    # Removing only mutable keys protects the remaining whole row, including
    # future added columns. A nullable immutable field is not lost to SQL '='.
    for field in mutable - {"version"}:
        assert f"NEW.{field} IS NOT NULL" in body  # INSERT rejects a released row.
        assert f"OLD.{field} IS NOT NULL" in body  # UPDATE requires the original active row.
        assert f"NEW.{field} IS NULL" in body  # Release requires complete proof.
    assert f"MESSAGE = 'backup_{kind}_immutable'" in body
    assert "RETURN OLD" not in body


def test_intent_and_truncate_rejections_use_fixed_non_sensitive_errors():
    for name, message in (
        ("flowtrace_backup_intent_immutable", "backup_retention_intent_immutable"),
        ("flowtrace_backup_protection_truncate_rejected", "backup_protection_truncate_rejected"),
    ):
        body = function_body(name)
        assert f"ERRCODE = '55000', MESSAGE = '{message}'" in body
        assert not re.search(r"\b(?:NEW|OLD|TG_ARGV|EXECUTE|RETURN)\b", body)


def test_downgrade_removes_exact_triggers_before_exact_functions_and_preserves_tables():
    installed = set(re.findall(r"CREATE TRIGGER (\w+).*? ON public\.(\w+)\n", UP, re.S))
    removed = set(re.findall(r"DROP TRIGGER (\w+) ON public\.(\w+);", DOWN))
    assert removed == installed
    created = set(re.findall(r"CREATE FUNCTION public\.(\w+)\(\)", UP))
    dropped = set(re.findall(r"DROP FUNCTION public\.(\w+)\(\);", DOWN))
    assert created == dropped
    assert DOWN.rfind("DROP TRIGGER") < DOWN.find("DROP FUNCTION")
    assert not re.search(r"\b(?:CASCADE|DROP TABLE|TRUNCATE|DELETE|UPDATE|INSERT)\b", DOWN)
