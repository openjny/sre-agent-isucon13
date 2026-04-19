---
name: dns-optimization
description: Optimize PowerDNS performance against DNS water torture attacks during ISUCON13 benchmark
---

# DNS Optimization — ISUPIPE

The ISUCON13 benchmark includes a "DNS water torture attack" — massive random subdomain queries that overwhelm PowerDNS with MySQL backend.

## Problem

- Benchmarker queries random subdomains like `randomuser123.u.isucon.dev`
- Each query hits PowerDNS → MySQL lookup in `isudns.records` table
- Thousands of queries/second → MySQL becomes bottleneck

## Fix 1: Add Indexes to isudns Tables

```bash
exec host="vm1" command="mysql -u isucon -pisucon isudns -e \"
SHOW INDEX FROM records;
ALTER TABLE records ADD INDEX idx_name_type (name, type);
ALTER TABLE records ADD INDEX idx_domain_id (domain_id);
\""
```

## Fix 2: Increase PowerDNS Cache

Edit `/etc/powerdns/pdns.conf`:

```bash
exec host="vm1" command="sudo tee -a /etc/powerdns/pdns.conf << 'EOF'
query-cache-ttl=60
negquery-cache-ttl=60
cache-ttl=60
EOF"
exec host="vm1" command="sudo systemctl restart pdns"
```

## Fix 3: Application-Level DNS (Advanced)

Bypass PowerDNS entirely by handling DNS in the Go app:

1. Register user subdomains in-memory when users are created
2. Implement a simple DNS responder or use PowerDNS pipe backend
3. For ISUCON13, the main bottleneck is NXDOMAIN lookups — cache negative results

## Fix 4: Reduce DNS Query Volume

The benchmarker resolves subdomains for each virtual user. If you use multi-server distribution, configure the benchmark to use specific IPs:

```bash
# Check current DNS setup
exec host="vm1" command="dig pipe.u.isucon.dev @127.0.0.1 +short"

# Ensure DNS returns appropriate IPs
exec host="vm1" command="mysql -u isucon -pisucon isudns -e \"SELECT * FROM records WHERE type='A' AND name LIKE '%.u.isucon.dev' LIMIT 10;\""
```

## Verification

```bash
# Test DNS resolution speed
exec host="vm1" command="time for i in $(seq 1 100); do dig +short test\$i.u.isucon.dev @127.0.0.1 > /dev/null; done"
```

## Expected Impact

- Index + cache: reduces DNS query time by 10-50x
- Application-level DNS: eliminates MySQL overhead entirely
- Typical improvement: +5,000-15,000 score
