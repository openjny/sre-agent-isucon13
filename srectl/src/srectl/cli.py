"""CLI entrypoint — argparse setup and dispatch."""

from __future__ import annotations

import argparse
import sys

from srectl.commands.agent import cmd_agent_apply, cmd_agent_delete, cmd_agent_get, cmd_agent_list, cmd_context
from srectl.commands.knowledge import (
    cmd_auth_github_delete,
    cmd_auth_github_set,
    cmd_connector_delete,
    cmd_connector_get,
    cmd_connector_list,
    cmd_knowledge_file_add,
    cmd_knowledge_file_delete,
    cmd_knowledge_file_list,
    cmd_knowledge_repo_add,
    cmd_knowledge_repo_delete,
    cmd_knowledge_repo_list,
    cmd_knowledge_web_add,
    cmd_knowledge_web_delete,
    cmd_knowledge_web_list,
    cmd_mcp_add,
)
from srectl.commands.memory import cmd_memory_add, cmd_memory_list
from srectl.commands.skill import cmd_skill_add, cmd_skill_delete, cmd_skill_get, cmd_skill_list
from srectl.commands.tool import (
    cmd_hook_add,
    cmd_hook_delete,
    cmd_hook_get,
    cmd_hook_list,
    cmd_tool_add,
    cmd_tool_delete,
    cmd_tool_list,
)
from srectl.commands.trigger import (
    cmd_contest_kick,
    cmd_contest_watch,
    cmd_thread_messages,
    cmd_thread_watch,
    cmd_trigger_create,
    cmd_trigger_delete,
    cmd_trigger_execute,
    cmd_trigger_list,
)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="srectl", description="SRE Agent CLI")
    p.add_argument("--endpoint", help="Override agent endpoint URL")
    p.add_argument("--token", help="Override bearer token")
    p.add_argument("-o", "--output", choices=["text", "json"], default="text", help="Output format (default: text)")

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

    aa = agent_sub.add_parser("apply", help="Create/update agent from YAML")
    aa.add_argument("-f", "--file", required=True, help="Agent YAML file")
    aa.add_argument("--strip-handoffs", action="store_true", help="Remove handoffs before applying (for two-pass creation)")
    aa.set_defaults(func=cmd_agent_apply)

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

    # mcp
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

    # contest
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
