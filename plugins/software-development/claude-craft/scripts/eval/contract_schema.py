#!/usr/bin/env python3
"""contract_schema.py — regenerate or check the committed JSON Schemas.

    python3 contract_schema.py            # check: exit 1 if a committed copy has drifted
    python3 contract_schema.py --write    # regenerate schemas/ from contract.py
    python3 contract_schema.py --validate report.json   # validate a document against the contract

`schemas/*.schema.json` are build artifacts of `contract.py`'s generators. They are committed so a
consumer outside this directory (a CI job, a second implementation, a reviewer) can validate a
document without importing Python — and the moment a copy is committed, it can drift from the
constants it claims to describe. This script is the regenerator; `eval.test.sh` is the gate.

Validation here is structural and dependency-free: it runs `contract.py`'s own validators, not a
JSON Schema library, because this repo's Python has no requirements file and the validators are
the authority anyway. The schema is for consumers who are not this process.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import contract

SCHEMA_DIR = Path(__file__).resolve().parent / "schemas"


def render(name: str) -> str:
    return json.dumps(contract.SCHEMAS[name](), indent=2) + "\n"


def cmd_write() -> int:
    SCHEMA_DIR.mkdir(parents=True, exist_ok=True)
    for name in contract.SCHEMAS:
        (SCHEMA_DIR / name).write_text(render(name))
        print(f"wrote {SCHEMA_DIR / name}")
    return contract.EXIT_OK


def cmd_check() -> int:
    drifted = []
    for name in contract.SCHEMAS:
        path = SCHEMA_DIR / name
        if not path.exists():
            drifted.append(f"{name}: not committed")
            continue
        if path.read_text() != render(name):
            drifted.append(f"{name}: differs from what contract.py generates now")
    if drifted:
        print("SCHEMA DRIFT:", file=sys.stderr)
        for d in drifted:
            print(f"  {d}", file=sys.stderr)
        print("\n  Fix: python3 contract_schema.py --write", file=sys.stderr)
        return contract.EXIT_MEASURED_FAIL
    print(f"OK: {len(contract.SCHEMAS)} committed schema(s) match contract.py")
    return contract.EXIT_OK


def cmd_validate(path: Path) -> int:
    try:
        doc = json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        print(f"cannot read {path}: {exc}", file=sys.stderr)
        return contract.EXIT_MISCONFIGURED
    kind = doc.get("kind") if isinstance(doc, dict) else None
    if kind == contract.KIND_TRIGGER:
        defects = contract.validate_trigger_report(doc)
    elif kind == contract.KIND_BENCHMARK:
        defects = contract.validate_benchmark_report(doc)
    else:
        print(f"unknown or missing 'kind'; expected one of {list(contract.KINDS)}", file=sys.stderr)
        return contract.EXIT_MISCONFIGURED
    if defects:
        print(f"CONTRACT DEFECTS in {path} ({kind}):", file=sys.stderr)
        for d in defects:
            print(f"  {d}", file=sys.stderr)
        return contract.EXIT_MEASURED_FAIL
    print(f"OK: {path} honours the {kind} contract")
    return contract.EXIT_OK


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--write", action="store_true", help="regenerate schemas/ from contract.py")
    ap.add_argument("--validate", metavar="FILE", help="validate a report document against the contract")
    args = ap.parse_args()
    if args.write:
        return cmd_write()
    if args.validate:
        return cmd_validate(Path(args.validate))
    return cmd_check()


if __name__ == "__main__":
    sys.exit(main())
