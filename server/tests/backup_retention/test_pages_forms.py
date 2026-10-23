"""Closed management forms and actual templates, before router integration."""

import re
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
from starlette.datastructures import FormData

from flowtrace_server.admin import retention_pages as pages
from flowtrace_server.admin.router import templates
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.backups.retention_schemas import RetentionPreviewRecord

PASSWORD = "Synthetic-page-password-sentinel-2026"


def preview_form(identities):
    request_id = uuid4()
    return FormData([
        ("csrf_token", "synthetic-csrf"), ("request_id", str(request_id)),
        ("expected_config_version", "0"), ("current_password", PASSWORD),
        ("confirm_target", str(request_id)),
        *(("backup_ids", str(value)) for value in identities),
    ])


def test_exact_twenty_uuid_selection_sorts_without_changing_set_or_money():
    identifiers = [uuid4() for _ in range(20)]
    selection, password = pages.parse_preview(preview_form(identifiers))
    assert selection.backup_ids == tuple(sorted(identifiers, key=str))
    assert selection.expected_config_version == 0 and password == PASSWORD


@pytest.mark.parametrize("mutation", [
    "none", "too_many", "duplicate_id", "duplicate_password", "duplicate_config",
    "extra_url", "uppercase_uuid", "bad_confirm", "negative", "float", "leading_zero",
    "overflow", "short_password",
])
def test_preview_form_rejects_nonclosed_or_ambiguous_selection(mutation):
    identities = [uuid4(), uuid4()]
    items = list(preview_form(identities).multi_items())
    if mutation == "none":
        items = [(key, value) for key, value in items if key != "backup_ids"]
    elif mutation == "too_many":
        items.extend(("backup_ids", str(uuid4())) for _ in range(19))
    elif mutation == "duplicate_id":
        items.append(("backup_ids", str(identities[0])))
    elif mutation == "duplicate_password":
        items.append(("current_password", PASSWORD))
    elif mutation == "duplicate_config":
        items.append(("expected_config_version", "0"))
    elif mutation == "extra_url":
        items.append(("endpoint", "https://private-sentinel.invalid"))
    else:
        key, value = {
            "uppercase_uuid": ("backup_ids", str(uuid4()).upper()),
            "bad_confirm": ("confirm_target", str(uuid4())),
            "negative": ("expected_config_version", "-1"),
            "float": ("expected_config_version", "1.0"),
            "leading_zero": ("expected_config_version", "00"),
            "overflow": ("expected_config_version", str(2**63)),
            "short_password": ("current_password", "short"),
        }[mutation]
        items = [(name, value if name == key else item) for name, item in items]
    with pytest.raises(ApiError) as caught:
        pages.parse_preview(FormData(items))
    assert PASSWORD not in str(caught.value)
    assert "private-sentinel" not in str(caught.value)


def test_registration_pins_are_bound_to_canonical_target_and_cas():
    backup_id, pin_id = uuid4(), uuid4()
    registration = pages.parse_registration(FormData({
        "csrf_token": "synthetic", "confirm_target": str(backup_id),
        "expected_manifest_sha256": "a" * 64, "expected_instance": str(uuid4()),
        "expected_epoch": str(uuid4()), "current_password": PASSWORD,
    }), backup_id)
    assert registration.backup_id == backup_id and PASSWORD not in repr(registration)
    create, password = pages.parse_pin_create(FormData({
        "csrf_token": "synthetic", "confirm_target": str(backup_id),
        "pin_id": str(pin_id), "request_id": str(uuid4()),
        "expected_control_version": "12", "current_password": PASSWORD,
    }), backup_id)
    assert create.backup_id == backup_id and create.expected_control_version == 12
    assert password == PASSWORD
    release_form = FormData({
        "csrf_token": "synthetic", "confirm_target": str(pin_id),
        "request_id": str(uuid4()), "expected_control_version": "13",
        "expected_pin_version": "1", "current_password": PASSWORD,
    })
    release, _ = pages.parse_pin_release(release_form, pin_id)
    assert release.pin_id == pin_id and release.expected_pin_version == 1
    with pytest.raises(ApiError, match="confirmation_invalid"):
        pages.parse_pin_release(release_form, uuid4())


