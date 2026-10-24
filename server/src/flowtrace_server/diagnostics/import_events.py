"""Log validation outcomes, never a financial commit or private source text."""

from . import event
from .import_codes import IMPORT_CODES


def record_import_check(format_name, errors, *, count=0, stage_id=None, error_count=None):
    errors = errors if isinstance(errors, (list, tuple)) else ()
    first = next((item for item in errors if isinstance(item, dict)), {})
    code = first.get("code") if errors else "import_parse_ok"
    if not isinstance(code, str) or code not in IMPORT_CODES:
        code = "import_parse_invalid"
    event(
        "import_parse_checked",
        format=format_name,
        code=code,
        count=count,
        error_count=len(errors) if error_count is None else error_count,
        row=first.get("row"),
        field=first.get("field"),
        stage_id=stage_id,
    )
