---
name: slow-query-analysis
description: Enable MySQL slow query log and use pt-query-digest to identify the most expensive database queries
---

# Slow Query Analysis — MySQL

Identify the most expensive MySQL queries using the slow query log and pt-query-digest.

## Enable Slow Query Log

```bash
exec host="vm1" command="sudo mysql -u isucon -pisucon -e \"
SET GLOBAL slow_query_log = 'ON';
SET GLOBAL slow_query_log_file = '/var/log/mysql/slow.log';
SET GLOBAL long_query_time = 0.01;
\""
```

**Note:** `long_query_time = 0.01` captures queries taking >10ms. For initial analysis, 0.1 (100ms) may be sufficient.

## Install pt-query-digest

```bash
exec host="vm1" command="which pt-query-digest || sudo apt-get install -y percona-toolkit"
```

## Workflow

1. Clear the slow query log:
   ```bash
   exec host="vm1" command="sudo truncate -s 0 /var/log/mysql/slow.log"
   ```

2. Run a benchmark:
   ```
   benchmark_start
   ```

3. Analyze results:
   ```bash
   exec host="vm1" command="sudo pt-query-digest /var/log/mysql/slow.log --limit 10"
   ```

## Reading pt-query-digest Output

### Key Sections

1. **Profile** — Top queries by total time:
   ```
   Rank  Query ID                          Response time  Calls  R/Call
   ====  ================================  =============  =====  ======
      1  0x1234567890ABCDEF...             150.0000 45.0%   500  0.3000
   ```

2. **Per-query details** — Full SQL, EXPLAIN output, index usage

### What to Look For

| Pattern | Issue | Fix |
|---------|-------|-----|
| High R/Call, low Calls | Single slow query | Add index, rewrite query |
| Low R/Call, high Calls | N+1 pattern | Batch or JOIN |
| Full table scan in EXPLAIN | Missing index | Add appropriate index |
| filesort in EXPLAIN | Sorting without index | Add composite index |

## Quick Analysis (without pt-query-digest)

```bash
exec host="vm1" command="sudo tail -200 /var/log/mysql/slow.log | grep -E 'Query_time|^SELECT|^UPDATE|^INSERT'"
```

## Disable After Analysis

To avoid log file growth during production benchmarks:

```bash
exec host="vm1" command="sudo mysql -u isucon -pisucon -e \"SET GLOBAL slow_query_log = 'OFF'\""
```
