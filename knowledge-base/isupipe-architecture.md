# ISUPIPE Architecture

## Overview
ISUPIPE is a live streaming platform from ISUCON13. Users can broadcast, watch streams, post comments with tips (ISUCOIN), and react with emoji.

## Components (per contest VM)

### Go Web Application (isupipe-go)
- Port: 8080
- Service: `systemctl status isupipe-go`
- Source: `/home/isucon/isucon13/webapp/go/`
- Binary: `/home/isucon/isucon13/webapp/go/isupipe`
- Handles all API endpoints for the platform

### nginx (reverse proxy + TLS)
- Port: 443 (HTTPS)
- Config: `/etc/nginx/sites-enabled/isupipe.conf`
- TLS cert: `/etc/nginx/tls/*.u.isucon.dev.*`
- Proxies to Go app on 127.0.0.1:8080

### MySQL 8.0
- Port: 3306
- Databases:
  - `isupipe` — application data (users, livestreams, livecomments, reactions, icons)
  - `isudns` — PowerDNS zone data
- User: `isucon` / Password: `isucon`
- Schema: `/home/isucon/isucon13/webapp/sql/initdb.d/10_schema.sql`

### PowerDNS
- Port: 53/UDP
- Backend: MySQL (isudns database)
- Config: `/etc/powerdns/pdns.conf`
- Provides per-streamer subdomains (e.g., `alice.u.isucon.dev`)
- Zone: `u.isucon.dev`

## Key Database Tables

### isupipe database
- `users` — user accounts (name UNIQUE, bcrypt passwords)
- `icons` — user avatar images (LONGBLOB)
- `livestreams` — stream metadata with scheduled times
- `livecomments` — comments with optional tip amounts (ISUCOIN)
- `reactions` — emoji reactions to streams
- `themes` — per-user frontend themes
- `livestream_tags` / `tags` — categorization

### isudns database
- PowerDNS standard schema (domains, records, etc.)

## API Endpoints
- `POST /api/initialize` — reset all data, must return `{"lang":"go"}`
- `GET /api/user/:username` — user profile
- `GET /api/user/:username/icon` — user icon (supports ETag/304)
- `GET /api/user/:username/statistics` — user stats
- `POST /api/livestream` — create livestream
- `GET /api/livestream/:id/statistics` — stream stats
- `POST /api/livestream/:id/livecomment` — post comment with tip
- `POST /api/livestream/:id/reaction` — post reaction

## Scoring
- Score = sum of all ISUCOIN tips during 60-second load test
- Initial score: ~3,600
- Top score (competition): 468,006

## Benchmark Flow
1. `POST /api/initialize` (42s timeout)
2. Application consistency check (20s timeout)
3. Load test (60s)
4. Final validation (10s)
