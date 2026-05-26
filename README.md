# rofihosted

A self-hosted control plane that turns an old Sharp Aquos Sense4 Plus phone into a real server, exposed to the public internet via Cloudflare Tunnel. Single Zig binary, ~2&nbsp;MB RSS, no IP publik, no port forward.

Live at [rofihosted.space](https://rofihosted.space). Authenticated console at [app.rofihosted.space](https://app.rofihosted.space).

## What it does

- HTTP server on port 8080 (Zig + httpz, single binary)
- Cookie-based session auth (HMAC-signed, 7&nbsp;day TTL, HttpOnly + Secure + SameSite=Lax)
- Per-IP token-bucket rate limiter
- Request classifier: `self` / `unknown` / `bot` / `scanner` / `blocked`
- Auto-ban: 3 scanner hits in 10&nbsp;min &rarr; 24h ban; 5 failed logins in 15&nbsp;min &rarr; 1h ban
- File-backed IP blocklist, persisted at `~/.hp-server-blocklist.txt`
- HTTP security headers on every response (HSTS, CSP, X-Frame-Options DENY, no MIME sniff, strict referrer, locked Permissions-Policy)
- Real-time event bus (Server-Sent Events) for live UI updates: visits, login attempts, blocklist mutations, uptime probe results, stats ticks
- Background uptime checker, append-only JSONL store, Telegram notifications on transitions
- Live system telemetry: `/proc/self/*`, `/proc/meminfo`, `termux-battery-status`, `termux-wifi-connectioninfo`, scraped Cloudflare tunnel metrics
- Web UI: Overview, Status, Files, API explorer, Security, Settings (all behind login except landing)

## Why a phone

Sharp Aquos Sense4 Plus has Snapdragon 720G, 8&nbsp;GB RAM, 4120&nbsp;mAh battery (built-in UPS). Idle, the binary uses around 2&nbsp;MB RSS and the device draws negligible power on AC. Cheaper than a Raspberry Pi, with on-device LTE fallback if WiFi drops.

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
   +-- ~/data/{visits,uptime,logins}.jsonl (append-only)
   +-- ~/.hp-server-blocklist.txt
   +-- ~/.hp-server-creds.txt (mode 600)
```

## Routing

| Host | Routes |
| --- | --- |
| `rofihosted.space` | Public landing (placeholder), `/theme.css`, `/theme.js`, `/app.css`, `/app.js`, `/health` |
| `app.rofihosted.space` | Private console (auth required): `/`, `/status`, `/files`, `/api`, `/security`, `/settings`, plus `/login`, `/logout` and the JSON API at `/api/{me,stats,host,tunnel,visits,uptime,security,stream,...}` |
| `dashboard.rofihosted.space` | 301 to `app.rofihosted.space` (legacy) |
| `status.rofihosted.space` | 301 to `app.rofihosted.space/status` (legacy) |
| `api.rofihosted.space` | 301 to `app.rofihosted.space/api` (legacy) |
| `files.rofihosted.space` | 301 to `app.rofihosted.space/files` (legacy) |
| `www.rofihosted.space` | 301 to `rofihosted.space` |

## Tech stack

- Zig 0.14.0
- [httpz](https://github.com/karlseguin/http.zig) for HTTP/SSE
- Termux on Android 12 (Bionic libc, no glibc)
- Cloudflare Tunnel (`cloudflared` Go binary, run via `proot`)
- Cloudflare Registrar for the domain, Cloudflare for DNS

## Repository layout

```
zig/hp-server/
  build.zig
  build.zig.zon
  src/
    main.zig          - HTTP routing, request lifecycle, session, auto-ban hooks
    auth.zig          - HMAC-SHA256 session cookies, file-backed creds
    security.zig      - Classifier, blocklist, autoban, login tracker, security headers
    events.zig        - SSE pub/sub bus, heartbeat
    sysmon.zig        - /proc readers (self + meminfo)
    hostinfo.zig      - termux-api subprocess scrapers + cloudflared metrics
    uptime.zig        - Periodic HTTP probes, transition detection
    store.zig         - JSONL append-only with size-bounded rotation
    ratelimit.zig     - Token bucket per IP
    files.zig         - Directory listing for /files page
    badge.zig         - SVG status badges (shields.io style)
    telegram.zig      - Notifier (spawns curl)
    templates/        - All HTML, CSS, JS
scripts/              - Termux setup helpers (initial provisioning, boot script, tunnel ops)
docs/                 - Architecture, security model, operations
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for module-level details and [`docs/SECURITY.md`](docs/SECURITY.md) for the threat model and current mitigations.

## Status

This is a personal home server. Nothing here is meant to scale beyond one user. The code is intentionally small (~2000 lines of Zig) and avoids dependencies aside from httpz.

Update history: [`CHANGELOG.md`](CHANGELOG.md).

## License

MIT. See [`LICENSE`](LICENSE).
