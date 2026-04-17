# ISUPIPE Optimization Guide

## Tier 1: Database Indexing (Highest ROI)

### Missing indexes in initial schema
```sql
ALTER TABLE livestreams ADD INDEX idx_user_id (user_id);
ALTER TABLE livecomments ADD INDEX idx_livestream_id (livestream_id);
ALTER TABLE reactions ADD INDEX idx_livestream_id (livestream_id);
ALTER TABLE livecomments ADD INDEX idx_livestream_id_created_at (livestream_id, created_at);
ALTER TABLE icons ADD INDEX idx_user_id (user_id);
ALTER TABLE livestream_tags ADD INDEX idx_livestream_id (livestream_id);
ALTER TABLE themes ADD INDEX idx_user_id (user_id);
```

### How to apply
```bash
mysql -u isucon -pisucon isupipe -e "ALTER TABLE livestreams ADD INDEX idx_user_id (user_id);"
# Repeat for each index
```

## Tier 2: N+1 Query Elimination

### Problem areas
- `GET /api/user/:username/statistics` — loops over all livestreams, counting tips/reactions per stream
- `GET /api/livestream/:id/statistics` — similar pattern
- User info fetching in comment/reaction lists

### Fix pattern
Replace individual queries in loops with JOINs:
```sql
-- Instead of querying per livestream in a loop:
SELECT IFNULL(SUM(tip), 0) FROM livecomments 
  INNER JOIN livestreams ON livestreams.id = livecomments.livestream_id 
  WHERE livestreams.user_id = ?
```

## Tier 3: Icon Image Caching (304 responses)

### Current behavior
- Every icon request reads LONGBLOB from MySQL
- Benchmark client sends `If-None-Match` header with icon_hash

### Fix
1. Compute SHA256 hash of icon data
2. Store hash alongside icon or compute on read
3. Compare with `If-None-Match` header, return 304 if match
4. Alternative: serve icons from filesystem instead of MySQL

## Tier 4: DNS Optimization

### Problem
- "DNS water torture attack" during benchmark — massive random subdomain queries
- PowerDNS with MySQL backend is slow under load

### Fixes
- Add indexes to isudns tables
- Configure PowerDNS query cache
- Consider serving DNS from application directly (bypass PowerDNS)
- Increase PowerDNS cache-ttl

## Tier 5: Multi-Server Distribution

### Initial state
All components on each VM (nginx + app + MySQL + PowerDNS)

### Optimized layout
- VM1: nginx (load balancer) + PowerDNS + MySQL (primary)
- VM2: nginx + Go app (worker)
- VM3: nginx + Go app (worker)

### Steps
1. Configure MySQL to listen on 0.0.0.0 and allow remote connections
2. Update Go app env vars to point to VM1's MySQL
3. Configure nginx on VM1 as upstream load balancer
4. Update PowerDNS zone to return VM2/VM3 IPs

## Tier 6: Application-Level Caching

### Candidates for in-memory cache
- User info (name, display_name) — changes rarely
- Theme data — changes rarely  
- Tag list — static data
- DNS zone data — cache in application

### Implementation
Use Go sync.Map or a simple TTL cache for frequently accessed data.

## Performance Analysis Tools

### Install alp (nginx log analyzer)
```bash
wget -q https://github.com/tkuchiki/alp/releases/download/v1.0.21/alp_linux_amd64.tar.gz
tar xzf alp_linux_amd64.tar.gz && mv alp /usr/local/bin/
```

### Usage
```bash
alp ltsv --file /var/log/nginx/access.log --sort sum -r
```

### Enable MySQL slow query log
```sql
SET GLOBAL slow_query_log = 'ON';
SET GLOBAL slow_query_log_file = '/var/log/mysql/slow.log';
SET GLOBAL long_query_time = 0.1;
```

### pt-query-digest
```bash
apt-get install -y percona-toolkit
pt-query-digest /var/log/mysql/slow.log
```
