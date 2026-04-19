# Benchmark Runbook

## Pre-Benchmark Checklist

1. **Verify all services are running** on each contest VM:
   ```
   exec vm1 "systemctl status isupipe-go nginx mysql pdns --no-pager"
   exec vm2 "systemctl status isupipe-go nginx mysql pdns --no-pager"
   exec vm3 "systemctl status isupipe-go nginx mysql pdns --no-pager"
   ```

2. **Verify DNS resolution**:
   ```
   exec vm1 "dig pipe.u.isucon.dev @127.0.0.1 +short"
   ```

3. **Verify HTTPS endpoint**:
   ```
   exec vm1 "curl -sk https://pipe.u.isucon.dev/api/tag"
   ```

4. **Initialize data** (resets DB to clean state):
   ```
   exec vm1 "cd /home/isucon/isucon13/webapp/sql && sudo -u isucon bash init.sh"
   ```

5. **Clear logs** (optional, for clean analysis):
   ```
   exec vm1 "sudo truncate -s 0 /var/log/nginx/access.log"
   exec vm1 "sudo truncate -s 0 /var/log/mysql/slow.log"
   ```

## Running the Benchmark

Use the dedicated benchmark tools instead of exec:

```
benchmark_start
```

### Pretest only (validation without load):
```
benchmark_start --pretest-only
```

### Check benchmark progress/results:
```
benchmark_status <job_id>
```

If job_id is omitted, returns the latest job.

## Interpreting Results

### Score
- Score = total ISUCOIN (tips) during 60s load test
- Initial: ~3,600
- Good: 10,000-50,000
- Excellent: 50,000-200,000
- Competition winner: 468,006

### Common Errors
- **DNS timeout**: PowerDNS too slow, consider caching or DNS optimization
- **HTTP 5xx**: Application crash or database connection issues
- **HTTP timeout**: Slow queries blocking request processing
