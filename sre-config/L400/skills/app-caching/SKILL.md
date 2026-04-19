---
name: app-caching
description: Implement application-level in-memory caching in Go using sync.Map for frequently accessed data that rarely changes
---

# Application-Level Caching — ISUPIPE

Cache frequently accessed, rarely changing data in Go application memory to avoid repeated MySQL queries.

## Cache Candidates

| Data | Access Pattern | Change Frequency | Cache Strategy |
|------|---------------|------------------|----------------|
| User info (name, display_name) | Every request (auth) | Rarely | sync.Map, invalidate on update |
| Theme data | Every page render | Rarely | sync.Map, invalidate on update |
| Tag list | Every livestream view | Never (static) | Load once at startup |
| DNS zone data | Every DNS query | On user creation | sync.Map + PowerDNS notify |

## Implementation — sync.Map

### User Cache Example

Add to `main.go`:

```go
var userCache sync.Map // map[int64]*UserModel

func getUserByID(ctx context.Context, db *sqlx.DB, userID int64) (*UserModel, error) {
    // Check cache first
    if cached, ok := userCache.Load(userID); ok {
        return cached.(*UserModel), nil
    }

    // Cache miss — query DB
    var user UserModel
    if err := db.GetContext(ctx, &user, "SELECT * FROM users WHERE id = ?", userID); err != nil {
        return nil, err
    }

    // Store in cache
    userCache.Store(userID, &user)
    return &user, nil
}
```

### Cache Invalidation

Clear cache on `POST /api/initialize`:

```go
func initializeHandler(c echo.Context) error {
    userCache = sync.Map{}   // Reset all caches
    themeCache = sync.Map{}
    tagCache = nil
    // ... existing init logic
}
```

### Tag Cache (Static Data)

```go
var tagCache []TagModel

func getTagsHandler(c echo.Context) error {
    if tagCache != nil {
        return c.JSON(http.StatusOK, &TagsResponse{Tags: tagCache})
    }
    // Load from DB and cache
    var tags []TagModel
    db.SelectContext(ctx, &tags, "SELECT * FROM tags")
    tagCache = tags
    return c.JSON(http.StatusOK, &TagsResponse{Tags: tags})
}
```

## Alternative: TTL Cache with expiration

For data that may change during the benchmark:

```go
type CacheEntry struct {
    Value     interface{}
    ExpiresAt time.Time
}

// Simple TTL cache
var cache sync.Map

func getCached(key string, ttl time.Duration, fetch func() (interface{}, error)) (interface{}, error) {
    if entry, ok := cache.Load(key); ok {
        if e := entry.(*CacheEntry); time.Now().Before(e.ExpiresAt) {
            return e.Value, nil
        }
    }
    val, err := fetch()
    if err != nil { return nil, err }
    cache.Store(key, &CacheEntry{Value: val, ExpiresAt: time.Now().Add(ttl)})
    return val, nil
}
```

## Expected Impact

- Eliminates repeated user/theme queries (often 50%+ of all queries)
- Tag cache eliminates a full table scan per request
- Typical improvement: +5,000-15,000 score
