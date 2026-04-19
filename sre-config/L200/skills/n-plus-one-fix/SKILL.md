---
name: n-plus-one-fix
description: Fix N+1 query problems in the ISUPIPE Go application by replacing loop queries with JOINs and batch queries
---

# N+1 Query Elimination — ISUPIPE

The ISUPIPE Go app has severe N+1 query problems in statistics and listing endpoints.

## Problem Areas

### 1. User Statistics (`GET /api/user/:username/statistics`)

**Current**: Loops over all user's livestreams, running a query per stream to sum tips and count reactions.

**Fix**: Replace with a single aggregation query:

```sql
-- Total tips for a user (instead of per-livestream loop)
SELECT IFNULL(SUM(lc.tip), 0)
FROM livecomments lc
INNER JOIN livestreams ls ON ls.id = lc.livestream_id
WHERE ls.user_id = ?
```

```sql
-- Total reactions for a user
SELECT COUNT(*)
FROM reactions r
INNER JOIN livestreams ls ON ls.id = r.livestream_id
WHERE ls.user_id = ?
```

### 2. Livestream Statistics (`GET /api/livestream/:id/statistics`)

**Current**: Loops over all comments/reactions individually.

**Fix**: Single query with GROUP BY:

```sql
SELECT IFNULL(SUM(tip), 0) as total_tips, COUNT(*) as total_comments
FROM livecomments
WHERE livestream_id = ?
```

### 3. User Info in Lists

**Current**: For each comment/reaction in a list, fetches user info individually.

**Fix**: Batch fetch users with `IN` clause or use JOINs:

```sql
SELECT lc.*, u.name, u.display_name
FROM livecomments lc
INNER JOIN users u ON u.id = lc.user_id
WHERE lc.livestream_id = ?
ORDER BY lc.created_at DESC
```

## Implementation Steps

1. Read current Go source: `exec host="vm1" command="cat /home/isucon/isucon13/webapp/go/stats_handler.go"`
2. Identify the loop with individual queries
3. Replace with a JOIN query
4. Rebuild: `exec host="vm1" command="cd /home/isucon/isucon13/webapp/go && go build -o isupipe ."`
5. Restart: `exec host="vm1" command="sudo systemctl restart isupipe-go"`

## Expected Impact

- Statistics endpoints go from O(n²) to O(1) database queries
- Typical score improvement: +3,000-10,000
