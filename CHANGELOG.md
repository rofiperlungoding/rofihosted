# Changelog

All notable changes to this project. Newest first.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project follows [Semantic Versioning](https://semver.org/) for tagged releases.

## [Unreleased]

### Added: AI v2

- **Structured outputs everywhere**: auto-ban annotation and IP explain now use Mistral's `response_format: json_schema` mode and return typed assessments (`actor_type`, `risk_score 0-100`, `confidence 0.0-1.0`, `recommended_action: allow|monitor|block_24h|block_permanent`, indicators array). The Security UI renders these as colored pills and offers a one-click "Apply this action" button when the AI recommends a block.
- **Embeddings + behavioural clusters**: each distinct (UA, path-pattern) is embedded once via `mistral-embed` (1024-dim) and stored in a flat in-memory + on-disk index at `~/data/embeddings.bin`. A "Behavioural clusters" panel on the Security page groups patterns with cosine similarity >= 0.85, surfacing coordinated scanner/bot families. Pure brute-force search at this scale (cap 4096 patterns), no HNSW needed. New module `embeddings.zig`.
- **Weekly policy review**: every 7 days (and on-demand), the server batches the past week's per-IP behavior and asks Mistral to produce a structured list of `{ip, suggested_action, risk_score, rationale}`. Each suggestion in the UI has a one-click "Apply" that pre-fills the rationale into the manual block flow. Persisted at `~/data/policy.jsonl`.
- **AI honeypot (opt-in, default off)**: when enabled in Settings, scanner-classified requests targeting common probe paths (`/wp-admin`, `/.env`, `/.git/config`, etc) get answered with AI-generated decoy content instead of a 403. Generated content uses obviously-fake placeholder values (`honeypot-decoy-00000`, `DECOY-NOT-A-REAL-KEY-XXXX`). Cached forever per kind so we never re-call Mistral. New module `honeypot.zig`.
- **Natural-language query bar**: a small "Ask" button in the topbar of every authenticated page opens a popover where you can type free-form questions like "top scanners today", "failed logins last hour", "explain 1.2.3.4". Mistral plans the call via structured output (`function` enum with strict args schema), the server executes it locally against `~/data/*.jsonl` and the blocklist, and the popover renders the result. No mutations possible. New module `query.zig`.
- New endpoints (auth-required): `POST /api/ai/query`, `GET /api/ai/policy/latest`, `GET /api/ai/policy/run`, `GET /api/embeddings/clusters`, `GET /api/embeddings/stats`, `GET /api/honeypot`, `POST /api/honeypot/update`.
- New per-feature rate limits in `ai.zig`: 1 embed/5s, 1 honeypot-gen/min, 1 policy/week, 1 query/4s.

### Changed
- `ai.zig` reorganised around two primitives: `complete()` for free text (digest only) and `completeJson()` for schema-validated structured output. The latter sends `response_format: {"type":"json_schema","json_schema":{...,"strict":true}}` so Mistral validates server-side.
- `/api/ai/explain` now returns a typed `assessment` field instead of free-text `profile`. Falls back to `raw` if the model fails to conform to the schema.
- All template asset query strings bumped to `?v=15`.

## [0.2.0] - 2026-05-27

### Added: AI features (opt-in via `MISTRAL_API_KEY`)
- **Auto-ban annotation**: when an IP gets auto-banned for scanning, a background thread enriches the ban reason with a one-liner describing what the attacker probed. Cached per-IP for 24 hours so re-bans of the same IP do not re-spend Mistral quota.
- **Explain this IP**: per-IP modal on the Security page where Mistral profiles an IP based on its access pattern and recommends allow / monitor / block.
- **Daily digest**: every 24h (and on-demand via "Generate now" button), aggregate metrics get summarised into one paragraph. Stored at `~/data/digests.jsonl`, surfaced at the top of the Security page.
- New `ai.zig` module with per-feature token-bucket rate limit (1 annotate/min, 1 explain/6s, 1 digest/hour) so a runaway loop cannot drain quota.
- New endpoints (auth-required): `GET /api/ai/digest/latest`, `GET /api/ai/digest/run`, `POST /api/ai/explain`.
- New SSE event: `digest_ready`.

### Added: reliability
- **Process supervision**: `scripts/watchdog.sh` is a long-lived loop that checks every 30s whether `hp-server` and `cloudflared` are alive and restarts them if not. Also watches the tunnel-restart flag dropped by the in-process tunnel health watchdog.
- **Tunnel health watchdog** in-process: polls `cloudflared:20241/metrics` every 30s, classifies as `healthy` / `degraded` / `offline` / `unknown`, broadcasts state changes over SSE, and writes a restart-request flag if the tunnel stays unhealthy for more than 2 minutes.
- New endpoint: `GET /api/tunnel/health`. New SSE event: `tunnel_health`.
- **Encrypted backup**: `scripts/backup.sh` tarballs `~/data/`, all `~/.hp-server-*` files, and `~/.cloudflared/`, then encrypts with `age` using a passphrase from `BACKUP_PASSPHRASE`. Daily 14-backup retention. Boot script auto-runs once on every restart.
- **Graceful shutdown**: SIGTERM and SIGINT handlers call `httpz.Server.stop()` so JSONL flushes complete and SSE streams close cleanly.

### Added: security hardening
- **Pepper-based session secret**: 32-byte random pepper persisted at `~/.hp-server-secret.bin` (mode 600), folded into the HMAC key. An attacker who steals only the credentials file can no longer forge cookies; they need the pepper file too. New module `secret.zig`.
- **Geo-block** (opt-in, off by default): toggle on Settings page, Cloudflare `cf-ipcountry` header drives the policy. Authenticated and local requests are never affected, so self-locking is impossible. Persisted at `~/.hp-server-geoblock.txt`. New module `geoblock.zig`. New endpoints: `GET /api/geoblock`, `POST /api/geoblock/update`.
- **Audit log**: every operator action (block, unblock, change credentials, run digest, update geo policy) is recorded to `~/data/audit.jsonl` with actor, target, detail, and outcome. Rendered at the bottom of the Security page. New module `audit.zig`. New endpoint: `GET /api/audit`.

### Added: quality
- **Bundled icon font**: `Simple-Line-Icons.woff2` (30 KB) is now embedded into the hp-server binary and served from `/icons.css` and `/fonts/Simple-Line-Icons.woff2`. cdnjs is no longer a runtime dependency, the CSP no longer needs a cdnjs entry, and the dashboard works offline.
- **GitHub Actions CI**: `.github/workflows/zig-ci.yml` runs `zig fmt --check` plus Debug and ReleaseFast builds on every push and pull request.
- **All source files are now pure 7-bit ASCII**. JS files use `\u00B0` and `\u2014` escapes; HTML uses `&deg;` / `&mdash;` entities; Zig sources use `[UP]` / `[DOWN]` instead of emoji. Source can no longer be corrupted by binary-unsafe transfer pipes.

### Added: realtime
- Real-time UI updates via Server-Sent Events at `/api/stream`. Replaces all polling on Overview, Status, and Security pages.
- New `events.zig` module with thread-safe pub/sub bus + 25s heartbeat.
- Backend publishes events for every visit, login attempt, blocklist mutation, uptime probe result, plus a stats tick every 2 seconds when at least one subscriber is connected.
- `ws-status` indicator on every authenticated page (live / connecting / offline).

### Changed
- CSP no longer references `cdnjs.cloudflare.com` (font is now self-hosted).
- Cookie HMAC key now folds in the pepper byte string, so `SHA-256("rofi.session.v1:" || password || ":" || username || ":" || pepper)`.
- All template asset query strings bumped progressively (final state: `?v=14`).
- AI auto-ban annotation reuses cached results within a 24h window per IP.

### Fixed
- Memory values were displayed as bytes when they're actually kibibytes from `/proc/meminfo`. 8 GB of RAM rendered as 8 MB. New `fmtKB()` formatter handles all `*_kb` fields (process RSS/VSZ, system memory, swap). `fmtSize()` continues to handle raw byte counts (file sizes on `/files`).
- Stale browser cache referencing `RH.fetchInitialStats` from the pre-SSE `app.js`. Bumped all asset query strings uniformly across every template.
- CSP blocked Cloudflare's auto-injected Web Analytics beacon. Allowed it explicitly in `script-src` and `connect-src` since the toggle is account-scoped on Cloudflare's side and not exposed in the zone dashboard.
- Embedded woff2 had been corrupted in transit during a `tar | ssh` sync, so the font glyphs rendered as boxes in the dashboard. Re-pushed via `scp` (binary-safe) and cache-busted the font URL so Cloudflare's edge stops serving the corrupted cached copy.
- The degree symbol and em-dash in the temperature/fallback strings were rendering as `??` for the same reason. Replaced all non-ASCII characters with escapes/entities so the source files are pure 7-bit ASCII and cannot corrupt across pipes.

### Privacy / safety notes for AI
- API key lives only in `~/.hp-server.env` on the device (mode 600). Never in git, never in logs, never returned to clients. `.gitignore` matches `*.env`, `*-server.env`, `.env*`.
- All AI features degrade gracefully: if no key or network fails, server keeps running with the classic non-AI behavior.
- Data sent to Mistral: only IP, country, UA, paths, and aggregated counts. Never visit log content beyond what the operator explicitly requests (e.g. clicking Explain). Never credentials.

## [0.1.0] - 2026-05-26

### Added: security hardening pass
- `security.zig`: classification model with `self / unknown / bot / scanner / blocked`. No "human" label.
- Browser-fingerprint check using `Accept-Language`, `Sec-Fetch-Site`, `Sec-Fetch-Mode`. Anything missing those is flagged as `bot`.
- Auto-ban: 3 scanner hits in 10 minutes &rarr; 24h ban; 5 failed logins in 15 minutes &rarr; 1h ban.
- TTL-aware blocklist with per-entry reason. File format upgraded from one-IP-per-line to TAB-separated.
- Login attempt log at `~/data/logins.jsonl`.
- Security headers on every response: HSTS (1y, includeSubDomains), CSP, X-Frame-Options DENY, X-Content-Type-Options, Referrer-Policy, Permissions-Policy.

### Added: console consolidation
- `app.rofihosted.space` private console with shared sidebar across all internal pages.
- Pages: Overview, Status, Files, API explorer, Security, Settings.
- Settings page lets the operator change credentials in-browser without SSH.
- Login page (custom) replaces the browser HTTP basic auth dialog.

### Added: first public deployment
- Domain `rofihosted.space` registered with Namecheap, delegated to Cloudflare DNS.
- Named Cloudflare Tunnel `hp-server` with credentials JSON on the device, persistent ID.
- DNS records (CNAME) for `rofihosted.space`, `www.`, `app.`, `dashboard.`, `status.`, `api.`, `files.` &rarr; tunnel.
- Initial credentials seeded: user `mrofid`. Password set via console.

### Added: stack rewrite to Zig
- Zig 0.14.0 binary `hp-server` replaces the previous Node + Express + Postgres prototype.
- Modules: `auth`, `ratelimit`, `store`, `sysmon`, `uptime`, `files`, `badge`, `telegram`.
- Templates rendered via `@embedFile`, single-binary deploy.
- httpz with multi-host routing on a single port (8080).

### Added: initial provisioning
- Termux + sshd on Sharp Aquos Sense4 Plus (Android 12).
- Cloudflare Tunnel (Quick Tunnel first, then named) wrapped via `proot` to fix DNS / CA paths under Bionic.
- Termux:Boot script `~/.termux/boot/01-server.sh` to auto-start sshd, hp-server, cloudflared on phone restart.
- Wake lock acquired at boot to keep services alive in the background.

### Changed
- `/api/stats` no longer falsely reports CPU usage; on Android 12 those /proc paths are SELinux-blocked. Capabilities object exposes which paths actually work.
- Cookie auth secret derived from `HMAC(password + username)`. Changing the password invalidates every existing session.

### Removed
- Node.js, Postgres, Redis, Nginx, php-fpm. Disabled in Termux runit and uninstalled.
- Obsolete files: Node app skeleton, glances/postgres/nginx setup scripts, Zig hello/sqltest playgrounds.

[Unreleased]: https://github.com/rofiperlungoding/rofihosted/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/rofiperlungoding/rofihosted/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/rofiperlungoding/rofihosted/releases/tag/v0.1.0
