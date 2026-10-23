"""Real admin HTTP invokes the control gate inside its source read lease."""

import pytest
from admin.conftest import ORIGIN, PASSWORD, login
from admin.conftest import admin_system as admin_system
from backup_admin.conftest import backup_system as backup_system

from flowtrace_server.auth.errors import ApiError
from flowtrace_server.backups import administration, retention
from flowtrace_server.backups.leases import BackupLeaseError, backup_exclusive_lease

pytestmark = pytest.mark.postgres


@pytest.mark.parametrize("denied", [False, True])
def test_raw_download_control_gate_under_source_lease_before_archive(
    backup_system, monkeypatch, denied
):
    client, _, _, settings, identifier, directory, _, contents = backup_system
    actual_gate = retention.require_backup_readable
    actual_archive = administration._prepare_archive
    gates, copies = [], []

    def gate(session, backup_id):
        assert backup_id == identifier
        with pytest.raises(BackupLeaseError, match="backup_busy"):
            with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
                pytest.fail("download control check must own the source SH")
        result = actual_gate(session, backup_id)
        assert not result.registered  # Old packages remain readable and protected.
        gates.append(session)
        if denied:
            raise ApiError("backup_control_conflict", 409)
        return result

    def archive(*args, **kwargs):
        assert len(gates) == 1 and not gates[0].in_transaction()
        copies.append(identifier)
        return actual_archive(*args, **kwargs)

    monkeypatch.setattr(retention, "require_backup_readable", gate)
    monkeypatch.setattr(administration, "_prepare_archive", archive)
    csrf = login(client)
    response = client.post(
        f"/admin/backups/{identifier}/download",
        data={"csrf_token": csrf, "confirm_target": str(identifier), "current_password": PASSWORD},
        headers=ORIGIN,
    )
    assert response.status_code == (409 if denied else 200)
    assert len(gates) == 1 and len(copies) == (0 if denied else 1)
    assert all((directory / name).read_bytes() == raw for name, raw in contents.items())
    with backup_exclusive_lease(settings, (identifier,), timeout_seconds=0):
        pass
