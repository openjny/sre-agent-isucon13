---
name: isucon-mcp-guide
description: Guide for using ISUCON MCP Server tools to interact with contest VMs, run benchmarks, and record findings
---

# MCP Tools Guide

## exec — Run commands on remote VMs

Execute shell commands on contest VMs via SSH. Commands run as the `isucon` user.

**Parameters:**
- `host` (required): `vm1`, `vm2`, or `vm3`
- `command` (required): Shell command to execute

| Host | IP | Role |
|------|-----|------|
| vm1 | 10.0.1.4 | Contest Server 1 |
| vm2 | 10.0.1.5 | Contest Server 2 |
| vm3 | 10.0.1.6 | Contest Server 3 |

Use `sudo` for privileged operations (e.g., `sudo systemctl restart mysql`).

## benchmark_start — Start a benchmark

Start the ISUCON13 benchmarker asynchronously. Returns a `job_id`. Only one benchmark can run at a time. Always poll `benchmark_status` after starting.

## benchmark_status — Check benchmark results

Returns status, score, and output. If `job_id` is omitted, returns the latest job.

**Parameters:**
- `job_id` (optional): Specific job ID

## benchmark_history — View score history

View past benchmark runs with scores and durations.

**Parameters:**
- `limit` (optional): Number of recent runs to display

## note_write — Write or append to a note

Record findings, changes, or build reports. Stored in persistent storage.

**Parameters:**
- `path` (required): File path (e.g., `report.md`, `logs/attempt-1.txt`)
- `content` (required): Text content
- `append` (optional): If true, append instead of overwrite

## note_read — Read a note

**Parameters:**
- `path` (required): File path to read
- `head` (optional): First N lines only
- `tail` (optional): Last N lines only (mutually exclusive with head)

## note_list — List notes

**Parameters:**
- `prefix` (optional): Filter by path prefix (e.g., `logs/`)

## Typical Workflow

1. Verify services: `exec host="vm1" command="systemctl status isupipe-go nginx mysql pdns --no-pager"`
2. Run benchmark: `benchmark_start`
3. Poll: `benchmark_status`
4. Check history: `benchmark_history limit=5`
5. Record findings: `note_write path="report.md" content="..." append=true`
