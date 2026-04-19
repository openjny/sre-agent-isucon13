"""YAML parsing and API payload mapping."""

from __future__ import annotations

import os
import re

import yaml

from srectl.output import die


def agent_yaml_to_api(spec: dict) -> dict:
    """Convert parsed agent YAML to SRE Agent API JSON body.

    Supports both legacy flat format and v2 official format:
      Legacy: {name, system_prompt, handoffs, tools, mcp_tools, ...}
      v2:     {kind: ExtendedAgent, metadata: {name}, spec: {instructions, ...}}
    """
    if "kind" in spec and "spec" in spec:
        name = spec.get("metadata", {}).get("name", "")
        s = spec.get("spec", {})
        body: dict = {
            "name": name,
            "type": "ExtendedAgent",
            "properties": {
                "instructions": s.get("instructions", ""),
                "handoffDescription": s.get("handoffDescription", ""),
                "handoffs": s.get("handoffs", []),
                "tools": s.get("tools", []),
                "mcpTools": s.get("mcpTools", []),
                "allowParallelToolCalls": True,
                "enableSkills": s.get("enableSkills", True),
                "allowedSkills": s.get("allowedSkills", []),
            },
        }
        hooks = s.get("hooks")
        if hooks:
            body["properties"]["hooks"] = hooks
        return body

    # Legacy flat format
    return {
        "name": spec.get("name", ""),
        "type": "ExtendedAgent",
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


def parse_agent_yaml(path: str) -> dict:
    """Parse an agent YAML file and return API body."""
    with open(path) as f:
        spec = yaml.safe_load(f)
    return agent_yaml_to_api(spec)


def parse_skill_dir(skill_dir: str) -> tuple[str, str, str]:
    """Parse a skill directory containing SKILL.md.

    Returns (skill_name, description, skill_content).
    """
    skill_name = os.path.basename(os.path.normpath(skill_dir))
    skill_md = os.path.join(skill_dir, "SKILL.md")
    if not os.path.isfile(skill_md):
        die(f"SKILL.md not found in {skill_dir}")

    with open(skill_md) as f:
        content = f.read()

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
