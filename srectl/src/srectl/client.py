"""HTTP client and Azure authentication for SRE Agent dataplane API."""

from __future__ import annotations

import io
import json
import subprocess
import urllib.error
import urllib.request
import uuid

from srectl.output import die


def run_cmd(cmd: list[str]) -> str:
    """Run a subprocess and return stripped stdout, or empty string on failure."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return r.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""


def resolve_endpoint(rg: str | None = None) -> tuple[str, str]:
    """Resolve SRE Agent endpoint. Returns (agent_name, endpoint_url)."""
    agent_name = run_cmd(["azd", "env", "get-value", "SRE_AGENT_NAME"])
    endpoint = run_cmd(["azd", "env", "get-value", "SRE_AGENT_ENDPOINT"])
    if agent_name and endpoint:
        return agent_name, endpoint

    if not rg:
        rg = run_cmd(["azd", "env", "get-value", "SREAGENT_RESOURCE_GROUP"])
    if not rg:
        rg = "rg-isucon13-sreagent"

    if not agent_name:
        agent_name = run_cmd([
            "az", "resource", "list", "-g", rg,
            "--resource-type", "Microsoft.App/agents",
            "--query", "[0].name", "-o", "tsv",
        ])
    if not agent_name:
        die(f"No SRE Agent found in {rg}")

    if not endpoint:
        endpoint = run_cmd([
            "az", "resource", "show", "-g", rg, "-n", agent_name,
            "--resource-type", "Microsoft.App/agents",
            "--api-version", "2025-05-01-preview",
            "--query", "properties.agentEndpoint", "-o", "tsv",
        ])
    if not endpoint:
        die("Could not resolve agent endpoint")

    return agent_name, endpoint


def get_token() -> str:
    """Get Azure SRE Agent dataplane token."""
    token = run_cmd([
        "az", "account", "get-access-token",
        "--resource", "https://azuresre.ai",
        "--query", "accessToken", "-o", "tsv",
    ])
    if not token:
        die("Failed to get access token (az account get-access-token)")
    return token


def get_arm_token() -> str:
    """Get Azure ARM token."""
    token = run_cmd([
        "az", "account", "get-access-token",
        "--resource", "https://management.azure.com",
        "--query", "accessToken", "-o", "tsv",
    ])
    if not token:
        die("Failed to get ARM access token")
    return token


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
    """Build a multipart/form-data body."""
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


# ── Context caching ──────────────────────────────────────────────────────────

_cached_ctx: tuple[str, str] | None = None


def get_ctx(args) -> tuple[str, str]:
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
