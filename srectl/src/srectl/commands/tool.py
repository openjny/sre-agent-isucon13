"""Tool and hook commands."""

from __future__ import annotations

import argparse
import json
import os

from srectl.client import api_request, get_ctx
from srectl.output import die, ok, print_json

# ── Tool ─────────────────────────────────────────────────────────────────────


def cmd_tool_list(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(endpoint, token, "GET", "/api/v2/agent/tools")
    if code != 200:
        die(f"HTTP {code}")
    tools = data.get("data", []) if isinstance(data, dict) else []
    if not tools:
        print("(no tools)")
        return

    source_filter = getattr(args, "source", None)
    if source_filter:
        tools = [t for t in tools if t.get("source") == source_filter]
        if not tools:
            print(f"(no {source_filter} tools)")
            return

    by_cat: dict[str, list] = {}
    for t in tools:
        cat = t.get("category") or "uncategorized"
        by_cat.setdefault(cat, []).append(t)

    for cat in sorted(by_cat):
        items = by_cat[cat]
        print(f"\n{cat} ({len(items)})")
        for t in sorted(items, key=lambda x: x["name"]):
            enabled = "on" if t.get("enabled") else "off"
            src = t.get("source", "")
            print(f"  {t['name']:45s} {src:8s} {enabled}")


def cmd_tool_add(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    name = args.name
    description = args.description

    if not os.path.isfile(args.code_file):
        die(f"File not found: {args.code_file}")
    with open(args.code_file) as f:
        code = f.read()

    params: list[dict] = []
    if args.param:
        for p in args.param:
            parts = p.split(":", 2)
            if len(parts) < 2:
                die(f"Invalid param format: {p} (expected name:type[:description])")
            param = {"name": parts[0], "type": parts[1], "required": True}
            if len(parts) >= 3:
                param["description"] = parts[2]
            params.append(param)

    body = {
        "api_version": "azuresre.ai/v1",
        "kind": "ToolList",
        "spec": {
            "tools": [
                {
                    "name": name,
                    "type": "PythonFunctionTool",
                    "description": description,
                    "function_code": code,
                    "timeout_seconds": args.timeout,
                    "parameters": params,
                }
            ],
        },
    }

    raw_body = json.dumps(body).encode()
    code_resp, data = api_request(
        endpoint,
        token,
        "PUT",
        "/api/v1/extendedAgent/apply",
        raw_body=raw_body,
        content_type="text/yaml",
    )
    if code_resp in (200, 201, 202):
        ok(f"tool/{name}")
    else:
        die(f"tool/{name}: HTTP {code_resp} — {data}")


def cmd_tool_delete(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(
        endpoint, token, "DELETE", f"/api/v1/extendedAgent/tools/{args.name}"
    )
    if code in (200, 202, 204, 404):
        ok(f"deleted tool/{args.name}")
    else:
        die(f"tool/{args.name}: HTTP {code}")


# ── Hook ─────────────────────────────────────────────────────────────────────


def cmd_hook_add(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    body = json.loads(args.json)
    name = body.get("name", args.name)
    code, data = api_request(
        endpoint, token, "PUT", f"/api/v2/extendedAgent/hooks/{name}", body=body
    )
    if code in (200, 201, 202):
        ok(f"hook/{name}")
    else:
        die(f"hook/{name}: HTTP {code} — {data}")


def cmd_hook_list(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(endpoint, token, "GET", "/api/v2/extendedAgent/hooks")
    if code != 200:
        die(f"HTTP {code}: {data}")
    hooks = (
        data.get("value", [])
        if isinstance(data, dict)
        else (data if isinstance(data, list) else [])
    )
    if not hooks:
        print("(no hooks)")
        return
    for h in hooks:
        name = h.get("name", "?")
        htype = h.get("type", "?")
        props = h.get("properties", {})
        event = props.get("eventType", "?")
        desc = (props.get("description", "") or "")[:50]
        print(f"  {name:30s} type={htype}  event={event}  {desc}")


def cmd_hook_get(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(
        endpoint, token, "GET", f"/api/v2/extendedAgent/hooks/{args.name}"
    )
    if code != 200:
        die(f"HTTP {code}: {data}")
    print_json(data)


def cmd_hook_delete(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(
        endpoint, token, "DELETE", f"/api/v2/extendedAgent/hooks/{args.name}"
    )
    if code in (200, 202, 204, 404):
        ok(f"deleted hook/{args.name}")
    else:
        die(f"hook/{args.name}: HTTP {code}")
