---
name: isucon-scoring-patterns
description: Common ISUCON scoring patterns and strategies to achieve score jumps based on historical competition data
---

# ISUCON Scoring Patterns — Historical Strategies

Patterns observed across ISUCON competitions (ISUCON 9-13) that consistently lead to score jumps.

## Score Plateaus and Breakthroughs

| Score Range | Typical State | Breakthrough Strategy |
|-------------|--------------|----------------------|
| 0-5,000 | Default implementation | Add DB indexes, fix obvious N+1 |
| 5,000-15,000 | Basic indexes added | Eliminate N+1 in hot paths, enable caching |
| 15,000-50,000 | Single-server optimized | Multi-server distribution, LB setup |
| 50,000-100,000 | Multi-server + optimized queries | App-level caching, DNS optimization |
| 100,000-200,000+ | All optimizations applied | Fine-tuning, edge cases, concurrency |

## High-Impact Patterns (All ISUCONs)

### 1. The "Index Everything" Pattern
Every ISUCON has intentionally missing indexes. Check ALL foreign keys and WHERE columns:
```sql
-- Find tables without secondary indexes
SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'isupipe' AND TABLE_NAME NOT IN (
    SELECT DISTINCT TABLE_NAME FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = 'isupipe' AND INDEX_NAME != 'PRIMARY'
);
```

### 2. The "Single Heavy Endpoint" Pattern
Usually one endpoint consumes 50%+ of total time. Fix that one endpoint and score doubles.
- ISUCON13: `/api/user/:username/statistics` and `/api/livestream/:id/statistics`
- Always profile with alp to find it

### 3. The "Serve Static from nginx" Pattern
If the app serves images/files through the application → move to nginx direct serving.
- ISUCON13: User icons (LONGBLOB from MySQL → filesystem + nginx)

### 4. The "Split DB and App" Pattern
When CPU is the bottleneck on a single server:
- Dedicated DB server gets all the RAM for buffer pool
- App servers get all CPU for request processing
- Typical 2-3x score improvement

### 5. The "Denormalize Statistics" Pattern
Pre-compute expensive aggregations instead of calculating on every request:
```sql
-- Instead of: SELECT SUM(tip) FROM livecomments WHERE livestream_id = ?
-- Maintain a running total updated on INSERT
UPDATE livestream_stats SET total_tips = total_tips + ? WHERE livestream_id = ?
```

## ISUCON13-Specific Insights

### Scoring Formula
Score = total ISUCOIN tips during 60-second load test. More successful requests = more tips = higher score.

### Key Bottlenecks (in order of impact)
1. Statistics endpoints (N+1 queries → full table scans)
2. Icon serving (LONGBLOB from MySQL on every request)
3. DNS resolution (PowerDNS + MySQL under water torture attack)
4. User authentication (bcrypt + DB lookup on every request)

### Competition Winner's Stack
- 468,006 points
- Multi-server: DB + DNS on vm1, App on vm2/vm3
- All indexes, JOINed queries, icon caching (304)
- Application-level user/theme cache
- PowerDNS cache tuning
- nginx upstream with keepalive

## Meta-Strategy

1. **Measure** before optimizing (alp + slow query)
2. **Fix the biggest bottleneck** (not the easiest)
3. **One change at a time** (isolate impact)
4. **Validate with pretest** before full benchmark
5. **Track score progression** (diminishing returns signal time to move to next tier)
