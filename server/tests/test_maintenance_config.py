"""Operator maintenance preserves configured TLS transport requirements."""

import pytest

from flowtrace_server.config import Settings
from flowtrace_server.persistence.maintenance import MaintenanceLease


class Connection:
    def __init__(self):
        self.closed = False

    def execute(self, *args):
        return self

    def fetchall(self):
        return []

    def close(self):
        self.closed = True


def test_maintenance_passes_explicit_tls_requirements(monkeypatch):
    connection, received = Connection(), {}

    def connect(**kwargs):
        received.update(kwargs)
        return connection

    monkeypatch.setattr("flowtrace_server.persistence.maintenance.psycopg.connect", connect)
    settings = Settings(
        _env_file=None,
        database_url="postgresql+psycopg://fixture@127.0.0.1/test"
        "?sslmode=verify-full&sslrootcert=C%3A%2Ffixture%2Fca.pem&channel_binding=require",
    )
    with MaintenanceLease(settings):
        assert received["sslmode"] == "verify-full"
        assert received["sslrootcert"] == "C:/fixture/ca.pem"
        assert received["channel_binding"] == "require"
        assert not connection.closed
    assert connection.closed


def test_maintenance_rejects_unsupported_connection_option_without_native_error(monkeypatch):
    def unexpected(**kwargs):
        raise AssertionError("connection must not be attempted")

    monkeypatch.setattr("flowtrace_server.persistence.maintenance.psycopg.connect", unexpected)
    settings = Settings(
        _env_file=None,
        database_url="postgresql+psycopg://fixture@127.0.0.1/test?unknown_option=private-value",
    )
    with pytest.raises(RuntimeError, match="^maintenance_window_unavailable$") as error:
        with MaintenanceLease(settings):
            pass
    assert "private-value" not in str(error.value)
