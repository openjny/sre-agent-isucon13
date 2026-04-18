#!/usr/bin/env python3
"""Convert our flat YAML agent spec to SRE Agent dataplane v2 API JSON."""
import yaml, json, sys

yaml_file = sys.argv[1]
with open(yaml_file) as f:
    spec = yaml.safe_load(f)

api_body = {
    "name": spec["name"],
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
    }
}
print(json.dumps(api_body))
