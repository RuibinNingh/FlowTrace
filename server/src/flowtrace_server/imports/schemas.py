from typing import Annotated, Literal

from pydantic import Field, StringConstraints, model_validator

from flowtrace_server.domain.money import parse_minor
from flowtrace_server.sync.schemas import PAYLOAD_TYPES, ClosedModel, Identifier, SignedMinor


def _payload_schema():
    # Preserve raw field presence in the Python dict, while still exporting the
    # real closed payload alternatives instead of an unconstrained JSON object.
    from copy import deepcopy

    def inline(value, definitions):
        if isinstance(value, list):
            return [inline(v, definitions) for v in value]
        if not isinstance(value, dict):
            return value
        if "$ref" in value:
            name = value["$ref"].removeprefix("#/$defs/")
            return inline(deepcopy(definitions[name]), definitions)
        return {k: inline(v, definitions) for k, v in value.items() if k != "$defs"}

    variants = []
    for model in PAYLOAD_TYPES.values():
        schema = model.model_json_schema(mode="validation")
        variants.append(inline(schema, schema.get("$defs", {})))
    return {"anyOf": variants}


class ImportRow(ClosedModel):
    source_id: Identifier
    entity_type: Literal["book", "account", "category", "tag", "bill", "budget"]
    scope_id: Identifier
    payload: dict = Field(json_schema_extra=_payload_schema())

    @model_validator(mode="after")
    def closed_payload(self):
        PAYLOAD_TYPES[self.entity_type].model_validate(self.payload)
        if self.entity_type == "bill" and self.payload.get("preserve_hidden_financial_links"):
            raise ValueError("import_requires_complete_financial_links")
        return self


class HistoricalPosting(ClosedModel):
    signed_principal_minor: SignedMinor


class ImportDocument(ClosedModel):
    format: Literal["flowtrace-data-v1"]
    source_namespace: Annotated[str, StringConstraints(min_length=1, max_length=80)]
    rows: list[ImportRow] = Field(min_length=1, max_length=50)
    posting_hints: dict[Identifier, HistoricalPosting] = Field(default_factory=dict, max_length=50)

    @model_validator(mode="after")
    def unique_sources(self):
        ids = [row.source_id for row in self.rows]
        if len(ids) != len(set(ids)):
            raise ValueError("duplicate_source_id")
        by_source = {row.source_id: row for row in self.rows}
        for identifier, hint in self.posting_hints.items():
            row = by_source.get(identifier)
            if (
                row is None
                or row.entity_type != "bill"
                or row.payload.get("bill_type") != "balance_adjustment"
            ):
                raise ValueError("historical_posting_requires_adjustment")
            signed = parse_minor(hint.signed_principal_minor)
            if signed == 0 or abs(signed) != parse_minor(row.payload["money"]["amount_minor"]):
                raise ValueError("historical_posting_amount_mismatch")
        return self


class ImportRequest(ClosedModel):
    batch_id: Identifier
    client_id: Identifier
    sync_epoch: Identifier
    document: ImportDocument
    scope_mapping: dict[Identifier, Identifier] = Field(default_factory=dict, max_length=100)
    resource_mapping: dict[Identifier, Identifier] = Field(default_factory=dict, max_length=100)
    attachment_transfers: dict[Identifier, Identifier] = Field(default_factory=dict, max_length=100)


class UndoRequest(ClosedModel):
    client_id: Identifier
    sync_epoch: Identifier
