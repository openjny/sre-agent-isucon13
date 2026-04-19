"""Skill commands."""

from __future__ import annotations

import argparse

from srectl.client import api_request, get_ctx
from srectl.models import parse_skill_dir, skill_to_api
from srectl.output import die, ok, print_json


def cmd_skill_list(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(endpoint, token, "GET", "/api/v2/extendedAgent/skills")
    if code != 200:
        die(f"HTTP {code}")
    skills = data.get("value", []) if isinstance(data, dict) else []
    if not skills:
        print("(no skills)")
        return
    for s in skills:
        desc = (s.get("properties", {}).get("description", "") or "")[:60]
        print(f"  {s['name']:40s} {desc}")


def cmd_skill_get(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(endpoint, token, "GET", f"/api/v2/extendedAgent/skills/{args.name}")
    if code != 200:
        die(f"HTTP {code}: {data}")
    print_json(data)


def cmd_skill_add(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    name, description, content = parse_skill_dir(args.dir)
    body = skill_to_api(name, description, content)
    code, data = api_request(endpoint, token, "PUT", f"/api/v2/extendedAgent/skills/{name}", body=body)
    if code in (200, 201, 202):
        ok(f"skill/{name}")
    else:
        die(f"skill/{name}: HTTP {code} — {data}")


def cmd_skill_delete(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(endpoint, token, "DELETE", f"/api/v2/extendedAgent/skills/{args.name}")
    if code in (200, 202, 204, 404):
        ok(f"deleted skill/{args.name}")
    else:
        die(f"skill/{args.name}: HTTP {code}")
