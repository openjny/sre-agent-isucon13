"""Output helpers for consistent CLI messaging."""

from __future__ import annotations

import json
import sys


def die(msg: str) -> None:
    print(f"❌ {msg}", file=sys.stderr)
    sys.exit(1)


def ok(msg: str) -> None:
    print(f"✅ {msg}")


def print_json(data: dict | list | str) -> None:
    if isinstance(data, (dict, list)):
        print(json.dumps(data, indent=2, ensure_ascii=False))
    else:
        print(data)
