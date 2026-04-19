---
name: icon-caching
description: Implement icon image caching with ETag and 304 Not Modified responses to eliminate redundant BLOB reads from MySQL
---

# Icon Caching (ETag / 304) — ISUPIPE

Every icon request currently reads a LONGBLOB from MySQL. The benchmark client sends `If-None-Match` headers, but the app ignores them.

## Current Behavior

```
GET /api/user/:username/icon
→ SELECT image FROM icons WHERE user_id = ?  (LONGBLOB, often 100KB+)
→ 200 OK with full image body every time
```

## Fix Strategy

### Option A: ETag with SHA256 hash (recommended)

1. When an icon is uploaded (`POST /api/user/me/icon`), compute SHA256 hash and store it
2. On `GET /api/user/:username/icon`:
   - Read the hash (not the image) from DB or cache
   - Compare with `If-None-Match` header
   - If match → return `304 Not Modified` (no body)
   - If no match → read and return full image with `ETag` header

### Option B: Serve from filesystem

1. On upload, write icon to `/home/isucon/isucon13/webapp/public/icons/{user_id}.jpg`
2. Configure nginx to serve `/api/user/:username/icon` directly from filesystem
3. Add `ETag` and `If-None-Match` handling in nginx (automatic with `sendfile`)

## Implementation (Option A)

Key changes to `user_handler.go`:

```go
// In getIconHandler:
// 1. Get icon hash (add icon_hash column or compute on read)
iconHash := fmt.Sprintf("%x", sha256.Sum256(iconImage))

// 2. Check If-None-Match
if c.Request().Header.Get("If-None-Match") == fmt.Sprintf(`"%s"`, iconHash) {
    return c.NoContent(http.StatusNotModified)
}

// 3. Return with ETag
c.Response().Header().Set("ETag", fmt.Sprintf(`"%s"`, iconHash))
return c.Blob(http.StatusOK, "image/jpeg", iconImage)
```

## Adding icon_hash Column

```sql
ALTER TABLE icons ADD COLUMN icon_hash VARCHAR(64) DEFAULT NULL;
```

Update the upload handler to compute and store the hash on insert.

## Expected Impact

- Most icon requests become 304 (no body transfer)
- Reduces MySQL BLOB reads by ~90%
- Typical score improvement: +2,000-5,000
