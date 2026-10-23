"""Malformed rows remain positioned errors; no arbitrary JSON is a resource."""

import pytest

from flowtrace_server.imports.parsers import canonical
from flowtrace_server.imports.staging_parsers import open_stage_source
from flowtrace_server.imports.staging_schemas import StageMapping

from .test_staging_parsers import native_row


@pytest.mark.parametrize("bad_entity", [[], {}, None, 1])
def test_malformed_native_entity_cannot_crash_reference_extraction(bad_entity):
    row = native_row()
    row["entity_type"] = bad_entity
    source = canonical({"format": "flowtrace-data-v1", "source_namespace": "bad", "rows": [row]})
    with open_stage_source(
        source, "flowtrace_json", StageMapping(), check_budget=lambda: None
    ) as data:
        result = list(data.rows)
    assert len(result) == 1 and result[0].row is None and result[0].errors
    assert result[0].requirements == () and result[0].defined_source_id is None
