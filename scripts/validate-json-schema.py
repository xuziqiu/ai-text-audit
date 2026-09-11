import json
import sys
from decimal import Decimal
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: validate-json-schema.py <instance.json> <schema.json>", file=sys.stderr)
        return 2

    try:
        from jsonschema import Draft202012Validator, FormatChecker
    except ImportError:
        print(
            "Python package 'jsonschema' is required for XZQ text audit schema validation.",
            file=sys.stderr,
        )
        return 3

    instance_path = Path(sys.argv[1])
    schema_path = Path(sys.argv[2])

    try:
        instance = json.loads(instance_path.read_text(encoding="utf-8"), parse_float=Decimal)
        schema = json.loads(schema_path.read_text(encoding="utf-8"), parse_float=Decimal)
    except (OSError, json.JSONDecodeError) as exc:
        print(str(exc), file=sys.stderr)
        return 4

    try:
        Draft202012Validator.check_schema(schema)
        validator = Draft202012Validator(schema, format_checker=FormatChecker())
        errors = sorted(validator.iter_errors(instance), key=lambda item: list(item.path))
    except Exception as exc:
        print(f"schema validation setup failed: {exc}", file=sys.stderr)
        return 5

    if not errors:
        return 0

    for error in errors:
        location = "/".join(str(part) for part in error.path) or "<root>"
        print(f"{location}: {error.message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
