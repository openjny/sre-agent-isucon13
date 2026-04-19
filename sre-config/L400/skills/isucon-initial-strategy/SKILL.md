---
name: isucon-initial-strategy
description: First 30 minutes strategy checklist for ISUCON competitions — what to do immediately after the contest starts
---

# ISUCON Initial Strategy — First 30 Minutes

A structured approach for the opening phase of an ISUCON competition.

## Minute 0-5: Environment Check

1. **Verify all services are running**:
   ```
   exec host="vm1" command="systemctl status isupipe-go nginx mysql pdns --no-pager"
   exec host="vm2" command="systemctl status isupipe-go nginx mysql pdns --no-pager"
   exec host="vm3" command="systemctl status isupipe-go nginx mysql pdns --no-pager"
   ```

2. **Check system resources**:
   ```
   exec host="vm1" command="free -h && df -h && nproc"
   ```

3. **Get baseline benchmark score**:
   ```
   benchmark_start
   ```

## Minute 5-15: Profiling Setup

4. **Enable slow query log**:
   ```
   exec host="vm1" command="sudo mysql -u isucon -pisucon -e \"SET GLOBAL slow_query_log = 'ON'; SET GLOBAL long_query_time = 0.01;\""
   ```

5. **Install alp** (if available in skill):
   ```
   exec host="vm1" command="wget -q https://github.com/tkuchiki/alp/releases/download/v1.0.21/alp_linux_amd64.tar.gz -O /tmp/alp.tar.gz && cd /tmp && tar xzf alp.tar.gz && sudo mv alp /usr/local/bin/"
   ```

6. **Read the application source**:
   ```
   exec host="vm1" command="ls /home/isucon/isucon13/webapp/go/"
   exec host="vm1" command="wc -l /home/isucon/isucon13/webapp/go/*.go"
   ```

7. **Read the database schema**:
   ```
   exec host="vm1" command="cat /home/isucon/isucon13/webapp/sql/initdb.d/10_schema.sql"
   ```

## Minute 15-25: Quick Wins

8. **Add missing indexes** (almost always the #1 quick win):
   - Check existing indexes: `SHOW INDEX FROM <table>`
   - Add indexes for foreign keys and WHERE clauses

9. **Check for obvious N+1 patterns**:
   ```
   exec host="vm1" command="grep -n 'for.*range\|\.Get\|\.Select\|\.Query' /home/isucon/isucon13/webapp/go/*.go | head -30"
   ```

10. **Run profiling benchmark**:
    ```
    exec host="vm1" command="sudo truncate -s 0 /var/log/nginx/access.log"
    benchmark_start
    ```

## Minute 25-30: Analyze & Plan

11. **Analyze results**:
    - alp output → identify slowest endpoints
    - pt-query-digest → identify slowest queries
    - Compare with baseline score

12. **Prioritize next steps** based on data:
    - Fix the single biggest bottleneck first
    - Always validate with `--pretest-only` before full benchmark

## Anti-Patterns to Avoid

| Don't | Do Instead |
|-------|------------|
| Optimize without profiling | Always measure first |
| Change multiple things at once | One change → one benchmark |
| Skip pretest validation | Always `--pretest-only` before full run |
| Forget to persist index changes | Add to schema.sql or init script |
| Ignore benchmark errors | Fix 5xx/timeout errors before optimizing |
