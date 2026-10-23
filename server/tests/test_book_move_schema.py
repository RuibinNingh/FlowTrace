"""Wire-level migration intent stays explicit and closed."""

from copy import deepcopy
from uuid import uuid4

import pytest
from pydantic import ValidationError

from flowtrace_server.sync.canonical import content_hash
from flowtrace_server.sync.schemas import Operation


def command():
    source, target = str(uuid4()), str(uuid4())
    return {
        "operation_id": str(uuid4()),
        "scope_id": source,
        "entity_type": "bill",
        "entity_id": str(uuid4()),
        "action": "update",
        "base_revision": "1",
        "depends_on": None,
        "move": {"target_scope_id": target, "attachment_replacements": []},
        "payload": {
            "bill_type": "expense",
            "book_id": target,
            "money": {"currency": "CNY", "currency_scale": 2, "amount_minor": "100"},
            "business_date": "2026-10-21",
            "business_timezone": "Asia/Shanghai",
        },
    }


def test_closed_marker_preserves_raw_and_original_null_hash_boundary():
    raw = command()
    unchanged = deepcopy(raw)
    parsed = Operation.model_validate(raw)
    assert parsed.move.target_scope_id == raw["payload"]["book_id"]
    assert raw == unchanged
    ordinary = {key: value for key, value in raw.items() if key != "move"}
    ordinary["payload"]["book_id"] = ordinary["scope_id"]
    assert Operation.model_validate(ordinary).move is None
    assert content_hash(ordinary) != content_hash({**ordinary, "move": None})


@pytest.mark.parametrize(
    "mutate",
    [
        lambda item: item.update(action="create", base_revision="0"),
        lambda item: item.update(base_revision="0"),
        lambda item: item.update(action="delete", payload={}),
        lambda item: item["move"].update(target_scope_id=item["scope_id"]),
        lambda item: item["payload"].update(book_id=str(uuid4())),
        lambda item: item["payload"].update(preserve_hidden_financial_links=True),
        lambda item: item["move"].update(unrecognized=True),
        lambda item: item["move"].pop("attachment_replacements"),
        lambda item: item["payload"].update(attachment_ids=[str(uuid4())]),
    ],
)
def test_invalid_move_intents_rejected_before_database(mutate):
    item = command()
    mutate(item)
    with pytest.raises(ValidationError):
        Operation.model_validate(item)


@pytest.mark.parametrize("invalid", ["same_id", "duplicate_source", "duplicate_target", "overlap"])
def test_attachment_mapping_is_bijective_and_requires_new_identifiers(invalid):
    item = command()
    source, target, third = (str(uuid4()) for _ in range(3))
    pairs = {
        "same_id": [(source, source)],
        "duplicate_source": [(source, target), (source, third)],
        "duplicate_target": [(source, target), (third, target)],
        "overlap": [(source, target), (target, third)],
    }[invalid]
    item["move"]["attachment_replacements"] = [
        {"source_id": old, "target_id": new} for old, new in pairs
    ]
    item["payload"]["attachment_ids"] = [new for _, new in pairs]
    with pytest.raises(ValidationError):
        Operation.model_validate(item)
