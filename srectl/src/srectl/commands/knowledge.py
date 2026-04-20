"""Knowledge, auth, connector, and MCP commands."""

from __future__ import annotations

import argparse
import base64
import os

from srectl.client import api_request, get_ctx
from srectl.output import die, ok, print_json

# ── Knowledge file ───────────────────────────────────────────────────────────


def cmd_knowledge_file_add(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    if not os.path.isfile(args.file):
        die(f"File not found: {args.file}")
    with open(args.file, "rb") as f:
        raw = f.read()

    encoded = base64.b64encode(raw).decode()
    name = args.name or os.path.basename(args.file)
    display_name = args.display_name or os.path.basename(args.file)
    filename = os.path.basename(args.file)

    ext = os.path.splitext(filename)[1].lower()
    if ext not in (".md", ".txt"):
        die(f"Unsupported file type: {ext} (only .md and .txt are supported)")
    content_types = {".md": "text/markdown", ".txt": "text/plain"}

    body = {
        "name": name,
        "type": "KnowledgeItem",
        "properties": {
            "dataConnectorType": "KnowledgeFile",
            "dataSource": name,
            "extendedProperties": {
                "displayName": display_name,
                "fileName": filename,
                "contentType": content_types[ext],
                "fileContent": encoded,
            },
        },
    }
    code, data = api_request(
        endpoint, token, "PUT", f"/api/v2/extendedAgent/connectors/{name}", body=body
    )
    if code in (200, 201, 202):
        ok(f"knowledge/file/{name}")
    else:
        die(f"knowledge/file/{name}: HTTP {code} — {data}")


def cmd_knowledge_file_delete(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(
        endpoint, token, "DELETE", f"/api/v2/extendedAgent/connectors/{args.name}"
    )
    if code in (200, 202, 204, 404):
        ok(f"deleted knowledge/file/{args.name}")
    else:
        die(f"knowledge/file/{args.name}: HTTP {code}")


def _list_connectors_by_type(args: argparse.Namespace, dtype: str) -> list:
    endpoint, token = get_ctx(args)
    code, data = api_request(endpoint, token, "GET", "/api/v2/extendedAgent/connectors")
    if code != 200:
        die(f"HTTP {code}")
    items = (
        data.get("value", [])
        if isinstance(data, dict)
        else (data if isinstance(data, list) else [])
    )
    return [
        c for c in items if c.get("properties", {}).get("dataConnectorType") == dtype
    ]


def cmd_knowledge_file_list(args: argparse.Namespace) -> None:
    items = _list_connectors_by_type(args, "KnowledgeFile")
    if not items:
        print("(no knowledge files)")
        return
    for c in items:
        ext = c.get("properties", {}).get("extendedProperties", {})
        display = ext.get("displayName", c["name"])
        size = ext.get("fileSize", "")
        size_str = f"  {size}B" if size else ""
        print(f"  {c['name']:40s} {display}{size_str}")


# ── Knowledge web ────────────────────────────────────────────────────────────


def cmd_knowledge_web_add(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    name = args.name
    body = {
        "name": name,
        "type": "KnowledgeItem",
        "properties": {
            "dataConnectorType": "KnowledgeWebPage",
            "dataSource": name,
            "extendedProperties": {
                "url": args.url,
                "displayName": args.display_name or name,
                "description": args.description or "",
            },
        },
    }
    code, data = api_request(
        endpoint, token, "PUT", f"/api/v2/extendedAgent/connectors/{name}", body=body
    )
    if code in (200, 201, 202):
        ok(f"knowledge/web/{name} -> {args.url}")
    else:
        die(f"knowledge/web/{name}: HTTP {code} — {data}")


def cmd_knowledge_web_delete(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(
        endpoint, token, "DELETE", f"/api/v2/extendedAgent/connectors/{args.name}"
    )
    if code in (200, 202, 204, 404):
        ok(f"deleted knowledge/web/{args.name}")
    else:
        die(f"knowledge/web/{args.name}: HTTP {code}")


def cmd_knowledge_web_list(args: argparse.Namespace) -> None:
    items = _list_connectors_by_type(args, "KnowledgeWebPage")
    if not items:
        print("(no knowledge web pages)")
        return
    for c in items:
        ext = c.get("properties", {}).get("extendedProperties", {})
        print(f"  {c['name']:40s} {ext.get('url', '')}")


# ── Knowledge repo ───────────────────────────────────────────────────────────


def cmd_knowledge_repo_add(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    name = args.name
    body = {
        "name": name,
        "type": "CodeRepo",
        "properties": {
            "url": args.url,
            "type": "GitHub",
            "description": args.description or "",
        },
    }
    code, data = api_request(endpoint, token, "PUT", f"/api/v2/repos/{name}", body=body)
    if code in (200, 201, 202):
        ok(f"knowledge/repo/{name} -> {args.url}")
    else:
        die(f"knowledge/repo/{name}: HTTP {code} — {data}")


def cmd_knowledge_repo_delete(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(endpoint, token, "DELETE", f"/api/v2/repos/{args.name}")
    if code in (200, 202, 204, 404):
        ok(f"deleted knowledge/repo/{args.name}")
    else:
        die(f"knowledge/repo/{args.name}: HTTP {code}")


def cmd_knowledge_repo_list(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(endpoint, token, "GET", "/api/v2/repos")
    if code != 200:
        die(f"HTTP {code}")
    repos = data.get("value", []) if isinstance(data, dict) else []
    if not repos:
        print("(no repos)")
        return
    for r in repos:
        props = r.get("properties", {})
        url = props.get("url", "")
        clone = props.get("cloneStatus", "?")
        scan = props.get("scanStatus", "?")
        print(f"  {r['name']:30s} clone={clone:10s} scan={scan:15s} {url}")


# ── Auth ─────────────────────────────────────────────────────────────────────


def cmd_auth_github_set(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    body_bytes = f"pat={args.pat}".encode()
    code, data = api_request(
        endpoint,
        token,
        "POST",
        "/api/v1/github/auth/pat",
        raw_body=body_bytes,
        content_type="application/x-www-form-urlencoded",
    )
    if code in (200, 201, 202):
        ok("auth/github PAT set")
    else:
        die(f"auth/github: HTTP {code} — {data}")


def cmd_auth_github_delete(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(endpoint, token, "DELETE", "/api/v1/github/auth")
    if code in (200, 202, 204, 404):
        ok("deleted auth/github")
    else:
        die(f"auth/github: HTTP {code}")


# ── Connector ────────────────────────────────────────────────────────────────


def cmd_connector_list(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(endpoint, token, "GET", "/api/v2/extendedAgent/connectors")
    if code != 200:
        die(f"HTTP {code}")
    connectors = (
        data.get("value", [])
        if isinstance(data, dict)
        else (data if isinstance(data, list) else [])
    )
    if not connectors:
        print("(no connectors)")
        return
    for c in connectors:
        props = c.get("properties", {})
        ctype = props.get("dataConnectorType", "?")
        print(f"  {c['name']:40s} type={ctype}")


def cmd_connector_get(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(
        endpoint, token, "GET", f"/api/v2/extendedAgent/connectors/{args.name}"
    )
    if code != 200:
        die(f"HTTP {code}: {data}")
    print_json(data)


def cmd_connector_delete(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(
        endpoint, token, "DELETE", f"/api/v2/extendedAgent/connectors/{args.name}"
    )
    if code in (200, 202, 204, 404):
        ok(f"deleted connector/{args.name}")
    else:
        die(f"connector/{args.name}: HTTP {code}")


# ── MCP ──────────────────────────────────────────────────────────────────────


def cmd_mcp_add(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    name = args.name
    url = args.url

    ext_props: dict = {"type": "http", "endpoint": url}

    if args.header:
        for h in args.header:
            if "=" not in h:
                die(f"Invalid header format: {h} (expected KEY=VALUE)")
            key, val = h.split("=", 1)
            key_lower = key.lower()
            if key_lower == "authorization" and val.lower().startswith("bearer "):
                ext_props["authType"] = "BearerToken"
                ext_props["bearerToken"] = val.split(" ", 1)[1]
            elif key_lower == "x-api-key":
                ext_props["authType"] = "BearerToken"
                ext_props["bearerToken"] = val
            else:
                ext_props.setdefault("headers", {})[key] = val

    body = {
        "name": name,
        "type": "AgentConnector",
        "properties": {
            "dataConnectorType": "Mcp",
            "dataSource": "placeholder",
            "identity": "",
            "extendedProperties": ext_props,
        },
    }

    code, data = api_request(
        endpoint, token, "PUT", f"/api/v2/extendedAgent/connectors/{name}", body=body
    )
    if code in (200, 201, 202):
        ok(f"connector/{name} -> {url}")
    else:
        die(f"connector/{name}: HTTP {code} -- {data}")
