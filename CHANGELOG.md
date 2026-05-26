# Changelog

All notable changes to this project. Newest first.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Real-time UI updates via Server-Sent Events at `/api/stream`. Replaces all polling on Overview, Status, and Security pages.
- New `events.zig` module with thread-safe pub/sub bus + 25s heartbeat.
- Backend publishes events for every visit, login attempt, blocklist mutation, uptime probe result, and a stats tick every 2 seconds.
- `ws-status` indicator on every authenticated page (live / connecting / offline).
- `LICENSE` (MIT), `docs/SECURITY.md`, `.gitignore`, public GitHub repo.

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
