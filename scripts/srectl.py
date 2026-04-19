#!/usr/bin/env python3
"""srectl — SRE Agent CLI.

CLI for managing Azure SRE Agent resources via the dataplane API.
No external dependencies (pure Python 3.8+).

Usage:
    srectl context                        Show current connection info
    srectl agent list                     List custom agents
    srectl agent get <name>               Get agent details
    srectl agent add -f <yaml>            Create/update agent from YAML
    srectl agent delete <name>            Delete agent
    srectl skill list                     List skills
    srectl skill get <name>               Get skill details
    srectl skill add --dir <dir>          Create/update skill from SKILL.md directory
    srectl skill delete <name>            Delete skill
    srectl memory list                    List memory files
    srectl memory add <file>...            Add memory files
    srectl knowledge file add --file <f>  Add a knowledge file
    srectl knowledge file delete <name>   Delete a knowledge file
    srectl knowledge web add --name <n> --url <u>  Add a web page
    srectl knowledge web delete <name>    Delete a web page
    srectl knowledge repo add --name <n> --url <u> Add a GitHub repo
    srectl knowledge repo delete <name>   Delete a repo
    srectl knowledge repo list            List repos with sync status
    srectl auth github set --pat <token>  Set GitHub PAT
    srectl auth github delete             Delete GitHub PAT
    srectl mcp add --name <n> --url <u>   Create/update MCP connector
    srectl connector list                 List connectors
    srectl connector get <name>           Get connector details
    srectl connector delete <name>        Delete connector
    srectl tool list                      List all available tools
    srectl tool add --name <n> ...        Add a Python tool
    srectl tool delete <name>             Delete a custom tool
    srectl trigger create --name <n> --prompt <p>  Create HTTP trigger
    srectl trigger list                   List triggers
    srectl trigger execute <id>           Execute a trigger
    srectl trigger delete <id>            Delete a trigger
    srectl thread messages <id>           Get thread messages
    srectl thread watch <id>              Watch thread messages (poll)
    srectl contest kick [--prompt <p>]    Create trigger + execute + watch
    srectl hook add --name <n> --json <j> Create/update a hook
    srectl hook list                      List hooks
    srectl hook get <name>                Get hook details
    srectl hook delete <name>             Delete a hook
"""

from __future__ import annotations

import argparse
import io
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid


# ── Context resolution ───────────────────────────────────────────────────────


