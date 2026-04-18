#!/usr/bin/env python3
"""Convert flat YAML agent spec to SRE Agent dataplane v2 API JSON.
No external dependencies."""
import json, sys, re

def parse_simple_yaml(text):
    result = {}
    current_key = None
    current_multiline = None
    for line in text.split('\n'):
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            if current_multiline is not None:
                current_multiline += '\n'
            continue
        if current_multiline is not None:
            if len(line) > 0 and not line[0].isspace() and ':' in stripped and not stripped.startswith('-'):
                result[current_key] = current_multiline.strip()
                current_multiline = None
            else:
                current_multiline += line.rstrip() + '\n'
                continue
        m = re.match(r'^(\w[\w_]*)\s*:\s*(.*)', line)
        if m:
            key, val = m.group(1), m.group(2).strip()
            current_key = key
            if val == '|':
                current_multiline = ''
            elif val.lower() in ('true', 'false'):
                result[key] = val.lower() == 'true'
            elif val:
                result[key] = val
            else:
                result[key] = []
            continue
        m = re.match(r'^\s*-\s+(.*)', line)
        if m and current_key:
            val = m.group(1).strip().strip('"').strip("'")
            if not isinstance(result.get(current_key), list):
                result[current_key] = []
            result[current_key].append(val)
    if current_multiline is not None and current_key:
        result[current_key] = current_multiline.strip()
    return result

yaml_file = sys.argv[1]
with open(yaml_file) as f:
    spec = parse_simple_yaml(f.read())

if len(sys.argv) > 2 and sys.argv[2] == '--name-only':
    print(spec.get('name', ''))
    sys.exit(0)

api_body = {
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
    }
}
print(json.dumps(api_body))
