"""Real facade/CAS/metadata with synthetic packages; routes tested separately."""

import hashlib
from datetime import timedelta
from time import monotonic
from uuid import uuid4

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from starlette.datastructures import FormData

from flowtrace_server.admin import retention_pages as pages
from flowtrace_server.admin.models import AdminAudit
from flowtrace_server.auth.errors import ApiError
from flowtrace_server.auth.service import now
from flowtrace_server.backups import retention
from flowtrace_server.backups.leases import backup_exclusive_lease
from flowtrace_server.backups.retention_models import BackupControl, BackupPin
from flowtrace_server.backups.retention_schemas import PinCreateCommand
from flowtrace_server.imports.parsers import canonical

from .test_job_references_pg import PASSWORD
from .test_job_references_pg import reference_case as reference_case
from .test_retention_io import package, snapshot

pytestmark = pytest.mark.postgres


def unregistered(case, *, age_days=0):
    with Session(case.engine) as session:
        instance, epoch = retention._source(session)
    return package(
        case.settings, instance=instance, epoch=epoch, created_at=now() - timedelta(days=age_days)
    )


def register(case, *, age_days=0):
    identifier, root, manifest = unregistered(case, age_days=age_days)
    with retention.prepare_registration(case.settings, identifier) as prepared:
        with Session(case.engine) as session:
            retention.register_verified_backup(
                session, case.owner, case.settings, prepared=prepared, password=PASSWORD
            )
            session.commit()
    return identifier, root, manifest


def command(view):
    return pages.parse_registration(FormData({
        "csrf_token": "synthetic", "confirm_target": view["target"]["backup_id"],
        "expected_manifest_sha256": view["target"]["manifest_sha256"],
        "expected_instance": str(view["source_instance"]),
        "expected_epoch": str(view["source_epoch"]), "current_password": PASSWORD,
    }), pages.optional_cursor(view["target"]["backup_id"]))


def test_explicit_registration_three_phases_keep_source_and_end_read_transaction(reference_case):
    case = reference_case
    identifier, root, _ = unregistered(case)
    before = snapshot(root)
    with Session(case.engine) as session:
        view = pages.registration_data(session, case.owner, case.settings, identifier)
        assert view["can_register"] and not view["already_registered"]
        parsed = command(view)
        pages.precheck_registration(session, case.owner, parsed)
        session.commit()
        assert not session.in_transaction()
        with retention.prepare_registration(case.settings, identifier) as prepared:
            assert not session.in_transaction()
            result = pages.finish_registration(
                session, case.owner, case.settings, prepared=prepared, command=parsed
            )
            session.commit()
            assert result.backup_id == identifier
        assert prepared.closed
        refreshed = pages.registration_data(session, case.owner, case.settings, identifier)
        assert refreshed["already_registered"] and not refreshed["can_register"]
    assert snapshot(root) == before


def test_registration_changed_get_manifest_rejects_without_overwrite_or_control(reference_case):
    case = reference_case
    identifier, root, manifest = unregistered(case)
    with Session(case.engine) as session:
        parsed = command(pages.registration_data(session, case.owner, case.settings, identifier))
        pages.precheck_registration(session, case.owner, parsed)
        session.commit()
        changed = b'{"environment":"test","synthetic_change":true}'
        (root / "settings.json").write_bytes(changed)
        manifest["files"][0].update(
            size_bytes=len(changed), sha256=hashlib.sha256(changed).hexdigest()
        )
        (root / "manifest.json").write_bytes(canonical(manifest))
        frozen = snapshot(root)
        with retention.prepare_registration(case.settings, identifier) as prepared:
            with pytest.raises(ApiError, match="backup_package_changed"):
                pages.finish_registration(
                    session, case.owner, case.settings, prepared=prepared, command=parsed
                )
            session.rollback()
        assert session.get(BackupControl, identifier) is None
    assert snapshot(root) == frozen


def test_catalog_busy_is_immediately_protected_without_source_changes(reference_case):
    case = reference_case
    identifier, root, _ = register(case, age_days=40)
    before = snapshot(root)
    with backup_exclusive_lease(case.settings, (identifier,), timeout_seconds=0):
        started = monotonic()
        with Session(case.engine) as session:
            view = pages.catalog_data(session, case.owner, case.settings)
        elapsed = monotonic() - started
        selected = next(item for item in view["items"] if item["backup_id"] == identifier)
        assert "package_unavailable" in selected["protection_reasons"]
        assert not selected["eligible"]
        assert elapsed < 0.8
    assert snapshot(root) == before


