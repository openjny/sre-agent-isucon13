"""Memory commands."""

from __future__ import annotations

import argparse
import os

from srectl.client import api_request, build_multipart, get_ctx
from srectl.output import die, ok


def cmd_memory_list(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(endpoint, token, "GET", "/api/v1/AgentMemory/files")
    if code != 200:
        die(f"HTTP {code}")
    files = data.get("files", []) if isinstance(data, dict) else []
    if not files:
        print("(no files)")
        return
    for f in files:
        status = "✅" if f.get("isIndexed") else "⏳"
        error = f" ( {f.get('errorReason')} )" if not f.get("isIndexed") else ""
        print(f"  {status} {f['name']}{error}")


def cmd_memory_add(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    file_tuples: list[tuple[str, str, bytes]] = []
    for path in args.files:
        if not os.path.isfile(path):
            die(f"File not found: {path}")
        with open(path, "rb") as f:
            file_tuples.append(("files", os.path.basename(path), f.read()))
    if not file_tuples:
        die("No files specified")

    body_bytes, content_type = build_multipart(file_tuples, {"triggerIndexing": "true"})
    code, data = api_request(
        endpoint,
        token,
        "POST",
        "/api/v1/AgentMemory/upload",
        raw_body=body_bytes,
        content_type=content_type,
    )
    if code in (200, 201):
        ok(f"uploaded {len(file_tuples)} file(s)")
    else:
        die(f"upload: HTTP {code} — {data}")
