import json
import multiprocessing
from datetime import UTC, datetime, timedelta
from uuid import uuid4

from flowtrace_server.diagnostics import safe_payload
from flowtrace_server.diagnostics.store import DiagnosticStore, Limits


def append_worker(root, total, result):
    store = DiagnosticStore(root)
    result.put(
        sum(store.append({"event": "safe", "operation_id": str(uuid4())}) for _ in range(total))
    )


def test_redaction_projection_does_not_accept_tokens_bodies_or_arbitrary_text(tmp_path):
    store = DiagnosticStore(tmp_path / "logs")
    assert store.append(
        {
            "event": "http_request",
            "request_id": str(uuid4()),
            "password": "DO_NOT_EXPORT",
            "body": {"amount": "987654"},
            "route": "/api/v1/books?token=DO_NOT_EXPORT",
            "code": "DO_NOT_EXPORT",
        }
    )
    exported = store.export()
    assert b"DO_NOT_EXPORT" not in exported and b"987654" not in exported
    assert json.loads(exported.splitlines()[0])["sanitized"] is True
    assert "route" not in json.loads(exported.splitlines()[1])
    assert (
        safe_payload({"event": ["invalid"], "method": {}, "code": {}})["event"] == "record_omitted"
    )


def test_rotation_retention_and_total_cap_preserve_complete_json_records(tmp_path):
    limits = Limits(file_bytes=512, total_bytes=1536, record_bytes=256, export_bytes=1024)
    store = DiagnosticStore(tmp_path / "logs", limits)
    stamp = datetime(2026, 10, 21, tzinfo=UTC)
    stranger = store.root / "personal-notes.txt"
    stranger.write_text("never remove", encoding="utf-8")
    assert store.append({"event": "safe"}, stamp - timedelta(days=10))
    for _ in range(40):
        assert store.append({"event": "safe", "operation_id": str(uuid4())}, stamp)
    assert sum(size for _, _, size in store.managed()) <= limits.total_bytes
    for _, path, size in store.managed():
        assert size <= limits.file_bytes
        assert "2026-10-11" not in path.name
        for line in path.read_bytes().splitlines():
            assert isinstance(json.loads(line), dict)
    assert stranger.read_text(encoding="utf-8") == "never remove"
    assert len(store.export()) <= limits.export_bytes


def test_export_projects_again_instead_of_returning_existing_bytes(tmp_path):
    store = DiagnosticStore(tmp_path / "logs")
    assert store.append({"event": "safe"})
    path = store.managed()[0][1]
    with path.open("ab") as stream:
        stream.write(
            json.dumps(
                {"timestamp": datetime.now(UTC).isoformat(), "event": "safe", "password": "LEAK_ME"}
            ).encode()
            + b"\n"
        )
    assert b"LEAK_ME" not in store.export()


def test_noncritical_write_failure_is_safe_and_rate_limited(tmp_path, monkeypatch, capsys):
    store = DiagnosticStore(tmp_path / "logs")
    monkeypatch.setattr(DiagnosticStore, "_last_notice", float("-inf"))
    monkeypatch.setattr(
        store, "_clean", lambda *_: (_ for _ in ()).throw(OSError("SENSITIVE_PATH"))
    )
    assert not store.append({"event": "safe"})
    assert not store.append({"event": "safe"})
    error = capsys.readouterr().err
    assert error.count("diagnostic_unavailable") == 1
    assert "SENSITIVE_PATH" not in error


def test_lock_wait_is_bounded(tmp_path):
    store = DiagnosticStore(tmp_path / "logs", Limits(lock_seconds=0.02))
    with store.locked():
        assert store.append({"event": "safe"}) is False


def test_multiprocess_append_keeps_every_record_parseable(tmp_path):
    context = multiprocessing.get_context("spawn")
    result = context.Queue()
    processes = [
        context.Process(target=append_worker, args=(tmp_path / "logs", 20, result))
        for _ in range(3)
    ]
    for process in processes:
        process.start()
    for process in processes:
        process.join(20)
        assert process.exitcode == 0
    assert sum(result.get(timeout=1) for _ in processes) == 60
    exported = DiagnosticStore(tmp_path / "logs").export().splitlines()
    assert len(exported) == 61
    assert len({json.loads(line)["operation_id"] for line in exported[1:]}) == 60


def test_export_and_cleanup_never_follow_links_or_manage_unknown_files(tmp_path):
    store = DiagnosticStore(tmp_path / "logs")
    outside = tmp_path / "private-config.txt"
    outside.write_bytes(b"DO_NOT_EXPORT_OR_DELETE")
    name = store.root / ("flowtrace-" + datetime.now(UTC).date().isoformat() + ".jsonl")
    try:
        name.symlink_to(outside)
    except OSError:
        name.hardlink_to(outside)
    assert b"DO_NOT_EXPORT_OR_DELETE" not in store.export()
    assert store.append({"event": "safe"}) is False
    assert outside.read_bytes() == b"DO_NOT_EXPORT_OR_DELETE"
