"""Closed destructive-action forms and the actual confirmation template."""

import re
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
from starlette.datastructures import FormData

from flowtrace_server.admin import quarantine_pages
from flowtrace_server.admin.router import templates
from flowtrace_server.auth.errors import ApiError

PASSWORD = "Synthetic-quarantine-password-2026"


def form(preview_id):
    return [
        ("csrf_token", "synthetic-csrf"),
        ("request_id", str(uuid4())),
        ("selection_sha256", "a" * 64),
        ("current_password", PASSWORD),
        ("confirm_target", str(preview_id)),
    ]


@pytest.mark.parametrize(
    "mutation",
    ["duplicate", "extra_path", "missing_confirm", "wrong_target", "bad_hash", "bad_uuid"],
)
def test_submission_rejects_ambiguous_or_changed_confirmation(mutation):
    preview_id = uuid4()
    items = form(preview_id)
    if mutation == "duplicate":
        items.append(("request_id", str(uuid4())))
    elif mutation == "extra_path":
        items.append(("directory", "C:/private-sentinel"))
    elif mutation == "missing_confirm":
        items = [(key, value) for key, value in items if key != "confirm_target"]
    else:
        key, replacement = {
            "wrong_target": ("confirm_target", str(uuid4())),
            "bad_hash": ("selection_sha256", "A" * 64),
            "bad_uuid": ("request_id", "not-an-identity"),
        }[mutation]
        items = [(name, replacement if name == key else value) for name, value in items]
    with pytest.raises(ApiError) as error:
        quarantine_pages.parse_submission(FormData(items), preview_id)
    assert PASSWORD not in str(error.value) and "private-sentinel" not in str(error.value)


def test_confirmation_form_preserves_exact_request_and_selection_without_paths():
    preview_id = uuid4()
    items = form(preview_id)
    command, password = quarantine_pages.parse_submission(FormData(items), preview_id)
    assert command.preview_id == preview_id
    assert str(command.request_id) == dict(items)["request_id"]
    assert command.selection_sha256 == "a" * 64 and password == PASSWORD


def test_actual_confirmation_template_has_blank_password_and_exact_uuid_action():
    preview_id, backup_id = uuid4(), uuid4()
    instant = datetime(2026, 10, 23, tzinfo=UTC)
    html = templates.env.get_template("pages/backup_quarantine.html").render(
        preview_id=preview_id,
        submission_request_id=uuid4(),
        selection_sha256="a" * 64,
        csrf_token="synthetic-csrf",
        expires_at=instant + timedelta(minutes=5),
        config_version=1,
        total_files=3,
        total_bytes=999,
        packages=[
            {
                "backup_id": backup_id,
                "created_at": instant,
                "control_version": 1,
                "file_count": 3,
                "size_bytes": 999,
                "manifest_sha256": "b" * 64,
            }
        ],
        error=None,
    )
    assert f'action="/admin/backups/retention/{preview_id}/quarantine"' in html
    assert str(backup_id) in html and "排队隔离这些备份" in html
    assert f'name="confirm_target" value="{preview_id}" required' in html
    assert "没有网页恢复或永久销毁入口" in html
    for tag in re.findall(r'<input[^>]+type="password"[^>]*>', html):
        assert not re.search(r"\bvalue\s*=", tag)
    assert PASSWORD not in html and "postgresql" not in html
