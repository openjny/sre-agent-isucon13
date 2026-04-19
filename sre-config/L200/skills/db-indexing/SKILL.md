---
name: db-indexing
description: Add missing database indexes to the ISUPIPE MySQL schema for immediate performance improvement
---

# Database Indexing — ISUPIPE

The initial ISUPIPE schema has no secondary indexes. Adding these indexes is the highest-ROI optimization.

## Missing Indexes

Run these on vm1 (or whichever VM hosts the primary MySQL):

```sql
ALTER TABLE livestreams ADD INDEX idx_user_id (user_id);
ALTER TABLE livecomments ADD INDEX idx_livestream_id (livestream_id);
ALTER TABLE reactions ADD INDEX idx_livestream_id (livestream_id);
ALTER TABLE livecomments ADD INDEX idx_livestream_id_created_at (livestream_id, created_at);
ALTER TABLE icons ADD INDEX idx_user_id (user_id);
ALTER TABLE livestream_tags ADD INDEX idx_livestream_id (livestream_id);
ALTER TABLE themes ADD INDEX idx_user_id (user_id);
```

## How to Apply

```bash
exec host="vm1" command="mysql -u isucon -pisucon isupipe -e \"
ALTER TABLE livestreams ADD INDEX idx_user_id (user_id);
ALTER TABLE livecomments ADD INDEX idx_livestream_id (livestream_id);
ALTER TABLE reactions ADD INDEX idx_livestream_id (livestream_id);
ALTER TABLE livecomments ADD INDEX idx_livestream_id_created_at (livestream_id, created_at);
ALTER TABLE icons ADD INDEX idx_user_id (user_id);
ALTER TABLE livestream_tags ADD INDEX idx_livestream_id (livestream_id);
ALTER TABLE themes ADD INDEX idx_user_id (user_id);
\""
```

## Important Notes

- Indexes are reset on `POST /api/initialize` (which runs `init.sh` → drops and recreates tables)
- To persist indexes across benchmarks, add the ALTER TABLE statements to the init script:
  `/home/isucon/isucon13/webapp/sql/initdb.d/10_schema.sql`
- Or add them to a post-init hook that runs after `init.sh`

## Verification

```bash
exec host="vm1" command="mysql -u isucon -pisucon isupipe -e 'SHOW INDEX FROM livestreams'"
```

## Expected Impact

- Statistics endpoints become 10-100x faster
- Reduces full table scans on every API call
- Typical score improvement: +5,000-15,000 from initial ~3,600
