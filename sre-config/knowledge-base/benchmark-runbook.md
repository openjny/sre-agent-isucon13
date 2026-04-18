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

```
exec bench "sudo -u isucon /home/isucon/run-benchmark.sh"
```

### Pretest only (validation without load):
```
exec bench "sudo -u isucon /home/isucon/run-benchmark.sh --pretest-only"
```

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
- **Initialization timeout (42s)**: init.sh or POST /api/initialize too slow

## Post-Benchmark Analysis

1. **Check nginx access log patterns**:
   ```
   exec vm1 "tail -1000 /var/log/nginx/access.log | awk '{print $7}' | sort | uniq -c | sort -rn | head -20"
   ```

2. **Check MySQL slow queries** (if enabled):
   ```
   exec vm1 "sudo tail -100 /var/log/mysql/slow.log"
   ```

3. **Check system resources during benchmark**:
   ```
   exec vm1 "dmesg | tail -20"
   exec vm1 "journalctl -u isupipe-go --no-pager -n 50 --since '5 minutes ago'"
   ```
