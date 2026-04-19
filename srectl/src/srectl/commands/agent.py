"""Agent commands."""

from __future__ import annotations

import argparse

from srectl.client import api_request, get_ctx
from srectl.models import parse_agent_yaml
from srectl.output import die, ok, print_json


def cmd_context(args: argparse.Namespace) -> None:
    from srectl.client import get_token, resolve_endpoint

    agent_name, endpoint = resolve_endpoint()
    token = get_token()
    print(f"Agent:    {agent_name}")
    print(f"Endpoint: {endpoint}")
    code, data = api_request(endpoint, token, "GET", "/api/v2/extendedAgent/agents")
    if code == 200:
        count = len(data.get("value", [])) if isinstance(data, dict) else 0
        print(f"Status:   Connected ({count} agents)")
    else:
        print(f"Status:   HTTP {code}")


def cmd_agent_list(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(endpoint, token, "GET", "/api/v2/extendedAgent/agents")
    if code != 200:
        die(f"HTTP {code}")
    agents = data.get("value", []) if isinstance(data, dict) else []
    if not agents:
        print("(no agents)")
        return
    for a in agents:
        props = a.get("properties", {})
        tools = len(props.get("tools", []) or []) + len(props.get("mcpTools", []) or [])
        skills = len(props.get("allowedSkills", []) or [])
        handoffs = len(props.get("handoffs", []) or [])
        print(f"  {a['name']:40s} tools={tools}  skills={skills}  handoffs={handoffs}")


def cmd_agent_get(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(endpoint, token, "GET", f"/api/v2/extendedAgent/agents/{args.name}")
    if code != 200:
        die(f"HTTP {code}: {data}")
    print_json(data)


def cmd_agent_apply(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    body = parse_agent_yaml(args.file)
    name = body.get("name", "")
    if not name:
        die("Agent YAML must have a name (metadata.name or top-level name)")
    if getattr(args, "strip_handoffs", False):
        body.get("properties", {})["handoffs"] = []
    code, data = api_request(endpoint, token, "PUT", f"/api/v2/extendedAgent/agents/{name}", body=body)
    if code in (200, 201, 202, 204):
        ok(f"agent/{name}")
    else:
        die(f"agent/{name}: HTTP {code} — {data}")


def cmd_agent_delete(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(endpoint, token, "DELETE", f"/api/v2/extendedAgent/agents/{args.name}")
    if code in (200, 202, 204, 404):
        ok(f"deleted agent/{args.name}")
    else:
        die(f"agent/{args.name}: HTTP {code}")
