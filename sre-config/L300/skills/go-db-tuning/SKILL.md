---
name: go-db-tuning
description: Tune Go database/sql connection pool settings for optimal MySQL performance under ISUCON load
---

# Go DB Connection Pool Tuning — ISUPIPE

The default Go `database/sql` connection pool settings are not optimal for ISUCON workloads.

## Key Settings

Add these after `sql.Open()` in the Go app (typically in `main.go`):

```go
db.SetMaxOpenConns(25)       // Max simultaneous connections (default: unlimited)
db.SetMaxIdleConns(25)       // Keep connections warm (default: 2)
db.SetConnMaxLifetime(0)     // No max lifetime (reuse connections)
db.SetConnMaxIdleTime(0)     // No idle timeout
```

## Why These Values

| Setting | Default | Recommended | Reason |
|---------|---------|-------------|--------|
| MaxOpenConns | ∞ | 25 | Prevents MySQL connection exhaustion (default max_connections=151) |
| MaxIdleConns | 2 | = MaxOpenConns | Avoids connection churn (creating new connections per request) |
| ConnMaxLifetime | ∞ | 0 | No need to rotate in ISUCON (short-lived benchmark) |

## Finding the db.Open() Call

```bash
exec host="vm1" command="grep -n 'sql.Open\|db.Set' /home/isucon/isucon13/webapp/go/main.go"
```

## Applying the Change

```bash
exec host="vm1" command="cd /home/isucon/isucon13/webapp/go && sed -i '/sql.Open/a\\tdb.SetMaxOpenConns(25)\n\tdb.SetMaxIdleConns(25)\n\tdb.SetConnMaxLifetime(0)' main.go"
```

Then rebuild and restart:
```bash
exec host="vm1" command="cd /home/isucon/isucon13/webapp/go && go build -o isupipe . && sudo systemctl restart isupipe-go"
```

## Prepared Statements

If the app uses `db.Prepare()` extensively, consider switching to `interpolateParams=true` in the DSN to reduce round-trips:

```go
// Add to DSN: ?interpolateParams=true
dsn := "isucon:isucon@tcp(127.0.0.1:3306)/isupipe?parseTime=true&interpolateParams=true"
```

This sends the full SQL in one packet instead of prepare→execute→close (3 round-trips).

## Expected Impact

- Eliminates connection churn under load
- Reduces "too many connections" errors
- Typical improvement: +1,000-3,000 score
