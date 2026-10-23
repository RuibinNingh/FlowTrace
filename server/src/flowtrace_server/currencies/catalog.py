import json
from importlib.resources import files

_CATALOG = json.loads(files(__package__).joinpath("data/iso4217.json").read_text("utf-8"))
CURRENCY_SCALES = {row["code"]: row["scale"] for row in _CATALOG["currencies"]}


def currency_catalog() -> dict:
    return {key: value for key, value in _CATALOG.items() if key != "source_sha256"}


def supported(code: str) -> str:
    if code not in CURRENCY_SCALES:
        raise ValueError("currency_unsupported")
    return code