def test_pin_actions_bind_parent_and_current_cas_and_paginate_twenty(reference_case):
    case = reference_case
    identifier, root, _ = register(case)
    before = snapshot(root)
    first_pin = None
    with Session(case.engine) as session:
        for version in range(1, 22):
            pin_id = uuid4()
            result = pages.create_pin(
                session, case.owner, command=PinCreateCommand(
                    pin_id=pin_id, backup_id=identifier, expected_control_version=version,
                    request_id=uuid4(),
                ), password=PASSWORD,
            )
            first_pin = first_pin or pin_id
            assert result["control_version"] == version + 1
        session.commit()
        view = pages.protection_data(session, case.owner, identifier)
        assert len(view["pins"]) == 20 and view["has_more"]
        after = pages.optional_cursor(view["next_url"].split("pins_after=", 1)[1])
        second = pages.protection_data(session, case.owner, identifier, pins_after=after)
        assert len(second["pins"]) == 1 and not second["has_more"]
        assert {pin["pin_id"] for pin in view["pins"]}.isdisjoint(
            pin["pin_id"] for pin in second["pins"]
        )
        release, password = pages.parse_pin_release(FormData({
            "csrf_token": "synthetic", "confirm_target": str(first_pin),
            "request_id": str(uuid4()), "expected_control_version": "21",
            "expected_pin_version": "1", "current_password": PASSWORD,
        }), first_pin)
        with pytest.raises(ApiError, match="not_found"):
            pages.release_pin(
                session, case.owner, backup_id=uuid4(), command=release, password=password
            )
        session.rollback()
        with pytest.raises(ApiError, match="backup_control_conflict"):
            pages.release_pin(
                session, case.owner, backup_id=identifier, command=release, password=password
            )
        session.rollback()
        assert session.get(BackupPin, first_pin).released_at is None
    assert snapshot(root) == before


@pytest.mark.parametrize("add_pin_after_build", [False, True])
def test_zero_delete_preview_uses_fresh_protection_and_keeps_package_bytes(
    reference_case, add_pin_after_build
):
    case = reference_case
    identifier, root, _ = register(case, age_days=40)
    _, witness_root, _ = register(case)
    before, witness_before = snapshot(root), snapshot(witness_root)
    with Session(case.engine) as session:
        view = pages.catalog_data(session, case.owner, case.settings)
        request_id = uuid4()
        selection, password = pages.parse_preview(FormData({
            "csrf_token": "synthetic", "confirm_target": str(request_id),
            "request_id": str(request_id), "backup_ids": str(identifier),
            "expected_config_version": str(view["config_version"]), "current_password": PASSWORD,
        }))
        authority = retention.precheck_retention_request(
            session, case.owner, selection=selection, password=password
        )
        session.commit()
        assert not session.in_transaction()
        with retention.build_retention_preview(case.settings, authority=authority) as prepared:
            assert not session.in_transaction()
            if add_pin_after_build:
                with Session(case.engine) as other:
                    pages.create_pin(other, case.owner, command=PinCreateCommand(
                        pin_id=uuid4(), backup_id=identifier, expected_control_version=1,
                        request_id=uuid4(),
                    ), password=PASSWORD)
                    other.commit()
                with pytest.raises(ApiError, match="backup_control_conflict"):
                    retention.authorize_retention_preview(
                        session, case.owner, case.settings, prepared=prepared, password=password
                    )
                session.rollback()
                assert session.scalar(select(func.count()).select_from(AdminAudit).where(
                    AdminAudit.action == "backup.retention_preview",
                    AdminAudit.target_id == prepared.record.preview_id,
                )) == 0
            else:
                record = retention.authorize_retention_preview(
                    session, case.owner, case.settings, prepared=prepared, password=password
                )
                session.commit()
                report = pages.preview_data(record)
                assert [item["backup_id"] for item in report["packages"]] == [identifier]
                assert "actor_id" not in report and "session_id" not in report
    assert snapshot(root) == before and snapshot(witness_root) == witness_before
