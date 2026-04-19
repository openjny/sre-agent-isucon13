---
name: alp-profiling
description: Install and use alp (Access Log Profiler) to identify slow nginx endpoints and analyze request patterns
---

# alp Profiling — nginx Access Log Analysis

alp analyzes nginx access logs in LTSV format to identify the slowest endpoints.

## Install alp

```bash
exec host="vm1" command="wget -q https://github.com/tkuchiki/alp/releases/download/v1.0.21/alp_linux_amd64.tar.gz -O /tmp/alp.tar.gz && cd /tmp && tar xzf alp.tar.gz && sudo mv alp /usr/local/bin/ && alp --version"
```

## Configure nginx for LTSV

Update nginx log format in `/etc/nginx/nginx.conf`:

```nginx
log_format ltsv "time:$time_local"
                "\thost:$remote_addr"
                "\tforwardedfor:$http_x_forwarded_for"
                "\treq:$request"
                "\tstatus:$status"
                "\tmethod:$request_method"
                "\turi:$request_uri"
                "\tsize:$body_bytes_sent"
                "\treferer:$http_referer"
                "\tua:$http_user_agent"
                "\treqtime:$request_time"
                "\tcache:$upstream_http_x_cache"
                "\truntime:$upstream_http_x_runtime"
                "\tapptime:$upstream_response_time"
                "\tvhost:$host";

access_log /var/log/nginx/access.log ltsv;
```

Then reload nginx:
```bash
exec host="vm1" command="sudo nginx -t && sudo systemctl reload nginx"
```

## Usage

After running a benchmark:

```bash
# Sort by total time (most impactful endpoints)
exec host="vm1" command="sudo alp ltsv --file /var/log/nginx/access.log --sort sum -r"

# Group parameterized URLs
exec host="vm1" command="sudo alp ltsv --file /var/log/nginx/access.log --sort sum -r -m '/api/user/[^/]+/icon,/api/user/[^/]+/statistics,/api/user/[^/]+$,/api/livestream/[0-9]+/statistics,/api/livestream/[0-9]+/livecomment,/api/livestream/[0-9]+/reaction,/api/livestream/[0-9]+$'"
```

## Key Metrics

| Column | Meaning |
|--------|---------|
| COUNT | Number of requests |
| SUM | Total response time |
| AVG | Average response time |
| MAX | Maximum response time |
| P99 | 99th percentile response time |

## Workflow

1. Clear logs: `exec host="vm1" command="sudo truncate -s 0 /var/log/nginx/access.log"`
2. Run benchmark: `benchmark_start`
3. Wait for completion: `benchmark_status`
4. Analyze: Run alp with `-m` grouping
5. Focus on endpoints with highest SUM (total time)
