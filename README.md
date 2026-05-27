# rofihosted

A self-hosted control plane that turns an old Sharp Aquos Sense4 Plus phone into a real server, exposed to the public internet via Cloudflare Tunnel. Single Zig binary, ~2&nbsp;MB RSS idle, no public IP, no port forward.

Live at [rofihosted.space](https://rofihosted.space). Authenticated console at [app.rofihosted.space](https://app.rofihosted.space).

## What it does

- Single Zig 0.14 binary (httpz) on port 8080
- Cookie-based session auth (HMAC + 32-byte random pepper, 7&nbsp;day TTL, HttpOnly + Secure + SameSite=Lax)
- Per-IP token-bucket rate limiter
- Request classifier: `self` / `unknown` / `bot` / `scanner` / `blocked`
- Auto-ban: 3 scanner hits in 10&nbsp;min &rarr; 24h ban; 5 failed logins in 15&nbsp;min &rarr; 1h ban
- Optional geo-block toggle (off by default), driven by `cf-ipcountry`. Authenticated/local requests are always allowed (self-locking impossible).
- Persisted IP blocklist with TTL and reason at `~/.hp-server-blocklist.txt`
- Strict HTTP security headers on every response: HSTS, CSP, X-Frame-Options DENY, no MIME sniff, strict referrer, locked Permissions-Policy
- Real-time event bus (Server-Sent Events) for live UI updates: visits, login attempts, blocklist mutations, uptime probes, stats ticks, tunnel health, digest ready
- Background uptime checker, append-only JSONL store, optional Telegram notifications on transitions
- Tunnel health watchdog: classifies cloudflared as healthy / degraded / offline, requests restart after 2 min downtime
- Process supervisor (`scripts/watchdog.sh`) restarts hp-server / cloudflared on death
- Encrypted daily backup with `age` (`scripts/backup.sh`), 14-day retention
- Audit log: every operator action (block, unblock, change credentials, run digest, update geo policy) recorded to `~/data/audit.jsonl`
- Live system telemetry: `/proc/self/*`, `/proc/meminfo`, `termux-battery-status`, `termux-wifi-connectioninfo`, scraped Cloudflare tunnel metrics
- Self-hosted icon font (no cdnjs dependency at runtime)
- Web UI: Overview, Status, Files, API explorer, Security, Settings (all behind login except landing)

## AI features (opt-in via Mistral)

When `MISTRAL_API_KEY` is set in `~/.hp-server.env`, three opt-in features activate. All degrade gracefully when the key is absent.

- **Auto-ban annotation**: scanner-ban reasons get enriched with a one-liner describing what the attacker probed. Cached per-IP for 24h to avoid re-spending quota.
- **Explain this IP**: per-IP button on the Security page opens a modal where Mistral profiles the IP based on its access pattern and recommends allow / monitor / block.
- **Daily digest**: every 24h (and on-demand), aggregate metrics are summarised into one paragraph. Stored at `~/data/digests.jsonl`, surfaced at the top of the Security page.

Per-feature token-bucket rate limit (1 annotate/min, 1 explain/6s, 1 digest/hour) prevents quota drain. See [`docs/SECURITY.md`](docs/SECURITY.md) for what data leaves the device.

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
   +-- (optional) Mistral API for AI features
   |
   +-- ~/data/{visits,uptime,logins,audit,digests}.jsonl  (append-only, hourly rotation)
   +-- ~/.hp-server-creds.txt                              (mode 600)
   +-- ~/.hp-server-blocklist.txt                          (TSV, mode 600)
   +-- ~/.hp-server-secret.bin                             (32-byte random pepper, mode 600)
   +-- ~/.hp-server-geoblock.txt                           (toggle + allow list)
   +-- ~/.hp-server.env                                    (env vars, mode 600)
```

## Routing

| Host | Routes |
| --- | --- |
| `rofihosted.space` | Public landing (placeholder), `/theme.css`, `/theme.js`, `/app.css`, `/app.js`, `/icons.css`, `/fonts/Simple-Line-Icons.woff2`, `/health` |
| `app.rofihosted.space` | Private console (auth required): `/`, `/status`, `/files`, `/api`, `/security`, `/settings`, plus `/login`, `/logout` and the JSON API at `/api/{me,stats,host,tunnel,tunnel/health,visits,uptime,security,security/block,security/unblock,audit,geoblock,geoblock/update,ai/explain,ai/digest/latest,ai/digest/run,stream,...}` |
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
- Mistral (`mistral-small-latest`) for optional AI features
- `age` for encrypted backups

## Repository layout

```
zig/hp-server/
  build.zig
  build.zig.zon
  src/
    main.zig          - HTTP routing, request lifecycle, signal handlers, AI/digest dispatch
    auth.zig          - HMAC-SHA256 session cookies (with pepper), file-backed creds
    secret.zig        - Random pepper persisted to ~/.hp-server-secret.bin
    security.zig      - Classifier, blocklist, autoban, login tracker, security headers
    geoblock.zig      - Country-based filtering (cf-ipcountry), opt-in
    audit.zig         - Append-only operator-action log
    events.zig        - SSE pub/sub bus, heartbeat
    sysmon.zig        - /proc readers (self + meminfo)
    hostinfo.zig      - termux-api subprocess scrapers + cloudflared metrics
    tunnel_health.zig - Periodic cloudflared metrics poll, restart-request flag
    uptime.zig        - Periodic HTTP probes, transition detection
    store.zig         - JSONL append-only with size-bounded rotation
    ratelimit.zig     - Token bucket per IP
    files.zig         - Directory listing for /files page
    badge.zig         - SVG status badges (shields.io style)
    telegram.zig      - Optional notifier (spawns curl)
    ai.zig            - Mistral client + per-feature rate limit + annotation cache
    templates/        - All HTML, CSS, JS, woff2 (embedded into binary)
scripts/              - Termux setup, boot, watchdog, backup, tunnel ops, smoke tests
docs/                 - Architecture, security model, operations
.github/workflows/    - Zig fmt + Debug + ReleaseFast CI on every push
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for module-level details and [`docs/SECURITY.md`](docs/SECURITY.md) for the threat model and current mitigations.

## Status

This is a personal home server. Nothing here is meant to scale beyond one user. The code is intentionally small (~3000 lines of Zig) and avoids dependencies aside from httpz. Source files are pure 7-bit ASCII so transfers over arbitrary pipes do not corrupt them.

Update history: [`CHANGELOG.md`](CHANGELOG.md).

## License

MIT. See [`LICENSE`](LICENSE).