def _run(cmd: list[str]) -> str:
    """Run a subprocess and return stripped stdout, or empty string on failure."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return r.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""


def resolve_endpoint(rg: str | None = None) -> tuple[str, str]:
    """Resolve SRE Agent endpoint from Azure resources.

    Tries azd env first (fast), falls back to az resource queries (slow).
    Returns (agent_name, endpoint_url).
    """
    # Fast path: azd env has both values after azd provision
    agent_name = _run(["azd", "env", "get-value", "SRE_AGENT_NAME"])
    endpoint = _run(["azd", "env", "get-value", "SRE_AGENT_ENDPOINT"])
    if agent_name and endpoint:
        return agent_name, endpoint

    # Slow path: query ARM
    if not rg:
        rg = _run(["azd", "env", "get-value", "SREAGENT_RESOURCE_GROUP"])
    if not rg:
        rg = "rg-isucon13-sreagent"

    if not agent_name:
        agent_name = _run([
            "az", "resource", "list", "-g", rg,
            "--resource-type", "Microsoft.App/agents",
            "--query", "[0].name", "-o", "tsv",
        ])
    if not agent_name:
        _die(f"No SRE Agent found in {rg}")

    if not endpoint:
        endpoint = _run([
            "az", "resource", "show", "-g", rg, "-n", agent_name,
            "--resource-type", "Microsoft.App/agents",
            "--api-version", "2025-05-01-preview",
            "--query", "properties.agentEndpoint", "-o", "tsv",
        ])
    if not endpoint:
        _die("Could not resolve agent endpoint")

    return agent_name, endpoint


def get_token() -> str:
    """Get Azure SRE Agent dataplane token."""
    token = _run([
        "az", "account", "get-access-token",
        "--resource", "https://azuresre.ai",
        "--query", "accessToken", "-o", "tsv",
    ])
    if not token:
        _die("Failed to get access token (az account get-access-token)")
    return token


def get_arm_token() -> str:
    """Get Azure ARM token (for HTTP trigger execute and thread APIs)."""
    token = _run([
        "az", "account", "get-access-token",
        "--resource", "https://management.azure.com",
        "--query", "accessToken", "-o", "tsv",
    ])
    if not token:
        _die("Failed to get ARM access token")
    return token


# ── HTTP client ──────────────────────────────────────────────────────────────


def api_request(
    endpoint: str,
    token: str,
    method: str,
    path: str,
    body: dict | None = None,
    raw_body: bytes | None = None,
    content_type: str = "application/json",
) -> tuple[int, dict | str]:
    """Make an HTTP request to the SRE Agent dataplane API."""
    url = f"{endpoint}{path}"
    headers = {"Authorization": f"Bearer {token}"}

    data: bytes | None = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    elif raw_body is not None:
        data = raw_body
        headers["Content-Type"] = content_type

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            code = resp.status
            resp_body = resp.read().decode()
            if resp_body:
                try:
                    return code, json.loads(resp_body)
                except json.JSONDecodeError:
                    return code, resp_body
            return code, {}
    except urllib.error.HTTPError as e:
        code = e.code
        resp_body = e.read().decode()
        try:
            return code, json.loads(resp_body)
        except (json.JSONDecodeError, Exception):
            return code, resp_body


def build_multipart(files: list[tuple[str, str, bytes]], fields: dict | None = None) -> tuple[bytes, str]:
    """Build a multipart/form-data body.

    files: list of (field_name, filename, file_bytes)
    fields: dict of simple form fields
    """
    boundary = f"----srectl-{uuid.uuid4().hex}"
    buf = io.BytesIO()

    if fields:
        for key, val in fields.items():
            buf.write(f"--{boundary}\r\n".encode())
            buf.write(f'Content-Disposition: form-data; name="{key}"\r\n\r\n'.encode())
            buf.write(f"{val}\r\n".encode())

    for field_name, filename, file_bytes in files:
        buf.write(f"--{boundary}\r\n".encode())
        buf.write(f'Content-Disposition: form-data; name="{field_name}"; filename="{filename}"\r\n'.encode())
        buf.write(b"Content-Type: text/plain\r\n\r\n")
        buf.write(file_bytes)
        buf.write(b"\r\n")

    buf.write(f"--{boundary}--\r\n".encode())
    return buf.getvalue(), f"multipart/form-data; boundary={boundary}"


# ── YAML / Frontmatter parsing ───────────────────────────────────────────────


def parse_simple_yaml(text: str) -> dict:
    """Parse a simple flat YAML file (no nesting beyond lists).

    Supports: scalars, multiline |, lists with - items, booleans.
    """
    result: dict = {}
    current_key: str | None = None
    current_multiline: str | None = None
    for line in text.split("\n"):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            if current_multiline is not None:
                current_multiline += "\n"
            continue
        if current_multiline is not None:
            if len(line) > 0 and not line[0].isspace() and ":" in stripped and not stripped.startswith("-"):
                result[current_key] = current_multiline.strip()
                current_multiline = None
            else:
                current_multiline += line.rstrip() + "\n"
                continue
        m = re.match(r"^(\w[\w_]*)\s*:\s*(.*)", line)
        if m:
            key, val = m.group(1), m.group(2).strip()
            current_key = key
            if val == "|":
                current_multiline = ""
            elif val.lower() in ("true", "false"):
                result[key] = val.lower() == "true"
            elif val:
                result[key] = val
            else:
                result[key] = []
            continue
        m = re.match(r"^\s*-\s+(.*)", line)
        if m and current_key:
            val = m.group(1).strip().strip('"').strip("'")
            if not isinstance(result.get(current_key), list):
                result[current_key] = []
            result[current_key].append(val)
    if current_multiline is not None and current_key:
        result[current_key] = current_multiline.strip()
    return result


def agent_yaml_to_api(spec: dict) -> dict:
    """Convert parsed agent YAML to SRE Agent API JSON body."""
    return {
        "name": spec.get("name", ""),
        "type": "ExtendedAgent",
        "tags": [],
        "owner": "",
        "properties": {
            "instructions": spec.get("system_prompt", ""),
            "handoffDescription": spec.get("handoff_description", ""),
            "handoffs": spec.get("handoffs", []),
            "tools": spec.get("tools", []),
            "mcpTools": spec.get("mcp_tools", []),
            "allowParallelToolCalls": True,
            "enableSkills": spec.get("enable_skills", True),
            "allowedSkills": spec.get("allowed_skills", []),
        },
    }


def parse_skill_dir(skill_dir: str) -> tuple[str, str, str]:
    """Parse a skill directory containing SKILL.md.

    Returns (skill_name, description, skill_content).
    """
    skill_name = os.path.basename(os.path.normpath(skill_dir))
    skill_md = os.path.join(skill_dir, "SKILL.md")
    if not os.path.isfile(skill_md):
        _die(f"SKILL.md not found in {skill_dir}")

    with open(skill_md) as f:
        content = f.read()

    # Extract description from YAML frontmatter
    description = ""
    m = re.search(r"^---\s*\n(.*?)\n---", content, re.DOTALL)
    if m:
        for line in m.group(1).split("\n"):
            if line.startswith("description:"):
                description = line.split(":", 1)[1].strip()
                break

    return skill_name, description, content


def skill_to_api(name: str, description: str, content: str) -> dict:
    """Build skill API JSON body."""
    return {
        "name": name,
        "type": "Skill",
        "properties": {
            "description": description,
            "tools": [],
            "skillContent": content,
            "additionalFiles": [],
        },
    }


# ── Output helpers ───────────────────────────────────────────────────────────


def _die(msg: str) -> None:
    print(f"❌ {msg}", file=sys.stderr)
    sys.exit(1)


def _ok(msg: str) -> None:
    print(f"✅ {msg}")


def _print_json(data: dict | list | str) -> None:
    if isinstance(data, (dict, list)):
        print(json.dumps(data, indent=2, ensure_ascii=False))
    else:
        print(data)


def _print_table(rows: list[dict], columns: list[tuple[str, str, int]]) -> None:
    """Print a simple table. columns: list of (header, key_path, width)."""
    header = "  ".join(h.ljust(w) for h, _, w in columns)
    print(header)
    print("  ".join("-" * w for _, _, w in columns))
    for row in rows:
        vals = []
        for _, key, w in columns:
            val = row
            for k in key.split("."):
                if isinstance(val, dict):
                    val = val.get(k, "")
                else:
                    val = ""
            vals.append(str(val)[:w].ljust(w))
        print("  ".join(vals))


# ── Commands ─────────────────────────────────────────────────────────────────


def cmd_context(args: argparse.Namespace) -> None:
    agent_name, endpoint = resolve_endpoint()
    token = get_token()
    print(f"Agent:    {agent_name}")
    print(f"Endpoint: {endpoint}")
    # Quick connectivity check
    code, data = api_request(endpoint, token, "GET", "/api/v2/extendedAgent/agents")
    if code == 200:
        count = len(data.get("value", [])) if isinstance(data, dict) else 0
        print(f"Status:   Connected ({count} agents)")
    else:
        print(f"Status:   HTTP {code}")


def cmd_agent_list(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "GET", "/api/v2/extendedAgent/agents")
    if code != 200:
        _die(f"HTTP {code}")
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
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "GET", f"/api/v2/extendedAgent/agents/{args.name}")
    if code != 200:
        _die(f"HTTP {code}: {data}")
    _print_json(data)


def cmd_agent_add(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    with open(args.file) as f:
        spec = parse_simple_yaml(f.read())
    name = spec.get("name", "")
    if not name:
        _die("Agent YAML must have a 'name' field")
    body = agent_yaml_to_api(spec)
    code, data = api_request(endpoint, token, "PUT", f"/api/v2/extendedAgent/agents/{name}", body=body)
    if code in (200, 201, 202, 204):
        _ok(f"agent/{name}")
    else:
        _die(f"agent/{name}: HTTP {code} — {data}")


def cmd_agent_delete(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "DELETE", f"/api/v2/extendedAgent/agents/{args.name}")
    if code in (200, 202, 204, 404):
        _ok(f"deleted agent/{args.name}")
    else:
        _die(f"agent/{args.name}: HTTP {code}")


def cmd_skill_list(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "GET", "/api/v2/extendedAgent/skills")
    if code != 200:
        _die(f"HTTP {code}")
    skills = data.get("value", []) if isinstance(data, dict) else []
    if not skills:
        print("(no skills)")
        return
    for s in skills:
        desc = (s.get("properties", {}).get("description", "") or "")[:60]
        print(f"  {s['name']:40s} {desc}")


def cmd_skill_get(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "GET", f"/api/v2/extendedAgent/skills/{args.name}")
    if code != 200:
        _die(f"HTTP {code}: {data}")
    _print_json(data)


def cmd_skill_add(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    name, description, content = parse_skill_dir(args.dir)
    body = skill_to_api(name, description, content)
    code, data = api_request(endpoint, token, "PUT", f"/api/v2/extendedAgent/skills/{name}", body=body)
    if code in (200, 201, 202):
        _ok(f"skill/{name}")
    else:
        _die(f"skill/{name}: HTTP {code} — {data}")


def cmd_skill_delete(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "DELETE", f"/api/v2/extendedAgent/skills/{args.name}")
    if code in (200, 202, 204, 404):
        _ok(f"deleted skill/{args.name}")
    else:
        _die(f"skill/{args.name}: HTTP {code}")


def cmd_memory_list(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "GET", "/api/v1/AgentMemory/files")
    if code != 200:
        _die(f"HTTP {code}")
    files = data.get("files", []) if isinstance(data, dict) else []
    if not files:
        print("(no files)")
        return
    for f in files:
        status = "✅" if f.get("isIndexed") else "⏳"
        error = f" ( {f.get('errorReason')} )" if not f.get("isIndexed") else ""
        print(f"  {status} {f['name']}{error}")


def cmd_memory_add(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    file_tuples: list[tuple[str, str, bytes]] = []
    for path in args.files:
        if not os.path.isfile(path):
            _die(f"File not found: {path}")
        with open(path, "rb") as f:
            file_tuples.append(("files", os.path.basename(path), f.read()))
    if not file_tuples:
        _die("No files specified")

    body_bytes, content_type = build_multipart(file_tuples, {"triggerIndexing": "true"})
    code, data = api_request(
        endpoint, token, "POST", "/api/v1/AgentMemory/upload",
        raw_body=body_bytes, content_type=content_type,
    )
    if code in (200, 201):
        _ok(f"uploaded {len(file_tuples)} file(s)")
    else:
        _die(f"upload: HTTP {code} — {data}")


# ── Knowledge commands ───────────────────────────────────────────────────────


def cmd_knowledge_file_add(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    if not os.path.isfile(args.file):
        _die(f"File not found: {args.file}")
    with open(args.file, "rb") as f:
        raw = f.read()

    import base64
    encoded = base64.b64encode(raw).decode()
    name = args.name or os.path.basename(args.file)
    display_name = args.display_name or os.path.basename(args.file)
    filename = os.path.basename(args.file)

    # Supported: .md and .txt only
    ext = os.path.splitext(filename)[1].lower()
    if ext not in (".md", ".txt"):
        _die(f"Unsupported file type: {ext} (only .md and .txt are supported)")
    content_types = {".md": "text/markdown", ".txt": "text/plain"}
    file_content_type = content_types[ext]

    body = {
        "name": name,
        "type": "KnowledgeItem",
        "properties": {
            "dataConnectorType": "KnowledgeFile",
            "dataSource": name,
            "extendedProperties": {
                "displayName": display_name,
                "fileName": filename,
                "contentType": file_content_type,
                "fileContent": encoded,
            },
        },
    }
    code, data = api_request(endpoint, token, "PUT", f"/api/v2/extendedAgent/connectors/{name}", body=body)
    if code in (200, 201, 202):
        _ok(f"knowledge/file/{name}")
    else:
        _die(f"knowledge/file/{name}: HTTP {code} — {data}")


def cmd_knowledge_file_delete(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "DELETE", f"/api/v2/extendedAgent/connectors/{args.name}")
    if code in (200, 202, 204, 404):
        _ok(f"deleted knowledge/file/{args.name}")
    else:
        _die(f"knowledge/file/{args.name}: HTTP {code}")


def _list_connectors_by_type(args: argparse.Namespace, dtype: str) -> list:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "GET", "/api/v2/extendedAgent/connectors")
    if code != 200:
        _die(f"HTTP {code}")
    items = data.get("value", []) if isinstance(data, dict) else (data if isinstance(data, list) else [])
    return [c for c in items if c.get("properties", {}).get("dataConnectorType") == dtype]


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


def cmd_knowledge_web_add(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
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
    code, data = api_request(endpoint, token, "PUT", f"/api/v2/extendedAgent/connectors/{name}", body=body)
    if code in (200, 201, 202):
        _ok(f"knowledge/web/{name} -> {args.url}")
    else:
        _die(f"knowledge/web/{name}: HTTP {code} — {data}")


def cmd_knowledge_web_delete(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "DELETE", f"/api/v2/extendedAgent/connectors/{args.name}")
    if code in (200, 202, 204, 404):
        _ok(f"deleted knowledge/web/{args.name}")
    else:
        _die(f"knowledge/web/{args.name}: HTTP {code}")


def cmd_knowledge_web_list(args: argparse.Namespace) -> None:
    items = _list_connectors_by_type(args, "KnowledgeWebPage")
    if not items:
        print("(no knowledge web pages)")
        return
    for c in items:
        ext = c.get("properties", {}).get("extendedProperties", {})
        url = ext.get("url", "")
        display = ext.get("displayName", c["name"])
        print(f"  {c['name']:40s} {url}")


def cmd_knowledge_repo_add(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
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
        _ok(f"knowledge/repo/{name} -> {args.url}")
    else:
        _die(f"knowledge/repo/{name}: HTTP {code} — {data}")


def cmd_knowledge_repo_delete(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "DELETE", f"/api/v2/repos/{args.name}")
    if code in (200, 202, 204, 404):
        _ok(f"deleted knowledge/repo/{args.name}")
    else:
        _die(f"knowledge/repo/{args.name}: HTTP {code}")


def cmd_knowledge_repo_list(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "GET", "/api/v2/repos")
    if code != 200:
        _die(f"HTTP {code}")
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


# ── Auth commands ────────────────────────────────────────────────────────────


def cmd_auth_github_set(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    body_bytes = f"pat={args.pat}".encode()
    code, data = api_request(
        endpoint, token, "POST", "/api/v1/github/auth/pat",
        raw_body=body_bytes, content_type="application/x-www-form-urlencoded",
    )
    if code in (200, 201, 202):
        _ok("auth/github PAT set")
    else:
        _die(f"auth/github: HTTP {code} — {data}")


def cmd_auth_github_delete(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "DELETE", "/api/v1/github/auth")
    if code in (200, 202, 204, 404):
        _ok("deleted auth/github")
    else:
        _die(f"auth/github: HTTP {code}")


def cmd_connector_list(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "GET", "/api/v2/extendedAgent/connectors")
    if code != 200:
        _die(f"HTTP {code}")
    connectors = data.get("value", []) if isinstance(data, dict) else (data if isinstance(data, list) else [])
    if not connectors:
        print("(no connectors)")
        return
    for c in connectors:
        props = c.get("properties", {})
        ctype = props.get("dataConnectorType", "?")
        print(f"  {c['name']:40s} type={ctype}")


def cmd_connector_get(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "GET", f"/api/v2/extendedAgent/connectors/{args.name}")
    if code != 200:
        _die(f"HTTP {code}: {data}")
    _print_json(data)


def cmd_connector_delete(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "DELETE", f"/api/v2/extendedAgent/connectors/{args.name}")
    if code in (200, 202, 204, 404):
        _ok(f"deleted connector/{args.name}")
    else:
        _die(f"connector/{args.name}: HTTP {code}")


def cmd_mcp_add(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    name = args.name
    url = args.url

    ext_props: dict = {
        "type": "http",
        "endpoint": url,
    }

    # Parse --header KEY=VALUE pairs into auth config
    if args.header:
        for h in args.header:
            if "=" not in h:
                _die(f"Invalid header format: {h} (expected KEY=VALUE)")
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

    code, data = api_request(endpoint, token, "PUT", f"/api/v2/extendedAgent/connectors/{name}", body=body)
    if code in (200, 201, 202):
        _ok(f"connector/{name} -> {url}")
    else:
        _die(f"connector/{name}: HTTP {code} -- {data}")


def cmd_tool_list(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "GET", "/api/v2/agent/tools")
    if code != 200:
        _die(f"HTTP {code}")
    tools = data.get("data", []) if isinstance(data, dict) else []
    if not tools:
        print("(no tools)")
        return

    # Filter by source if specified
    source_filter = getattr(args, "source", None)
    if source_filter:
        tools = [t for t in tools if t.get("source") == source_filter]
        if not tools:
            print(f"(no {source_filter} tools)")
            return

    # Group by category
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
    endpoint, token = _get_ctx(args)
    name = args.name
    description = args.description

    # Read Python code from file
    if not os.path.isfile(args.code_file):
        _die(f"File not found: {args.code_file}")
    with open(args.code_file) as f:
        code = f.read()

    # Build parameters list
    params: list[dict] = []
    if args.param:
        for p in args.param:
            # Format: name:type[:description]
            parts = p.split(":", 2)
            if len(parts) < 2:
                _die(f"Invalid param format: {p} (expected name:type[:description])")
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
                },
            ],
        },
    }

    # Apply API requires Content-Type: text/yaml (415 with application/json)
    # Send JSON structure as YAML-compatible text
    raw_body = json.dumps(body).encode()
    code_resp, data = api_request(
        endpoint, token, "PUT", "/api/v1/extendedAgent/apply",
        raw_body=raw_body, content_type="text/yaml",
    )
    if code_resp in (200, 201, 202):
        _ok(f"tool/{name}")
    else:
        _die(f"tool/{name}: HTTP {code_resp} — {data}")


def cmd_tool_delete(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "DELETE", f"/api/v1/extendedAgent/tools/{args.name}")
    if code in (200, 202, 204, 404):
        _ok(f"deleted tool/{args.name}")
    else:
        _die(f"tool/{args.name}: HTTP {code}")


# ── HTTP Trigger commands ────────────────────────────────────────────────────


# ── Hook commands ────────────────────────────────────────────────────────────


def cmd_hook_add(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    body = json.loads(args.json)
    name = body.get("name", args.name)
    code, data = api_request(endpoint, token, "PUT", f"/api/v2/extendedAgent/hooks/{name}", body=body)
    if code in (200, 201, 202):
        _ok(f"hook/{name}")
    else:
        _die(f"hook/{name}: HTTP {code} — {data}")


def cmd_hook_list(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "GET", "/api/v2/extendedAgent/hooks")
    if code != 200:
        _die(f"HTTP {code}: {data}")
    hooks = data.get("value", []) if isinstance(data, dict) else (data if isinstance(data, list) else [])
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
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "GET", f"/api/v2/extendedAgent/hooks/{args.name}")
    if code != 200:
        _die(f"HTTP {code}: {data}")
    _print_json(data)


def cmd_hook_delete(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "DELETE", f"/api/v2/extendedAgent/hooks/{args.name}")
    if code in (200, 202, 204, 404):
        _ok(f"deleted hook/{args.name}")
    else:
        _die(f"hook/{args.name}: HTTP {code}")


def cmd_trigger_create(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    body = {
        "name": args.name,
        "description": args.description or "",
        "agentPrompt": args.prompt,
        "agent": args.agent or "isucon",
        "agentMode": args.mode or "autonomous",
    }
    if args.thread_id:
        body["threadId"] = args.thread_id
    code, data = api_request(endpoint, token, "POST", "/api/v1/httptriggers/create", body=body)
    if code in (200, 201, 202):
        if isinstance(data, dict):
            trigger_id = data.get("triggerId", "?")
            trigger_url = data.get("triggerUrl", "?")
            print(f"Trigger ID:  {trigger_id}")
            print(f"Trigger URL: {trigger_url}")
            _ok(f"trigger/{args.name}")
        else:
            _print_json(data)
    else:
        _die(f"trigger/{args.name}: HTTP {code} — {data}")


def cmd_trigger_list(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "GET", "/api/v1/httptriggers")
    if code != 200:
        _die(f"HTTP {code}: {data}")
    triggers = data if isinstance(data, list) else data.get("value", data.get("triggers", [])) if isinstance(data, dict) else []
    if not triggers:
        print("(no triggers)")
        return
    for t in triggers:
        name = t.get("name", "?")
        tid = t.get("triggerId", t.get("id", "?"))
        enabled = "on" if t.get("enabled", True) else "off"
        agent = t.get("agent", "?")
        print(f"  {name:30s} id={tid}  agent={agent}  {enabled}")


def cmd_trigger_execute(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    # Trigger execute requires ARM token
    trigger_id = args.trigger_id

    payload: dict | None = None
    if args.data:
        try:
            payload = json.loads(args.data)
        except json.JSONDecodeError:
            _die(f"Invalid JSON: {args.data}")

    code, data = api_request(endpoint, token, "POST", f"/api/v1/httptriggers/{trigger_id}/execute", body=payload)
    if code in (200, 202):
        if isinstance(data, dict):
            execution = data.get("execution", data)
            thread_id = execution.get("threadId", "?")
            print(f"Thread ID: {thread_id}")
            _ok(f"trigger executed")
        else:
            _print_json(data)
    else:
        _die(f"trigger execute: HTTP {code} — {data}")


def cmd_trigger_delete(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    code, data = api_request(endpoint, token, "DELETE", f"/api/v1/httptriggers/{args.trigger_id}")
    if code in (200, 202, 204, 404):
        _ok(f"deleted trigger/{args.trigger_id}")
    else:
        _die(f"trigger: HTTP {code}")


# ── Thread commands ──────────────────────────────────────────────────────────


def _fetch_messages(endpoint: str, token: str, thread_id: str, top: int = 20, skip: int = 0) -> list:
    """Fetch thread messages."""
    code, data = api_request(
        endpoint, token, "GET",
        f"/api/v1/threads/{thread_id}/messages?skip={skip}&top={top}&orderby=timestamp+desc",
    )
    if code != 200:
        print(f"  ⚠️  HTTP {code}", file=sys.stderr)
        return []
    if isinstance(data, dict):
        return data.get("value", [])
    return data if isinstance(data, list) else []


def _format_message(msg: dict) -> str:
    """Format a single thread message for display."""
    author = msg.get("author", {})
    role = author.get("role", "?") if isinstance(author, dict) else "?"
    ts = msg.get("timeStamp", msg.get("timestamp", ""))
    content = msg.get("text", "")

    # Role short names
    role_map = {"SREAgent": "agent", "User": "user", "System": "system"}
    role = role_map.get(role, role)

    # Skip empty or tool-only messages
    if not content or not content.strip():
        return ""

    # Truncate long content for display
    if len(content) > 500:
        content = content[:500] + "..."
    # Short timestamp (HH:MM:SS)
    if "T" in ts:
        ts = ts.split("T")[1][:8]
    return f"[{ts}] {role}: {content}"


def cmd_thread_messages(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    messages = _fetch_messages(endpoint, token, args.thread_id, top=args.top)
    if not messages:
        print("(no messages)")
        return
    # Print in chronological order (API returns desc)
    for msg in reversed(messages):
        line = _format_message(msg)
        if line:
            print(line, flush=True)


def cmd_thread_watch(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)
    thread_id = args.thread_id
    interval = args.interval
    seen_ids: set[str] = set()

    print(f"Watching thread {thread_id} (Ctrl+C to stop, polling every {interval}s)")
    print("-" * 60)

    try:
        while True:
            messages = _fetch_messages(endpoint, token, thread_id, top=20)
            # Print new messages in chronological order
            new_msgs = []
            for msg in reversed(messages):
                msg_id = msg.get("id", msg.get("timestamp", ""))
                if msg_id and msg_id not in seen_ids:
                    seen_ids.add(msg_id)
                    new_msgs.append(msg)
            for msg in new_msgs:
                line = _format_message(msg)
                if line:
                    print(line, flush=True)

            print(f"--- ({interval}s) ---", flush=True)
            time.sleep(interval)
    except KeyboardInterrupt:
        print("\n(stopped)")


# ── Contest commands ─────────────────────────────────────────────────────────


def cmd_contest_kick(args: argparse.Namespace) -> None:
    endpoint, token = _get_ctx(args)

    time_limit = args.time_limit
    prompt = args.prompt or f"ISUCON の競技を開始してください。制限時間は今から{time_limit}分です。その間は何回でもベンチマークを走らせて良いですが、最後に回したベンチマークのスコアがあなたの得点になります。"
    agent = args.agent or "isucon"
    trigger_name = args.name or "start-contest"

    # Step 1: Create trigger
    print(f"Creating trigger '{trigger_name}'...")
    body = {
        "name": trigger_name,
        "description": f"ISUCON contest kick ({time_limit}min)",
        "agentPrompt": prompt,
        "agent": agent,
        "agentMode": "autonomous",
    }
    code, data = api_request(endpoint, token, "POST", "/api/v1/httptriggers/create", body=body)
    if code not in (200, 201, 202):
        _die(f"Failed to create trigger: HTTP {code} — {data}")

    trigger_id = data.get("triggerId", "") if isinstance(data, dict) else ""
    if not trigger_id:
        _die(f"No triggerId in response: {data}")
    print(f"  Trigger ID: {trigger_id}")

    # Step 2: Execute trigger
    print("Executing trigger...")
    code, data = api_request(endpoint, token, "POST", f"/api/v1/httptriggers/{trigger_id}/execute")
    if code not in (200, 202):
        _die(f"Failed to execute trigger: HTTP {code} — {data}")

    execution = data.get("execution", data) if isinstance(data, dict) else {}
    thread_id = execution.get("threadId", "")
    if not thread_id:
        _die(f"No threadId in response: {data}")

    print(f"  Thread ID:  {thread_id}")
    print(f"  Portal:     https://sre.azure.com")
    _ok(f"Contest kicked! Time limit: {time_limit}min")
    print("")

    # Step 3: Watch
    if not args.no_watch:
        print(f"Watching thread (Ctrl+C to stop, polling every {args.interval}s)")
        print("-" * 60)
        seen_ids: set[str] = set()
        try:
            while True:
                messages = _fetch_messages(endpoint, token, thread_id, top=20)
                new_msgs = []
                for msg in reversed(messages):
                    msg_id = msg.get("id", msg.get("timestamp", ""))
                    if msg_id and msg_id not in seen_ids:
                        seen_ids.add(msg_id)
                        new_msgs.append(msg)
                for msg in new_msgs:
                    line = _format_message(msg)
                    if line:
                        print(line, flush=True)
                print(f"--- ({args.interval}s) ---", flush=True)
                time.sleep(args.interval)
        except KeyboardInterrupt:
            print("\n(stopped watching)")


def cmd_contest_watch(args: argparse.Namespace) -> None:
    """Alias for thread watch with contest-friendly defaults."""
    endpoint, token = _get_ctx(args)
    thread_id = args.thread_id
    interval = args.interval
    seen_ids: set[str] = set()

    print(f"Watching contest thread {thread_id} (Ctrl+C to stop)")
    print("-" * 60)

    try:
        while True:
            messages = _fetch_messages(endpoint, token, thread_id, top=20)
            new_msgs = []
            for msg in reversed(messages):
                msg_id = msg.get("id", msg.get("timestamp", ""))
                if msg_id and msg_id not in seen_ids:
                    seen_ids.add(msg_id)
                    new_msgs.append(msg)
            for msg in new_msgs:
                line = _format_message(msg)
                if line:
                    print(line, flush=True)
            print(f"--- ({interval}s) ---", flush=True)
            time.sleep(interval)
    except KeyboardInterrupt:
        print("\n(stopped)")


# ── Helpers ──────────────────────────────────────────────────────────────────


_cached_ctx: tuple[str, str] | None = None


def _get_ctx(args: argparse.Namespace) -> tuple[str, str]:
    """Get (endpoint, token), using CLI overrides or auto-resolve."""
    global _cached_ctx
    if _cached_ctx:
        return _cached_ctx

    endpoint = getattr(args, "endpoint", None)
    token = getattr(args, "token", None)

    if not endpoint:
        _, endpoint = resolve_endpoint()
    if not token:
        token = get_token()

    _cached_ctx = (endpoint, token)
    return endpoint, token


# ── CLI entrypoint ───────────────────────────────────────────────────────────


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="srectl", description="SRE Agent CLI")
    p.add_argument("--endpoint", help="Override agent endpoint URL")
    p.add_argument("--token", help="Override bearer token")

    sub = p.add_subparsers(dest="resource", help="Resource type")

    # context
    ctx = sub.add_parser("context", help="Show connection info")
    ctx.set_defaults(func=cmd_context)

    # agent
    agent = sub.add_parser("agent", help="Manage custom agents")
    agent_sub = agent.add_subparsers(dest="action")

    al = agent_sub.add_parser("list", help="List agents")
    al.set_defaults(func=cmd_agent_list)

    ag = agent_sub.add_parser("get", help="Get agent details")
    ag.add_argument("name")
    ag.set_defaults(func=cmd_agent_get)

    aa = agent_sub.add_parser("add", help="Create/update agent from YAML")
    aa.add_argument("-f", "--file", required=True, help="Agent YAML file")
    aa.set_defaults(func=cmd_agent_add)

    ad = agent_sub.add_parser("delete", help="Delete agent")
    ad.add_argument("name")
    ad.set_defaults(func=cmd_agent_delete)

    # skill
    skill = sub.add_parser("skill", help="Manage skills")
    skill_sub = skill.add_subparsers(dest="action")

    sl = skill_sub.add_parser("list", help="List skills")
    sl.set_defaults(func=cmd_skill_list)

    sg = skill_sub.add_parser("get", help="Get skill details")
    sg.add_argument("name")
    sg.set_defaults(func=cmd_skill_get)

    sa = skill_sub.add_parser("add", help="Create/update skill from SKILL.md directory")
    sa.add_argument("--dir", required=True, help="Directory containing SKILL.md")
    sa.set_defaults(func=cmd_skill_add)

    sd = skill_sub.add_parser("delete", help="Delete skill")
    sd.add_argument("name")
    sd.set_defaults(func=cmd_skill_delete)

    # memory
    mem = sub.add_parser("memory", help="Manage agent memory")
    mem_sub = mem.add_subparsers(dest="action")

    ml = mem_sub.add_parser("list", help="List memory files")
    ml.set_defaults(func=cmd_memory_list)

    mu = mem_sub.add_parser("add", help="Add memory files")
    mu.add_argument("files", nargs="+", help="Markdown files to add")
    mu.set_defaults(func=cmd_memory_add)

    # knowledge
    know = sub.add_parser("knowledge", help="Manage knowledge sources (files, web, repos)")
    know_sub = know.add_subparsers(dest="action")

    # knowledge file
    kf = know_sub.add_parser("file", help="Manage knowledge files")
    kf_sub = kf.add_subparsers(dest="file_action")

    kfa = kf_sub.add_parser("add", help="Upload a knowledge file")
    kfa.add_argument("--file", required=True, help="File to upload")
    kfa.add_argument("--name", help="Knowledge item name (default: filename)")
    kfa.add_argument("--display-name", help="Display name (default: filename)")
    kfa.set_defaults(func=cmd_knowledge_file_add)

    kfd = kf_sub.add_parser("delete", help="Delete a knowledge file")
    kfd.add_argument("name", help="Knowledge item name")
    kfd.set_defaults(func=cmd_knowledge_file_delete)

    kfl = kf_sub.add_parser("list", help="List knowledge files")
    kfl.set_defaults(func=cmd_knowledge_file_list)

    # knowledge web
    kw = know_sub.add_parser("web", help="Manage knowledge web pages")
    kw_sub = kw.add_subparsers(dest="web_action")

    kwa = kw_sub.add_parser("add", help="Add a web page as knowledge")
    kwa.add_argument("--name", required=True, help="Knowledge item name")
    kwa.add_argument("--url", required=True, help="Web page URL")
    kwa.add_argument("--display-name", help="Display name")
    kwa.add_argument("--description", help="Description")
    kwa.set_defaults(func=cmd_knowledge_web_add)

    kwd = kw_sub.add_parser("delete", help="Delete a knowledge web page")
    kwd.add_argument("name", help="Knowledge item name")
    kwd.set_defaults(func=cmd_knowledge_web_delete)

    kwl = kw_sub.add_parser("list", help="List knowledge web pages")
    kwl.set_defaults(func=cmd_knowledge_web_list)

    # knowledge repo
    kr = know_sub.add_parser("repo", help="Manage knowledge repositories")
    kr_sub = kr.add_subparsers(dest="repo_action")

    kra = kr_sub.add_parser("add", help="Add a GitHub repo as knowledge")
    kra.add_argument("--name", required=True, help="Repo name")
    kra.add_argument("--url", required=True, help="GitHub repo URL")
    kra.add_argument("--description", help="Description")
    kra.set_defaults(func=cmd_knowledge_repo_add)

    krd = kr_sub.add_parser("delete", help="Delete a knowledge repo")
    krd.add_argument("name", help="Repo name")
    krd.set_defaults(func=cmd_knowledge_repo_delete)

    krl = kr_sub.add_parser("list", help="List knowledge repos")
    krl.set_defaults(func=cmd_knowledge_repo_list)

    # auth
    auth = sub.add_parser("auth", help="Manage authentication")
    auth_sub = auth.add_subparsers(dest="action")

    ag_ = auth_sub.add_parser("github", help="Manage GitHub authentication")
    ag_sub = ag_.add_subparsers(dest="github_action")

    ags = ag_sub.add_parser("set", help="Set GitHub PAT")
    ags.add_argument("--pat", required=True, help="GitHub Personal Access Token")
    ags.set_defaults(func=cmd_auth_github_set)

    agd = ag_sub.add_parser("delete", help="Delete GitHub PAT")
    agd.set_defaults(func=cmd_auth_github_delete)

    # hook
    hook = sub.add_parser("hook", help="Manage hooks")
    hook_sub = hook.add_subparsers(dest="action")

    ha = hook_sub.add_parser("add", help="Create/update a hook")
    ha.add_argument("--name", required=True, help="Hook name")
    ha.add_argument("--json", required=True, help="Hook JSON body")
    ha.set_defaults(func=cmd_hook_add)

    hl = hook_sub.add_parser("list", help="List hooks")
    hl.set_defaults(func=cmd_hook_list)

    hg = hook_sub.add_parser("get", help="Get hook details")
    hg.add_argument("name", help="Hook name")
    hg.set_defaults(func=cmd_hook_get)

    hd = hook_sub.add_parser("delete", help="Delete a hook")
    hd.add_argument("name", help="Hook name")
    hd.set_defaults(func=cmd_hook_delete)

    # connector
    conn = sub.add_parser("connector", help="Manage connectors")
    conn_sub = conn.add_subparsers(dest="action")

    cl = conn_sub.add_parser("list", help="List connectors")
    cl.set_defaults(func=cmd_connector_list)

    cg = conn_sub.add_parser("get", help="Get connector details")
    cg.add_argument("name")
    cg.set_defaults(func=cmd_connector_get)

    cd_ = conn_sub.add_parser("delete", help="Delete connector")
    cd_.add_argument("name")
    cd_.set_defaults(func=cmd_connector_delete)

    # mcp (shortcut for connector add --type Mcp)
    mcp = sub.add_parser("mcp", help="Manage MCP connectors")
    mcp_sub = mcp.add_subparsers(dest="action")

    ma = mcp_sub.add_parser("add", help="Create/update MCP connector (HTTP)")
    ma.add_argument("--name", required=True, help="Connector name")
    ma.add_argument("--url", required=True, help="MCP server endpoint URL")
    ma.add_argument("--header", action="append", help="Header as KEY=VALUE (e.g. X-API-Key=secret)")
    ma.set_defaults(func=cmd_mcp_add)

    # tool
    tool = sub.add_parser("tool", help="Manage tools")
    tool_sub = tool.add_subparsers(dest="action")

    tl = tool_sub.add_parser("list", help="List all tools")
    tl.add_argument("--source", choices=["system", "mcp", "custom"], help="Filter by source")
    tl.set_defaults(func=cmd_tool_list)

    tc = tool_sub.add_parser("add", help="Add a Python tool via apply API")
    tc.add_argument("--name", required=True, help="Tool name")
    tc.add_argument("--description", required=True, help="Tool description")
    tc.add_argument("--code-file", required=True, help="Python file with main() function")
    tc.add_argument("--timeout", type=int, default=120, help="Timeout in seconds (default: 120)")
    tc.add_argument("--param", action="append", help="Parameter as name:type[:description]")
    tc.set_defaults(func=cmd_tool_add)

    td = tool_sub.add_parser("delete", help="Delete a custom tool")
    td.add_argument("name", help="Tool name")
    td.set_defaults(func=cmd_tool_delete)

    # trigger
    trigger = sub.add_parser("trigger", help="Manage HTTP triggers")
    trigger_sub = trigger.add_subparsers(dest="action")

    trc = trigger_sub.add_parser("create", help="Create an HTTP trigger")
    trc.add_argument("--name", required=True, help="Trigger name")
    trc.add_argument("--prompt", required=True, help="Agent prompt text")
    trc.add_argument("--description", default="", help="Trigger description")
    trc.add_argument("--agent", default="isucon", help="Agent name (default: isucon)")
    trc.add_argument("--mode", choices=["autonomous", "review"], default="autonomous", help="Agent mode")
    trc.add_argument("--thread-id", help="Existing thread ID to reuse")
    trc.set_defaults(func=cmd_trigger_create)

    trl = trigger_sub.add_parser("list", help="List triggers")
    trl.set_defaults(func=cmd_trigger_list)

    tre = trigger_sub.add_parser("execute", help="Execute a trigger")
    tre.add_argument("trigger_id", help="Trigger ID")
    tre.add_argument("--data", help="JSON payload to send")
    tre.set_defaults(func=cmd_trigger_execute)

    trd = trigger_sub.add_parser("delete", help="Delete a trigger")
    trd.add_argument("trigger_id", help="Trigger ID")
    trd.set_defaults(func=cmd_trigger_delete)

    # thread
    thread = sub.add_parser("thread", help="Manage threads")
    thread_sub = thread.add_subparsers(dest="action")

    thm = thread_sub.add_parser("messages", help="Get thread messages")
    thm.add_argument("thread_id", help="Thread ID")
    thm.add_argument("--top", type=int, default=20, help="Number of messages (default: 20)")
    thm.set_defaults(func=cmd_thread_messages)

    thw = thread_sub.add_parser("watch", help="Watch thread messages (poll)")
    thw.add_argument("thread_id", help="Thread ID")
    thw.add_argument("--interval", type=int, default=30, help="Poll interval in seconds (default: 30)")
    thw.set_defaults(func=cmd_thread_watch)

    # contest (shortcuts)
    contest = sub.add_parser("contest", help="Contest management shortcuts")
    contest_sub = contest.add_subparsers(dest="action")

    ck = contest_sub.add_parser("kick", help="Create trigger + execute + watch")
    ck.add_argument("--name", default="start-contest", help="Trigger name (default: start-contest)")
    ck.add_argument("--prompt", help="Custom agent prompt (default: standard ISUCON prompt)")
    ck.add_argument("--agent", default="isucon", help="Agent name (default: isucon)")
    ck.add_argument("--time-limit", type=int, default=60, help="Time limit in minutes (default: 60)")
    ck.add_argument("--no-watch", action="store_true", help="Don't watch after kick")
    ck.add_argument("--interval", type=int, default=30, help="Watch poll interval in seconds (default: 30)")
    ck.set_defaults(func=cmd_contest_kick)

    cw = contest_sub.add_parser("watch", help="Watch a contest thread")
    cw.add_argument("thread_id", help="Thread ID")
    cw.add_argument("--interval", type=int, default=30, help="Poll interval in seconds (default: 30)")
    cw.set_defaults(func=cmd_contest_watch)

    return p


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if not hasattr(args, "func"):
        parser.print_help()
        sys.exit(1)

    args.func(args)


if __name__ == "__main__":
    main()