def render(page, **data):
    return templates.env.get_template("panel.html").render(
        page=page, csrf_token="synthetic-csrf", can_service=False, can_recovery=True,
        error=None, notice=None, **data,
    )


def assert_no_destructive_form_or_password_echo(html):
    for action in re.findall(r'<form[^>]+action="([^"]+)"', html):
        assert "quarantine" not in action and "purge" not in action and "delete" not in action
    for tag in re.findall(r'<input[^>]+type="password"[^>]*>', html):
        assert not re.search(r'\bvalue\s*=', tag)
    assert PASSWORD not in html and "postgresql" not in html


def test_catalog_template_disables_protected_uuid_and_lists_fixed_reason():
    eligible, protected = uuid4(), uuid4()
    items = [{
        "backup_id": identity, "eligible": valid, "created_at": datetime.now(UTC),
        "control_version": 2, "state": "available", "size_bytes": 123, "file_count": 3,
        "protection_reasons": () if valid else ("pinned", "restore_intent"),
    } for identity, valid in ((eligible, True), (protected, False))]
    html = render(
        "backup_retention", items=items, retention_days=30, config_version=0,
        request_id=uuid4(), reason_labels=pages.REASON_LABELS, state_labels=pages.STATE_LABELS,
        has_more=False,
    )
    checkboxes = re.findall(r'<input[^>]+name="backup_ids"[^>]*>', html)
    assert len(checkboxes) == 2
    assert "disabled" not in checkboxes[0] and "disabled" in checkboxes[1]
    assert "恢复意图永久保留来源" in html and "不会自动删除文件" in html
    assert_no_destructive_form_or_password_echo(html)


def test_registration_and_pin_templates_use_fixed_target_and_empty_passwords():
    identifier, pin_id = uuid4(), uuid4()
    html = render(
        "backup_retention_register", can_register=True, already_registered=False,
        source_instance=uuid4(), source_epoch=uuid4(), target={
            "backup_id": identifier, "state": "manifest_available", "declared_bytes": 123,
            "file_count": 3, "manifest_sha256": "a" * 64, "created_at": None,
        },
    )
    assert f'action="/admin/backups/{identifier}/register"' in html
    assert_no_destructive_form_or_password_echo(html)
    html = render(
        "backup_retention_protection", target_id=identifier, control_version=2,
        state="可读", mutable=True, pin_id=uuid4(), request_id=uuid4(), has_more=False,
        pins=[{
            "pin_id": pin_id, "version": 1, "created_at": datetime.now(UTC),
            "created_by": uuid4(), "release_request_id": uuid4(),
        }],
    )
    assert f'action="/admin/backups/{identifier}/pins/{pin_id}/release"' in html
    assert_no_destructive_form_or_password_echo(html)


def test_authorized_preview_projection_excludes_origin_session_and_has_no_action():
    stamp = datetime.now(UTC)
    record = RetentionPreviewRecord(
        preview_id=uuid4(), actor_id=uuid4(), session_id=uuid4(), request_id=uuid4(),
        config_version=0, source_instance_id=uuid4(), source_epoch=uuid4(), retention_days=30,
        cutoff=stamp - timedelta(days=30), issued_at=stamp,
        expires_at=stamp + timedelta(seconds=300),
        selection_sha256="b" * 64, packages=({
            "backup_id": uuid4(), "control_version": 1, "manifest_sha256": "a" * 64,
            "tree_sha256": "c" * 64, "created_at": stamp - timedelta(days=40),
            "size_bytes": 123, "file_count": 3, "instance_id": uuid4(), "sync_epoch": uuid4(),
        },),
    )
    data = pages.preview_data(record)
    assert "session_id" not in data and "actor_id" not in data and "source_epoch" not in data
    html = render("backup_retention_preview", **data)
    assert str(record.session_id) not in html and "零删除预览报告" in html
    # The common navigation has only logout. There is no follow-on file effect.
    assert re.findall(r'<form[^>]+action="([^"]+)"', html) == ["/admin/logout"]
    assert_no_destructive_form_or_password_echo(html)
