---
name: nginx-tuning
description: Tune nginx worker processes, connection handling, keepalive, and logging for ISUCON workloads
---

# nginx Tuning — ISUPIPE

Optimize nginx reverse proxy for high-concurrency ISUCON benchmarks.

## Key Settings

Edit `/etc/nginx/nginx.conf`:

```nginx
worker_processes auto;          # Match CPU cores (default: 1)
worker_rlimit_nofile 65535;     # File descriptor limit per worker

events {
    worker_connections 4096;    # Connections per worker (default: 512)
    multi_accept on;            # Accept multiple connections at once
    use epoll;                  # Linux-optimized event model
}

http {
    # Keepalive to backend Go app
    upstream app {
        server 127.0.0.1:8080;
        keepalive 64;           # Persistent connections to upstream
    }

    # TCP optimizations
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;

    # Timeouts
    keepalive_timeout 65;
    keepalive_requests 10000;

    # Buffer sizes
    client_body_buffer_size 16k;
    proxy_buffering on;
    proxy_buffer_size 8k;
    proxy_buffers 8 8k;

    # Disable access log for performance (after profiling is done)
    # access_log off;
}
```

## Update Site Config

In `/etc/nginx/sites-enabled/isupipe.conf`, update the proxy_pass to use upstream with keepalive:

```nginx
location / {
    proxy_pass http://app;
    proxy_http_version 1.1;           # Required for keepalive
    proxy_set_header Connection "";    # Required for keepalive
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
```

## Apply Changes

```bash
exec host="vm1" command="sudo nginx -t && sudo systemctl reload nginx"
```

## LTSV Log Format for Profiling

If using alp for profiling, configure LTSV log format (see alp-profiling skill). After profiling is complete, consider disabling access logging to reduce I/O:

```nginx
access_log off;
```

## Static File Serving

If icons are moved to filesystem (see icon-caching skill), add:

```nginx
location ~ ^/api/user/[^/]+/icon$ {
    root /home/isucon/isucon13/webapp/public;
    try_files /icons/$arg_user_id.jpg @app;
}
location @app {
    proxy_pass http://app;
}
```

## Expected Impact

- Keepalive eliminates connection setup overhead to backend
- worker_processes auto uses all CPU cores
- Typical improvement: +500-2,000 score
