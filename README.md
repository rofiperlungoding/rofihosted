# rofihosted

A "kingdom of one" personal cloud running on an old Sharp Aquos Sense4 Plus phone, exposed to the public internet via Cloudflare Tunnel. Single Zig binary, ~3&nbsp;MB RSS idle, no public IP, no port forward.

Live at [rofihosted.space](https://rofihosted.space). Authenticated console at [app.rofihosted.space](https://app.rofihosted.space). Static sites at any [`<sub>.rofihosted.space`](https://blog.rofihosted.space).

## What it does

- Single Zig 0.14 binary (httpz) on port 8080
- Cookie-based session auth (HMAC + 32-byte random pepper, 7&nbsp;day TTL, HttpOnly + Secure + SameSite=Lax)
- Per-IP token-bucket rate limiter
- Request classifier: `self` / `unknown` / `bot` / `scanner` / `blocked`
- Auto-ban: 3 scanner hits in 10&nbsp;min &rarr; 24h ban; 5 failed logins in 15&nbsp;min &rarr; 1h ban
- Optional geo-block toggle (off by default), driven by `cf-ipcountry`. Authenticated/local requests are always allowed (self-locking impossible).
- Persisted IP blocklist with TTL and reason at `~/.hp-server-blocklist.txt`
- Strict HTTP security headers on every response: HSTS, CSP, X-Frame-Options DENY, no MIME sniff, strict referrer, locked Permissions-Policy
- Real-time event bus (Server-Sent Events) for live UI updates: visits, login attempts, blocklist mutations, uptime probes, stats ticks, tunnel health, digest ready, anomaly detected
- Background uptime checker, append-only JSONL store with 5s buffered writes, optional Telegram notifications on transitions
- Tunnel health watchdog: classifies cloudflared as healthy / degraded / offline, requests restart after 2 min downtime
- Process supervisor (`scripts/watchdog.sh`) restarts hp-server / cloudflared on death, HTTP /health probe with consecutive-failure threshold, hard 384&nbsp;MB RSS ceiling with SIGTERM-then-restart so the write buffer flushes before the OOM killer hits
- Encrypted daily backup with `age` (`scripts/backup.sh`), 14-day retention
- Audit log: every operator action recorded to `~/data/audit.jsonl`
- SQLite read-side cache (`~/data/cache.db`) for fast AI query bar; 5-minute incremental sync from JSONL via persistent sqlite3 subprocess pool (5x lower per-query latency vs one-shot spawning)
- Operator rule engine: JSON DSL at `~/.hp-server-rules.jsonl` (4 triggers: on_visit, on_login_attempt, on_blocklist_change, on_anomaly; 3 action types: block, log, increment)
- Static site hosting at any `*.rofihosted.space` with atomic symlink deploys, per-site LRU cache, SPA fallback. Operator drops a folder, runs `~/hosted-deploy.sh <sub> <dir>`, zero downtime, no rebuild.
- API key manager: scoped tokens (`/v1/execute` SQL-over-HTTP) hashed with SHA-256+pepper for operator's other apps and scripts
- Outbound webhook dispatcher: configure URL + event subscription, get POSTed `{event, ts, payload}` envelopes when things happen
- Live system telemetry: `/proc/self/*`, `/proc/meminfo`, `termux-battery-status`, `termux-wifi-connectioninfo`, scraped Cloudflare tunnel metrics
- Self-hosted icon font (no cdnjs dependency at runtime)
- Web UI: Overview, Status, Files, API explorer, Security, Settings (all behind login except landing)

## AI features (opt-in via Mistral)

When `MISTRAL_API_KEY` is set in `~/.hp-server.env`, eleven AI features activate. All degrade gracefully when the key is absent.

- **Auto-ban annotation** with structured output
- **Explain this IP** (streaming + structured) with risk scoring
- **Daily digest** of activity
- **Weekly policy review** (medium model + small reflection pass)
- **Honeypot** (opt-in, decoy responses for scanners)
- **Natural-language query bar** with function calling and semantic prompt cache
- **Embeddings + behavioural clusters** of attacker patterns
- **Anomaly detection** on novel access patterns
- **AI observability** (`~/data/ai-calls.jsonl` + `/api/ai/usage`)
- **Log scrubbing** ("is anything in this scanner traffic actually a zero-day?")
- **Prompt injection defense** via `<UNTRUSTED>` delimiters + sanitization across every Mistral call

Per-feature token-bucket rate limit prevents quota drain. See [`docs/SECURITY.md`](docs/SECURITY.md) and [`docs/PROJECT-BRIEFING.md`](docs/PROJECT-BRIEFING.md) for details.

## Why a phone

Sharp Aquos Sense4 Plus has Snapdragon 720G, 8&nbsp;GB RAM, 4120&nbsp;mAh battery (built-in UPS). Idle, the binary uses around 3&nbsp;MB RSS and the device draws negligible power on AC. Cheaper than a Raspberry Pi, with on-device LTE fallback if WiFi drops.

## Topology

```
Internet
   |
   v
Cloudflare edge (Singapore HA: sin07/09/16/20/22)
   |
   v
cloudflared (Go, prebuilt binary, run via proot for DNS+CA bind)
   |
   v
hp-server :8080 (single Zig binary)
   |
   +-- /proc reads (self stats, meminfo)
   +-- termux-api subprocess (battery, wifi)
   +-- cloudflared :20241/metrics scrape
   +-- persistent sqlite3 worker pool -> ~/data/cache.db (read-side cache)
   +-- on-demand sqlite3 -> ~/data/dbs/<db>.db  (V1 SQL-over-HTTP)
   +-- (optional) Mistral API for AI features
   +-- (optional) curl subprocess fan-out -> webhook URLs
   |
   +-- ~/data/{visits,uptime,logins,audit,digests,policy,scrub,anomalies,ai-calls}.jsonl
   +-- ~/data/cache.db                                     (rebuildable from visits.jsonl)
   +-- ~/data/embeddings.bin                               (1024-dim vectors, LRU)
   +-- ~/hosted/sites/<sub>/{releases,current}             (static sites)
   +-- ~/.hp-server-creds.txt                              (mode 600)
   +-- ~/.hp-server-blocklist.txt                          (TSV, mode 600)
   +-- ~/.hp-server-secret.bin                             (32-byte random pepper, mode 600)
   +-- ~/.hp-server-geoblock.txt                           (toggle + allow list)
   +-- ~/.hp-server-honeypot.txt                           (toggle)
   +-- ~/.hp-server-rules.jsonl                            (operator rule DSL)
   +-- ~/.hp-server-apikeys.jsonl                          (hashed API keys, mode 600)
   +-- ~/.hp-server-webhooks.jsonl                         (outbound webhook configs)
   +-- ~/.hp-server.env                                    (env vars, mode 600)
```

## Routing

| Host | Routes |
| --- | --- |
| `rofihosted.space` | Public landing (placeholder), static asset endpoints (`/theme.css`, `/theme.js`, `/app.css`, `/app.js`, `/icons.css`, `/fonts/Simple-Line-Icons.woff2`), `/health` |
| `app.rofihosted.space` | Private console (auth required): pages and `/api/*` JSON. Also handles `/v1/*` X-API-Key endpoints. |
| `<anything>.rofihosted.space` | Static site from `~/hosted/sites/<sub>/current/`, with SPA fallback if `spa.flag` is present |
| `dashboard.rofihosted.space` | 301 to `app.rofihosted.space` (legacy) |
| `status.rofihosted.space` | 301 to `app.rofihosted.space/status` (legacy) |
| `api.rofihosted.space` | 301 to `app.rofihosted.space/api` (legacy; `/v1/*` works on any host) |
| `files.rofihosted.space` | 301 to `app.rofihosted.space/files` (legacy) |
| `www.rofihosted.space` | 301 to `rofihosted.space` |

Reserved subdomains (`app`, `www`, `dashboard`, `status`, `api`, `files`) cannot be overridden by the static-hosting layer even if `~/hosted/sites/<reserved>/` exists.

## Tech stack

- Zig 0.14.0
- [httpz](https://github.com/karlseguin/http.zig) for HTTP/SSE
- Termux on Android 12 (Bionic libc, no glibc)
- Cloudflare Tunnel (`cloudflared` Go binary, run via `proot`)
- Cloudflare Registrar for the domain, Cloudflare for DNS (wildcard CNAME for static hosting)
- `sqlite3` CLI as a persistent subprocess pool (no libsqlite3 linking, Termux/Bionic friendly)
- Mistral (small + medium + embed) for optional AI features
- `age` for encrypted backups
- `curl` subprocess for outbound webhooks and Telegram

## Repository layout

```
zig/hp-server/
  build.zig
  build.zig.zon
  src/
    main.zig          - HTTP routing, request lifecycle, signal handlers, AI/digest/policy dispatch
    auth.zig          - HMAC-SHA256 session cookies (with pepper), file-backed creds
    secret.zig        - Random pepper persisted to ~/.hp-server-secret.bin
    security.zig      - Classifier, blocklist, autoban, login tracker, security headers
    geoblock.zig      - Country-based filtering (cf-ipcountry), opt-in
    audit.zig         - Append-only operator-action log
    events.zig        - SSE pub/sub bus + optional fan-out callback for webhooks
    sysmon.zig        - /proc readers (self + meminfo)
    hostinfo.zig      - termux-api subprocess scrapers + cloudflared metrics
    tunnel_health.zig - Periodic cloudflared metrics poll, restart-request flag
    uptime.zig        - Periodic HTTP probes, transition detection
    store.zig         - JSONL append-only with size-bounded rotation
    writebuf.zig      - 5s buffered writer for visits.jsonl
    rules.zig         - Operator rule engine (JSON DSL)
    dbcache.zig       - SQLite read-side cache, 5-min incremental sync
    dbpool.zig        - Persistent sqlite3 -batch worker pool
    pathsafe.zig      - Strict path/subdomain validators + realpath escape check
    hosted.zig        - Static-site hosting at *.rofihosted.space with LRU cache
    apikey.zig        - Scoped tokens for /v1/* endpoints
    webhook.zig       - Outbound HTTP webhook fan-out
    ratelimit.zig     - Token bucket per IP
    files.zig         - Directory listing for /files page
    badge.zig         - SVG status badges (shields.io style)
    telegram.zig      - Optional notifier (spawns curl)
    embeddings.zig    - 1024-dim vectors + LRU + cosine clustering
    honeypot.zig      - AI-generated decoy content for scanners
    query.zig         - Function-call planner for the AI query bar
    ai.zig            - Mistral client + per-feature rate limit + caches
    templates/        - All HTML, CSS, JS, woff2 (embedded into binary)
scripts/              - Termux setup, boot, watchdog, backup, tunnel ops, deploy helper, smoke tests
docs/                 - Architecture, security model, full project briefing
.github/workflows/    - Zig fmt + Debug + ReleaseFast CI on every push
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for module-level details, [`docs/SECURITY.md`](docs/SECURITY.md) for the threat model, and [`docs/PROJECT-BRIEFING.md`](docs/PROJECT-BRIEFING.md) for the comprehensive context-transfer document.

## Status

This is a personal home server. Nothing here is meant to scale beyond one user. The code is intentionally small (~5000 lines of Zig) and avoids dependencies aside from httpz. Source files are pure 7-bit ASCII so transfers over arbitrary pipes do not corrupt them.

Update history: [`CHANGELOG.md`](CHANGELOG.md).

## License

MIT. See [`LICENSE`](LICENSE).
