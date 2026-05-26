# Changelog

All notable changes to this project. Newest first.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- **Process supervision**: `scripts/watchdog.sh` is a long-lived loop that checks every 30s whether `hp-server` and `cloudflared` are alive, restarts them if not. Also watches for the tunnel-restart flag dropped by the in-process tunnel health watchdog.
- **Tunnel health watchdog** in-process: polls `cloudflared:20241/metrics` every 30s, classifies as `healthy` / `degraded` / `offline` / `unknown`, broadcasts state changes over SSE, and writes a restart-request flag if the tunnel stays down for more than 2 minutes (consumed by `watchdog.sh`).
- **Encrypted backup**: `scripts/backup.sh` tarballs `~/data/`, all `~/.hp-server-*` files, and `~/.cloudflared/`, then encrypts with `age` using a passphrase from `BACKUP_PASSPHRASE`. Daily retention of 14 backups. Boot script auto-runs once on every restart.
- **Graceful shutdown**: SIGTERM and SIGINT handlers call `httpz.Server.stop()` so JSONL flushes complete and SSE streams close cleanly.
- **Geo-block** (opt-in, off by default): toggle on Settings page, Cloudflare `cf-ipcountry` header drives the policy. Authenticated requests and local requests are never affected, so self-locking is impossible. Persisted at `~/.hp-server-geoblock.txt`.
- **Audit log**: `~/data/audit.jsonl` records every operator action (block, unblock, change credentials, run digest, update geo policy) with actor, target, detail, and outcome. Rendered at the bottom of the Security page.
- **Pepper-based session secret**: 32-byte random pepper persisted at `~/.hp-server-secret.bin` (mode 600), folded into the HMAC key. An attacker who steals only the credentials file can no longer forge cookies; they need the pepper file too.
- **Annotation cache**: AI auto-ban annotations are cached per IP for 24 hours so re-bans of the same IP do not re-spend Mistral quota.
- **Bundled icon font**: `simple-line-icons.woff2` (30 KB) and a slimmed `icons.css` are now embedded into the hp-server binary and served from `/icons.css` and `/fonts/Simple-Line-Icons.woff2`. cdnjs is no longer a dependency, the CSP no longer needs a cdnjs entry, and the dashboard works offline.
- **GitHub Actions CI**: `.github/workflows/zig-ci.yml` runs `zig fmt --check` plus Debug and ReleaseFast builds on every push and pull request.
- **AI features** powered by Mistral (`mistral-small-latest`). Three opt-in capabilities:
  - **Auto-ban annotation**: when an IP gets auto-banned for scanning, a background thread enriches the ban reason with a human-readable summary based on the recent paths probed. The classic generic reason ("auto: scanner attempts exceeded threshold") becomes something like "auto: probing WordPress and PHP exploits, generic mass scanner".
  - **"Explain this IP" on Security page**: per-IP button opens a modal where Mistral profiles the IP based on its access pattern (visit count, paths, UAs, country) and recommends allow/monitor/block.
  - **Daily digest**: every 24h (and on-demand via "Generate now" button), the server aggregates the past 24h of visits, logins, uptime, and bans, sends those metrics to Mistral, and stores a one-paragraph natural-language summary at `~/data/digests.jsonl`. Surfaced at the top of the Security page.
- New `ai.zig` module with per-feature token-bucket rate limit (1 annotate/min, 1 explain/6s, 1 digest/hour) so a runaway loop cannot drain quota.
- New endpoints (auth-required): `GET /api/ai/digest/latest`, `GET /api/ai/digest/run`, `POST /api/ai/explain`, `GET /api/audit`, `GET /api/tunnel/health`, `GET /api/geoblock`, `POST /api/geoblock/update`.
- New SSE events: `digest_ready`, `tunnel_health`.
- Real-time UI updates via Server-Sent Events at `/api/stream`. Replaces all polling on Overview, Status, and Security pages.
- New `events.zig` module with thread-safe pub/sub bus + 25s heartbeat.
- Backend publishes events for every visit, login attempt, blocklist mutation, uptime probe result, and a stats tick every 2 seconds.
- `ws-status` indicator on every authenticated page (live / connecting / offline).
- `LICENSE` (MIT), `docs/SECURITY.md`, `.gitignore`, public GitHub repo.

### Changed
- CSP no longer references `cdnjs.cloudflare.com` (font is now self-hosted).
- All template asset query strings bumped to `?v=12`.

