---
name: multi-server-distribution
description: Distribute ISUPIPE components across 3 contest VMs for optimal resource utilization — DB on vm1, App workers on vm2/vm3
---

# Multi-Server Distribution — ISUPIPE

The initial setup runs all components on each VM. Distributing them across VMs eliminates resource contention.

## Target Architecture

| VM | Components | Role |
|----|-----------|------|
| vm1 (10.0.1.4) | MySQL, PowerDNS, nginx (load balancer) | Database + DNS + LB |
| vm2 (10.0.1.5) | Go app (isupipe-go), nginx (local proxy) | App worker 1 |
| vm3 (10.0.1.6) | Go app (isupipe-go), nginx (local proxy) | App worker 2 |

## Step 1: Configure MySQL on vm1 to Accept Remote Connections

```bash
exec host="vm1" command="sudo sed -i 's/bind-address.*=.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf"
exec host="vm1" command="sudo mysql -u isucon -pisucon -e \"GRANT ALL PRIVILEGES ON *.* TO 'isucon'@'%' IDENTIFIED BY 'isucon'; FLUSH PRIVILEGES;\""
exec host="vm1" command="sudo systemctl restart mysql"
```

## Step 2: Point App Workers to vm1's MySQL

On vm2 and vm3, update the Go app environment:

```bash
# vm2
exec host="vm2" command="sudo sed -i 's|ISUCON13_MYSQL_DIALCONFIG_ADDRESS=.*|ISUCON13_MYSQL_DIALCONFIG_ADDRESS=10.0.1.4|' /home/isucon/env.sh"
exec host="vm2" command="sudo systemctl restart isupipe-go"

# vm3
exec host="vm3" command="sudo sed -i 's|ISUCON13_MYSQL_DIALCONFIG_ADDRESS=.*|ISUCON13_MYSQL_DIALCONFIG_ADDRESS=10.0.1.4|' /home/isucon/env.sh"
exec host="vm3" command="sudo systemctl restart isupipe-go"
```

## Step 3: Configure nginx on vm1 as Load Balancer

```bash
exec host="vm1" command="sudo tee /etc/nginx/sites-enabled/isupipe.conf << 'NGINX'
upstream app {
    server 10.0.1.5:443;
    server 10.0.1.6:443;
}

server {
    listen 443 ssl;
    server_name *.u.isucon.dev;

    ssl_certificate /etc/nginx/tls/_.u.isucon.dev.crt;
    ssl_certificate_key /etc/nginx/tls/_.u.isucon.dev.key;

    location / {
        proxy_pass https://app;
        proxy_http_version 1.1;
        proxy_set_header Connection \"\";
        proxy_set_header Host \\$host;
    }
}
NGINX"
exec host="vm1" command="sudo nginx -t && sudo systemctl reload nginx"
```

## Step 4: Stop Unnecessary Services

```bash
# Stop MySQL on vm2/vm3 (using vm1's MySQL now)
exec host="vm2" command="sudo systemctl stop mysql && sudo systemctl disable mysql"
exec host="vm3" command="sudo systemctl stop mysql && sudo systemctl disable mysql"

# Stop Go app on vm1 (vm1 is DB+LB only)
exec host="vm1" command="sudo systemctl stop isupipe-go && sudo systemctl disable isupipe-go"
```

## Step 5: Update PowerDNS Zone

Update DNS to return vm2/vm3 IPs for streaming subdomains:

```bash
exec host="vm1" command="mysql -u isucon -pisucon isudns -e \"UPDATE records SET content='10.0.1.5' WHERE type='A' AND name LIKE '%.u.isucon.dev' LIMIT 1;\""
```

## Verification

```bash
exec host="vm1" command="curl -sk https://pipe.u.isucon.dev/api/tag"
```

## Expected Impact

- VM1 dedicated to DB → larger buffer pool, no CPU contention
- VM2/VM3 dedicated to app → full CPU for Go processing
- Typical improvement: +20,000-50,000 score
