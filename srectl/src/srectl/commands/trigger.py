"""Trigger, thread, and contest commands."""

from __future__ import annotations

import argparse
import json
import sys
import time

from srectl.client import api_request, get_ctx
from srectl.output import die, ok, print_json


# ── Trigger ──────────────────────────────────────────────────────────────────


def cmd_trigger_create(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
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
            if getattr(args, "output", "text") == "json":
                print_json(data)
            else:
                print(f"Trigger ID:  {data.get('triggerId', '?')}")
                print(f"Trigger URL: {data.get('triggerUrl', '?')}")
                ok(f"trigger/{args.name}")
        else:
            print_json(data)
    else:
        die(f"trigger/{args.name}: HTTP {code} — {data}")


def cmd_trigger_list(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(endpoint, token, "GET", "/api/v1/httptriggers")
    if code != 200:
        die(f"HTTP {code}: {data}")
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
    endpoint, token = get_ctx(args)
    trigger_id = args.trigger_id

    payload: dict | None = None
    if args.data:
        try:
            payload = json.loads(args.data)
        except json.JSONDecodeError:
            die(f"Invalid JSON: {args.data}")

    code, data = api_request(endpoint, token, "POST", f"/api/v1/httptriggers/{trigger_id}/execute", body=payload)
    if code in (200, 202):
        if isinstance(data, dict):
            if getattr(args, "output", "text") == "json":
                print_json(data)
            else:
                execution = data.get("execution", data)
                print(f"Thread ID: {execution.get('threadId', '?')}")
                ok("trigger executed")
        else:
            print_json(data)
    else:
        die(f"trigger execute: HTTP {code} — {data}")


def cmd_trigger_delete(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    code, data = api_request(endpoint, token, "DELETE", f"/api/v1/httptriggers/{args.trigger_id}")
    if code in (200, 202, 204, 404):
        ok(f"deleted trigger/{args.trigger_id}")
    else:
        die(f"trigger: HTTP {code}")


# ── Thread ───────────────────────────────────────────────────────────────────


def _fetch_messages(endpoint: str, token: str, thread_id: str, top: int = 20, skip: int = 0) -> list:
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
    author = msg.get("author", {})
    role = author.get("role", "?") if isinstance(author, dict) else "?"
    ts = msg.get("timeStamp", msg.get("timestamp", ""))
    content = msg.get("text", "")

    role_map = {"SREAgent": "agent", "User": "user", "System": "system"}
    role = role_map.get(role, role)

    if not content or not content.strip():
        return ""
    if len(content) > 500:
        content = content[:500] + "..."
    if "T" in ts:
        ts = ts.split("T")[1][:8]
    return f"[{ts}] {role}: {content}"


def _watch_loop(endpoint: str, token: str, thread_id: str, interval: int) -> None:
    """Shared watch loop for thread watch and contest watch."""
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
            print(f"--- ({interval}s) ---", flush=True)
            time.sleep(interval)
    except KeyboardInterrupt:
        print("\n(stopped)")


def cmd_thread_messages(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    messages = _fetch_messages(endpoint, token, args.thread_id, top=args.top)
    if not messages:
        print("(no messages)")
        return
    for msg in reversed(messages):
        line = _format_message(msg)
        if line:
            print(line, flush=True)


def cmd_thread_watch(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    print(f"Watching thread {args.thread_id} (Ctrl+C to stop, polling every {args.interval}s)")
    print("-" * 60)
    _watch_loop(endpoint, token, args.thread_id, args.interval)


# ── Contest ───────────────────────────────────────────────────────────────────


def cmd_contest_kick(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)

    time_limit = args.time_limit
    prompt = args.prompt or f"ISUCON の競技を開始してください。制限時間は今から{time_limit}分です。その間は何回でもベンチマークを走らせて良いですが、最後に回したベンチマークのスコアがあなたの得点になります。"
    agent = args.agent or "isucon"
    trigger_name = args.name or "start-contest"

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
        die(f"Failed to create trigger: HTTP {code} — {data}")

    trigger_id = data.get("triggerId", "") if isinstance(data, dict) else ""
    if not trigger_id:
        die(f"No triggerId in response: {data}")
    print(f"  Trigger ID: {trigger_id}")

    print("Executing trigger...")
    code, data = api_request(endpoint, token, "POST", f"/api/v1/httptriggers/{trigger_id}/execute")
    if code not in (200, 202):
        die(f"Failed to execute trigger: HTTP {code} — {data}")

    execution = data.get("execution", data) if isinstance(data, dict) else {}
    thread_id = execution.get("threadId", "")
    if not thread_id:
        die(f"No threadId in response: {data}")

    print(f"  Thread ID:  {thread_id}")
    print(f"  Portal:     https://sre.azure.com")
    ok(f"Contest kicked! Time limit: {time_limit}min")
    print("")

    if not args.no_watch:
        print(f"Watching thread (Ctrl+C to stop, polling every {args.interval}s)")
        print("-" * 60)
        _watch_loop(endpoint, token, thread_id, args.interval)


def cmd_contest_watch(args: argparse.Namespace) -> None:
    endpoint, token = get_ctx(args)
    print(f"Watching contest thread {args.thread_id} (Ctrl+C to stop)")
    print("-" * 60)
    _watch_loop(endpoint, token, args.thread_id, args.interval)