### Privacy / safety notes for AI
- API key lives only in `~/.hp-server.env` on the device (mode 600). Never in git, never in logs, never returned to clients. `.gitignore` matches `*.env`, `*-server.env`, `.env*`.
- All AI features degrade gracefully: if no key or network fails, server keeps running with the classic non-AI behavior.
- Data sent to Mistral: only IP, country, UA, paths, and aggregated counts. Never visit log content beyond what the operator explicitly requests (e.g. clicking Explain). Never credentials.

### Fixed
- Memory values were displayed as bytes when they're actually kibibytes from `/proc/meminfo`. 8 GB of RAM rendered as 8 MB. New `fmtKB()` formatter handles all `*_kb` fields (process RSS/VSZ, system memory, swap). `fmtSize()` continues to handle raw byte counts (file sizes on `/files`).
- Stale browser cache referencing `RH.fetchInitialStats` from the pre-SSE `app.js`. Bumped all asset query strings to `?v=9` uniformly across every template.
- CSP blocked Cloudflare's auto-injected Web Analytics beacon (`static.cloudflareinsights.com/beacon.min.js`). Allowed it explicitly in `script-src` and `connect-src` since the toggle is account-scoped on Cloudflare's side and not exposed in the zone dashboard.

### Changed
- Removed obsolete files: Node app skeleton, glances/postgres/nginx setup scripts, Zig hello/sqltest playgrounds.

## 2026-05-26 - Security hardening pass

### Added
- `security.zig`: classification model with `self / unknown / bot / scanner / blocked`. No more "human" label.
- Browser-fingerprint check using `Accept-Language`, `Sec-Fetch-Site`, `Sec-Fetch-Mode`. Anything missing those is flagged as `bot`.
- Auto-ban: 3 scanner hits in 10 minutes &rarr; 24h ban; 5 failed logins in 15 minutes &rarr; 1h ban.
- TTL-aware blocklist with per-entry reason. File format upgraded from one-IP-per-line to TAB-separated.
- Login attempt log at `~/data/logins.jsonl`.
- Security headers on every response: HSTS (1y, includeSubDomains), CSP, X-Frame-Options DENY, X-Content-Type-Options, Referrer-Policy, Permissions-Policy.

### Changed
- `/api/stats` no longer falsely reports CPU usage; on Android 12 those /proc paths are SELinux-blocked. Capabilities object exposes which paths actually work.
- Cookie auth secret is now derived from `HMAC(password + username)`. Changing the password invalidates every existing session.

## 2026-05-26 - Console consolidation

### Added
- `app.rofihosted.space` private console with shared sidebar across all internal pages.
- Pages: Overview, Status, Files, API explorer, Security, Settings.
- Settings page lets the operator change credentials in-browser without SSH.
- Login page (custom) replaces the browser HTTP basic auth dialog.

### Changed
- Old subdomains (`dashboard.`, `status.`, `api.`, `files.`) now 301 redirect to `app.rofihosted.space/*` equivalents.
- `api.rofihosted.space` is no longer publicly accessible. All JSON endpoints require an authenticated session.

## 2026-05-26 - First public deployment

### Added
- Domain `rofihosted.space` registered with Namecheap, delegated to Cloudflare DNS.
- Named Cloudflare Tunnel `hp-server` with credentials JSON on the device, persistent ID.
- DNS records (CNAME) for `rofihosted.space`, `www.`, `app.`, `dashboard.`, `status.`, `api.`, `files.` &rarr; tunnel.
- Initial credentials seeded: user `mrofid`. Password set via console.

## 2026-05-26 - Stack rewrite to Zig

### Added
- Zig 0.14.0 binary `hp-server` replaces the previous Node + Express + Postgres prototype.
- Modules: `auth`, `ratelimit`, `store`, `sysmon`, `uptime`, `files`, `badge`, `telegram`.
- Templates rendered via `@embedFile`, single-binary deploy.
- httpz with multi-host routing on a single port (8080).

### Removed
- Node.js, Postgres, Redis, Nginx, php-fpm. Disabled in Termux runit and uninstalled.

## 2026-05-26 - Initial provisioning

### Added
- Termux + sshd on Sharp Aquos Sense4 Plus (Android 12).
- Cloudflare Tunnel (Quick Tunnel first, then named) wrapped via `proot` to fix DNS / CA paths under Bionic.
- Termux:Boot script `~/.termux/boot/01-server.sh` to auto-start sshd, hp-server, cloudflared on phone restart.
- Wake lock acquired at boot to keep services alive in the background.

[Unreleased]: https://github.com/rofiperlungoding/rofihosted/compare/main...HEAD
