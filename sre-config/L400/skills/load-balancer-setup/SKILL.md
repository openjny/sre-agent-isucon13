---
name: load-balancer-setup
description: Configure nginx as a load balancer distributing traffic across multiple Go app workers
---

# Load Balancer Setup — nginx upstream

Configure nginx on vm1 to distribute requests across app workers on vm2/vm3.

## Basic Upstream Configuration

```nginx
upstream app {
    server 10.0.1.5:443;    # vm2
    server 10.0.1.6:443;    # vm3
    keepalive 64;
}
```

## Weighted Distribution

If one VM has more resources, use weights:

```nginx
upstream app {
    server 10.0.1.5:443 weight=3;   # vm2: more powerful
    server 10.0.1.6:443 weight=2;   # vm3
    keepalive 64;
}
```

## Full Site Config

```bash
exec host="vm1" command="sudo tee /etc/nginx/sites-enabled/isupipe.conf << 'NGINX'
upstream app {
    server 10.0.1.5:443;
    server 10.0.1.6:443;
    keepalive 64;
}

server {
    listen 443 ssl http2;
    server_name *.u.isucon.dev;

    ssl_certificate /etc/nginx/tls/_.u.isucon.dev.crt;
    ssl_certificate_key /etc/nginx/tls/_.u.isucon.dev.key;

    proxy_http_version 1.1;
    proxy_set_header Connection \"\";
    proxy_set_header Host \\$host;
    proxy_set_header X-Real-IP \\$remote_addr;
    proxy_set_header X-Forwarded-For \\$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;

    location / {
        proxy_pass https://app;
    }
}
NGINX"
exec host="vm1" command="sudo nginx -t && sudo systemctl reload nginx"
```

## Health Checks

Add passive health checks to remove failed backends:

```nginx
upstream app {
    server 10.0.1.5:443 max_fails=3 fail_timeout=10s;
    server 10.0.1.6:443 max_fails=3 fail_timeout=10s;
    keepalive 64;
}
```

## Sticky Sessions (if needed)

If the app stores session state locally (not in MySQL), use ip_hash:

```nginx
upstream app {
    ip_hash;
    server 10.0.1.5:443;
    server 10.0.1.6:443;
}
```

**Note:** ISUPIPE stores sessions in cookies with MySQL, so sticky sessions are not required.

## Verification

```bash
exec host="vm1" command="curl -sk -o /dev/null -w '%{http_code}' https://pipe.u.isucon.dev/api/tag"
```

## Expected Impact

- Doubles request throughput (2 app workers instead of 1)
- Typically combined with multi-server-distribution skill
