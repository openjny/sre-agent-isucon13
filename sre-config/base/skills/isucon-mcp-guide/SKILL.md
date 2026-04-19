---
name: isucon-mcp-guide
description: Guide for using ISUCON MCP Server tools (exec, benchmark_start, benchmark_status) to interact with contest VMs and run benchmarks
---

# MCP Tools Guide

This skill explains how to use the ISUCON MCP Server tools to interact with contest VMs and manage benchmarks.

## Available Tools

### exec — Run commands on remote VMs

Execute shell commands on contest or benchmark VMs via SSH.

**Parameters:**
- `host` (required): Target VM — `vm1`, `vm2`, `vm3`, or `bench`
- `command` (required): Shell command to execute

**Host mapping:**
| Host | IP | Role |
|------|-----|------|
| vm1 | 10.0.1.4 | Contest Server 1 |
| vm2 | 10.0.1.5 | Contest Server 2 |
| vm3 | 10.0.1.6 | Contest Server 3 |
| bench | 10.0.1.7 | Benchmark Server |

**Examples:**
```
exec host="vm1" command="systemctl status isupipe-go nginx mysql pdns --no-pager"
exec host="vm1" command="top -bn1 | head -20"
exec host="vm1" command="mysql -u isucon -pisucon isupipe -e 'SHOW PROCESSLIST'"
exec host="bench" command="cat /home/isucon/run-benchmark.sh"
```

**Notes:**
- Commands run as the `isucon` user
- 10-second timeout per connection
- Use `sudo` for privileged operations (e.g., `sudo systemctl restart mysql`)

### benchmark_start — Start a benchmark

Start the ISUCON13 benchmarker asynchronously. Returns a `job_id` immediately.

**Parameters:**
- `options` (optional): Benchmarker options (e.g., `--pretest-only`)

**Examples:**
```
benchmark_start                           # Full benchmark (~2 min)
benchmark_start options="--pretest-only"  # Validation only (~45 sec)
```

**Notes:**
- Only one benchmark can run at a time (exclusive lock)
- The benchmark runs `sudo -u isucon /home/isucon/run-benchmark.sh [options]` on the bench VM
- Always poll `benchmark_status` after starting — the benchmark runs asynchronously

### benchmark_status — Check benchmark results

Poll the status and results of a benchmark job.

**Parameters:**
- `job_id` (optional): Specific job ID. If omitted, returns the latest job.

**Returns:**
- `status`: running, completed, failed
- `score`: ISUCOIN score (parsed from output)
- `output`: Full benchmark output
- `error`: Error message if failed

**Example:**
```
benchmark_status job_id="abc123"
benchmark_status  # latest job
```

## Typical Workflow

1. **Verify services** before benchmarking:
   ```
   exec host="vm1" command="systemctl status isupipe-go nginx mysql pdns --no-pager"
   ```

2. **Initialize data** (resets DB to clean state):
   ```
   exec host="vm1" command="cd /home/isucon/isucon13/webapp/sql && sudo -u isucon bash init.sh"
   ```

3. **Run pretest** to validate changes:
   ```
   benchmark_start options="--pretest-only"
   ```

4. **Poll until complete**:
   ```
   benchmark_status
   ```

5. **If pretest passes, run full benchmark**:
   ```
   benchmark_start
   ```

6. **Check final score**:
   ```
   benchmark_status
   ```
