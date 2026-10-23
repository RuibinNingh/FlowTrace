"""Executable fixture guards reject redirected/old targets before any connection."""

import importlib.util
import json
from pathlib import Path
from uuid import uuid4

import pytest

ENTRY = Path(__file__).resolve().parents[3] / "tests/e2e/admin/prepare_retention_fixture.py"


@pytest.fixture
def script(tmp_path, monkeypatch):
    spec = importlib.util.spec_from_file_location("retention_fixture_guard_test", ENTRY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setattr(module, "ROOT", tmp_path)
    return module


def environment(script, *, query="", port=55432, database=None, wrong_data=False):
    run = uuid4().hex
    directory = script.ROOT / "work/flowtrace-dev/postgresql"
    directory.mkdir(parents=True)
    data = script.ROOT / "work/flowtrace-dev/p5-restores" / (uuid4().hex if wrong_data else run)
    target = directory / f"server-p5-restore-{run}.env"
    database = database or f"flowtrace_test_p5_admin_{run[:16]}"
    url = f"postgresql+psycopg://synthetic:fixture@127.0.0.1:{port}/{database}{query}"
    target.write_text(
        f"FLOWTRACE_ENVIRONMENT=test\nFLOWTRACE_TEST_DATABASE_URL={url}\n"
        f"FLOWTRACE_DATA_DIRECTORY={data}\n",
        encoding="utf-8",
    )
    return target, data


@pytest.mark.parametrize(
    "bad",
    [
        "hostaddr",
        "service",
        "options",
        "prod",
        "wrong_port",
        "other_test_db",
        "wrong_data",
    ],
)
def test_environment_rejects_target_overrides_before_engine_creation(script, bad, monkeypatch):
    overrides = {
        "hostaddr": {"query": "?hostaddr=203.0.113.55"},
        "service": {"query": "?service=production"},
        "options": {"query": "?options=-csearch_path%3Dproduction"},
        "prod": {"database": "production"},
        "wrong_port": {"port": 5432},
        "other_test_db": {"database": "flowtrace_test_p5_admin_" + "f" * 16},
        "wrong_data": {"wrong_data": True},
    }
    target, _ = environment(script, **overrides[bad])

    def no_engine(*args, **kwargs):
        pytest.fail("invalid fixture attempted a database connection")

    monkeypatch.setattr(script, "build_engine", no_engine)
    with pytest.raises(ValueError):
        script.environment(target)


def test_environment_accepts_only_correlated_new_uuid_paths_without_creating_data(script):
    target, data = environment(script)
    settings, database = script.environment(target)
    assert settings.data_directory == data and not data.exists()
    assert database == "flowtrace_test_p5_admin_" + data.name[:16]


@pytest.mark.parametrize("bad", ["run_id", "duplicate_package", "good"])
def test_fixture_handle_requires_its_own_output_and_distinct_uuid_set(script, bad):
    target, data = environment(script)
    run = uuid4().hex
    credential = script.ROOT / "work/flowtrace-dev" / f"retention-{run}.json"
    credential.write_text("{}", encoding="utf-8")
    packages = {label: {"id": str(uuid4())} for label in script.LABELS}
    fixture = {
        "purpose": script.PURPOSE,
        "api_origin": script.ORIGIN,
        "expected_head": script.HEAD,
        "run_id": run,
        "env_file": str(target),
        "database": "flowtrace_test_p5_admin_" + data.name[:16],
        "data_directory": str(data),
        "credential_file": str(credential),
        "packages": packages,
        "package_directory_names": sorted(item["id"] for item in packages.values()),
    }
    output = script.ROOT / "outputs/validation/P5/admin" / f"retention-{run}" / "fixture.json"
    output.parent.mkdir(parents=True)
    if bad == "run_id":
        fixture["run_id"] = "../outside"
    elif bad == "duplicate_package":
        packages["pinned"]["id"] = packages["old_eligible"]["id"]
    output.write_text(json.dumps(fixture), encoding="utf-8")
    if bad == "good":
        actual, settings = script.load_fixture(output)
        assert actual["run_id"] == run and settings.data_directory == data
    else:
        with pytest.raises(ValueError):
            script.load_fixture(output)
