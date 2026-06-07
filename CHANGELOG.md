# Changelog

All notable changes to this project. Newest first.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project follows [Semantic Versioning](https://semver.org/) for tagged releases.

### Refactor: resolve cron + builder paths from HOME (P1-1, part 10) (2026-06-08)

`cron.zig` (the `.hp-server-cron.jsonl` store plus the per-task work-root and
DB paths) and `builder.zig` (project work, release, current, and build-log
paths) now resolve via `paths.zig` instead of an embedded Termux home literal.
Byte-identical on the phone. Remaining: dbcache, hosted, and the inline
literals in main.zig.

### Refactor: resolve honeypot, geoblock, embeddings, file-browser paths from $HOME (P1-1, part 9) (2026-06-06)

`honeypot.zig`, `geoblock.zig`, `embeddings.zig`, and `files.zig` (the file
browser root) now resolve via `paths.zig`. Byte-identical on the phone.
Remaining: dbcache, cron, builder, hosted, and inline literals in main.zig.

### Refactor: resolve invites, fingerprints, audit, AI-call log paths from $HOME (P1-1, part 8) (2026-06-06)

`invites.zig`, `fingerprint.zig`, `audit.zig`, and `ai.zig` (call log) now
resolve their store paths via `paths.zig`. Byte-identical on the phone.
Remaining: dbcache, cron, builder, embeddings, honeypot, geoblock, hosted,
files, and inline literals in main.zig.

### Refactor: resolve project secrets, auth DB, and supervisor paths from $HOME (P1-1, part 7) (2026-06-06)

`projsecrets.zig` (secrets vault), `projauth.zig` (per-project auth DB dir; the
cross-module `DBS_DIR` constant becomes `projauth.dbsDir(buf)`, updating the
project-purge path in `main.zig`), and `supervisor.zig` (project work dir, DB,
pid, and runtime-log paths) now resolve from `$HOME` via `paths.zig`.
Byte-identical on the phone. Remaining: dbcache, cron, builder, and the
single-const modules (audit, ai, embeddings, honeypot, geoblock, fingerprint,
invites, hosted, files) plus inline literals in main.zig.

### Refactor: resolve the projects registry + working dir from $HOME (P1-1, part 6) (2026-06-06)

`projects.zig` no longer hardcodes the Termux path for the project registry
(`.hp-server-projects.jsonl`) or the working-tree directory. The cross-module
`PROJECTS_DIR` constant is replaced by `projects.projectsDir(buf)` (resolves
`data/projects` from `$HOME`); callers in `main.zig` (static serving, project
delete) and `builder.zig` updated accordingly. Byte-identical on the phone.
Remaining: dbcache (`cache.db`, used by dbpool), projsecrets, projauth,
supervisor, and inline literals in main.zig.

### Refactor: resolve operator creds + tunnel marker paths from $HOME (P1-1, part 5) (2026-06-06)

`auth.zig` (`.hp-server-creds.txt`, the legacy operator credentials) and
`tunnel_health.zig` (`data/.tunnel-restart-requested` marker) now resolve via
`paths.zig`. Byte-identical on the phone, so operator login is unaffected.
Remaining: projects + dbcache (both expose paths cross-module), projsecrets,
projauth, supervisor, and inline literals in main.zig.

### Refactor: resolve blocklist, login log, and query store paths from $HOME (P1-1, part 4) (2026-06-06)

`security.zig` (`.hp-server-blocklist.txt`, `data/logins.jsonl`) and `query.zig`
(`data/visits.jsonl`, `data/uptime.jsonl`) now resolve their paths via
`paths.zig`. Byte-identical on the phone. Remaining: projects (cross-module
`PROJECTS_DIR`), projsecrets, projauth, dbcache, supervisor, tunnel_health,
auth creds, and inline literals in main.zig.

### Refactor: resolve webhooks + rules store paths from $HOME (P1-1, part 3) (2026-06-06)

`webhook.zig` (`.hp-server-webhooks.jsonl`) and `rules.zig`
(`.hp-server-rules.jsonl`) now resolve their store paths via `paths.zig`, same
pattern as parts 1-2. Byte-identical on the phone; no behavior change. Remaining
hardcoded paths: projects (registry + project dirs, used cross-module),
security (blocklist/login log), projsecrets, projauth, query, dbcache,
supervisor, tunnel_health, auth creds, and inline literals in main.zig.

### Refactor: resolve users + api-key store paths from $HOME (P1-1, part 2) (2026-06-06)

`users.zig` (`.hp-server-users.jsonl`) and `apikey.zig` (`.hp-server-apikeys.jsonl`)
now resolve their store paths from the home directory via `paths.zig` instead of
a hardcoded Termux literal, using the pattern from part 1 (a local
`paths.join(buf, FILE)` per file op; `.tmp` atomic-rewrite paths likewise). On
the phone `$HOME` is the Termux home, so paths are byte-identical — existing
users and API keys load unchanged (a successful auto-deploy, which authenticates
with the admin key, confirms the api-key path still resolves). Remaining
hardcoded paths (projects, webhooks, rules, blocklist, dbcache, data logs) are
the next increments.

### Refactor: resolve the pepper path from $HOME, not a hardcoded Termux literal (P1-1, part 1) (2026-06-06)

The integration smoke test (added the same day) revealed the server could not
boot anywhere but Termux: `secret.zig` created the pepper at a hardcoded
`/data/data/com.termux/files/home/...` path. `secret.zig` now resolves the
pepper file from the home directory via `paths.zig` (reads `$HOME` once at
startup, falling back to the Termux home). On the phone `$HOME` is the Termux
home, so the resolved path is byte-identical to the old literal — no behavior
change, no pepper regeneration. Several other state paths (users, projects, api
keys, blocklist, dbcache, data logs) are still hardcoded and remain the next
P1-1 increments; until then the smoke workflow provisions the Termux directory
layout so the binary still boots in CI.

### CI: integration smoke test (2026-06-06)

Adds a separate, non-required `integration-smoke` workflow that builds the
server, boots it against a throwaway `HOME`, and asserts it actually serves
(`/health`, apex landing, a static asset, `status /api/status`, and that the
admin host returns an auth response rather than a 5xx). This catches
runtime/init/route regressions that the build-only `zig-ci` cannot. It is
deliberately *not* part of branch protection, so a flaky run never blocks a
merge. Reusable script at `scripts/smoke-test.sh`.

### Docs: correct password-hashing description to match the implementation (2026-06-06)

A source-grounded re-audit of the external review found most code findings were
already implemented (bounded worker pool, Argon2id, boot capability checks,
collision-safe sqlite sentinel, proxy session-cookie stripping, fail-closed rate
limiter, cf-connecting-ip-only). The remaining mismatch was documentation:
`docs/SECURITY.md` and the `users.zig` header still described password hashing
as HMAC-SHA256 with Argon2id as "future work". Both now accurately describe the
shipped Argon2id hashing (pepper-bound, PHC string) with constant-time legacy
fallback and rehash-on-login. No behavior change.

### Reliability (P0-1): procguard waits out the previous instance on restart (2026-06-06)

Self-update restarts were racing the single-instance lock: the incoming binary
could try to acquire the `~/.hp-server.pid` flock while the outgoing instance
was still releasing it, hit `procguard`'s immediate refusal, and exit — leaving
`/health` down long enough to trigger an auto-rollback (observed rolling back an
otherwise-healthy build). `procguard.acquireOrExit` now **retries the flock for
~15 s** before giving up, bridging the kill→release window so restarts come back
cleanly. It still refuses (exit 1) if the lock is held for the whole window, so
the duplicate-instance guarantee is preserved. (`procguard.zig`)

### Hardening: collision-safe SQLite result framing (2026-06-06)

The `sqlite3` worker pool marked end-of-output with a predictable counter
(`__SQL_DONE_<n>__`) located with an unanchored substring search — a row value
containing that text could truncate the result. Now the sentinel is a per-query
**random nonce** and the search is **anchored to a line start**, so neither
accidental nor adversarial result data can end the frame early. (`dbpool.zig`,
unit-tested.)

### Security: tenant passwords now hashed with Argon2id (2026-06-06)

Replaces the single-round HMAC-SHA256 password hash (fast, weak against offline
brute force) with **Argon2id** (memory-hard: ~19 MiB, t=2). The install pepper
is bound in as a secret input (HMAC over the password before the KDF), so a
leaked hash file remains useless without the separately stored pepper.

- New `users.hashPassword` / `passwordMatches`; `create` and `changePassword`
  now produce argon2id PHC strings. (`users.zig`)
- **Rehash on login:** legacy HMAC hashes are verified, then transparently
  upgraded to argon2id on the next successful login — no forced reset.
- Operator login (legacy `~/.hp-server-creds.txt`, handled in `auth.zig`) is
  unaffected. Unit tests cover the argon2 roundtrip and legacy fallback.

### Security: stop leaking the operator session to project apps + webhook SSRF guard (2026-06-06)

- **Reverse proxy:** the proxy no longer forwards the platform session cookie
  (`rofi_session`) to project backends. Previously, when the operator browsed a
  tenant's subdomain, the browser sent the `.rofihosted.space` session cookie and
  the proxy forwarded it to the (untrusted) project process, which could harvest
  it. Other cookies and `Authorization` (needed by per-project auth) still pass
  through. (`proxy.zig`)
- **Webhooks:** `webhook.create` now rejects targets on loopback, link-local
  (incl. `169.254.169.254` cloud metadata), and private ranges, closing an SSRF
  path to the control plane (`127.0.0.1:8080`) and internal services.
  (`webhook.zig`)
- Both behaviors have unit tests; `proxy.zig` and `webhook.zig` were added to the
  CI test set.

### Security: backend deployment is now operator-only (2026-06-06)

Closes a multi-tenant isolation gap surfaced by an external review. Because all
Termux processes share one Android UID, a tenant-deployed backend process could
read the install pepper (`~/.hp-server-secret.bin`) and thereby derive every
project's secrets, JWT keys, and session HMACs — defeating the documented
per-project isolation. (Triage: no non-static tenant backend had ever run, so
the pepper was not exposed; no rotation was required.)

- **Gate:** `/api/projects/create` and `/api/projects/auto-deploy` now reject a
  non-`static` runtime for non-admin callers (`backend_deploy_operator_only`).
  The MCP tools and the `/v1/*` project endpoints were already admin-scoped, and
  project `update` cannot change a runtime, so this closes the tenant path.
- **Docs:** `docs/SECURITY.md` now states the accurate guarantee — per-project
  *cryptographic* separation that is not an OS isolation boundary, with backend
  deploy restricted to the operator. `README.md` positioning corrected: tenants
  get static hosting + managed DB + auth; backends are operator-only.

### Fixed + Changed: API keys, CI/CD hardening, docs, and dev workflow (2026-06-06)

**Fixed: API keys created with the `admin` scope were not admin, and keys could not be deleted.**
- Root cause: the Settings and Security pages submitted forms via `new FormData()`
  (`multipart/form-data`), but the server's `req.formData()` parses only
  `application/x-www-form-urlencoded`. Every field was dropped, so created keys
  silently defaulted to `scope=sql` and the revoke handler never received an `id`.
- Frontend now posts URL-encoded (like the rest of the app) in
  `app-settings.html` and `app-security.html`.
- `apikey.revoke` now hard-deletes the record (removes it from disk) instead of
  tombstoning, so dead keys stop accumulating; the UI action is relabeled *Delete*.
- Added `apikey.zig` to the test suite with admin-scope regression guards.

**Changed: deploy is now gated on CI and validated for the device target.**
- `zig-ci` additionally cross-compiles the phone target (`aarch64-linux-android`)
  via a new `zig build phone` step, so an Android-only build break is caught
  before deploy.
- `auto-deploy` now triggers on `zig-ci` success (`workflow_run`) rather than in
  parallel with it; a red build can no longer reach the phone. The
  `HP_ADMIN_API_KEY` deploy secret is configured, so auto-deploy works end-to-end.

**Added: development workflow + richer docs.**
- New [`CONTRIBUTING.md`](CONTRIBUTING.md): trunk-based flow (feature branch ->
  PR -> green CI -> squash-merge to a protected `main` -> auto-deploy). `main`
  is production and is no longer committed to directly.
- Mermaid diagrams added across all docs (`README`, `docs/*`, `cli/README`) for
  architecture, request lifecycle, deploy/CI, security, recovery, and CLI flow.

**Added: SSH ergonomics + branding.**
- `scripts/hp-status.sh` + `~/.bash_profile`: a live status summary on every
  interactive SSH login (read-only, interactive-guarded).
- `.gitattributes` forces LF on `.sh`/`.zig`/`.mjs` so Termux never chokes on CRLF.
- CLI rebranded: the package installs both `rofihosted` (full) and `rh` (alias),
  with npm SEO metadata. A `ROFIHOSTED` ASCII banner greets `rofihosted`/`rh` and
  the browser dev console.

**Added: server metrics.**
- `/metrics` now exports `http_requests_total` by status class,
  `auth_failures_total`, `ratelimit_denied_total`, worker-pool job counters, and
  the fail-closed `ratelimit_alloc_denied_total`.

### Changed: Engineering review + documentation consolidation (2026-06-05)

A documentation-only release (no binary changes, no deploy required). The goal
was to make the repository legible to a new reader and to record, in one
authoritative place, what should be improved next and why.

**New: prioritized improvement backlog.**
- New [`docs/ENGINEERING-REVIEW.md`](docs/ENGINEERING-REVIEW.md) — a full technical
  review with eighteen findings ranked across four tiers (P0 critical → P3 low),
  each stating the observation, its impact, and a concrete recommendation. It
  also records the design choices worth preserving and a suggested sequencing.
  The three P0 items concern operational robustness: duplicate-process races
  from inconsistent `pgrep`/`pkill` patterns, on-device compilation as a single
  point of deploy failure, and unreliable external uptime probes under Termux.

**Rewritten: canonical documentation set (formal, current, full English).**
- [`README.md`](README.md) — rewritten around the current four-surface
  architecture (apex / status / admin / app) with capability, technology, and
  operating-model sections and a documentation map.
- [`docs/README.md`](docs/README.md) — new documentation index.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — system design, request
  lifecycle, module map, and storage model brought up to date with the
  subdomain split and email subsystem.
- [`docs/SECURITY.md`](docs/SECURITY.md) — threat model and controls;
  consolidates the former anti-duplicate and API-key working notes.
- [`docs/OPERATIONS.md`](docs/OPERATIONS.md) — deploy workflow and incident
  playbooks; absorbs the former metrics-testing checklist.
- [`docs/RECOVERY.md`](docs/RECOVERY.md) — disaster recovery onto a fresh device.
- [`docs/API.md`](docs/API.md) — endpoint reference (session and API-key).

**Removed: stale and fragmentary notes (addresses finding P3-1).**
- Deleted eleven overlapping working-note files whose content is now folded into
  the canonical references: `ANTI-DUPLICATE-*.md` (×4), `API-KEY-AUDIT.md`,
  `API-KEY-INVENTORY.md`, `CACHE-IMPLEMENTATION-SUMMARY.md`, `CACHE-METRICS.md`,
  `CACHE-OBSERVABILITY-PLAN.md`, `METRICS-TESTING-CHECKLIST.md`, and the
  superseded `PROJECT-BRIEFING.md` (its content predated the subdomain split,
  the email feature, and the design overhaul, and is now covered accurately by
  `ARCHITECTURE.md` / `SECURITY.md` / `OPERATIONS.md`).

No source files changed; the binary on the device is unaffected by this release.

### Changed: Four-surface subdomain split + redesigned UI system (2026-06-05)

A full front-of-house overhaul. Routing, design language, and a real public status page.

**Routing (subdomain split):**
- `rofihosted.space` - public landing only (new minimal design).
- `status.rofihosted.space` - **new public status page** backed by `GET /api/status`, built from real signals (web reachability + live Cloudflare tunnel state). External reference probes (google/github/cloudflare) deliberately do **not** drive the public overall, since they can fail under Termux DNS.
- `admin.rofihosted.space` - operator console, gated to `role=admin` at the host level (tenants hitting it are 302'd to the app host).
- `app.rofihosted.space` - tenant console; operators are 302'd to the admin host for page loads (API calls pass through).
- Role-aware login + apex redirects (operators -> admin, tenants -> app). Logout -> apex. `dashboard`/`api`/`files` legacy subdomains now redirect to admin. `admin` added to the reserved-subdomain list so no project can claim it.
- `handleApp` refactored to `handleConsole(..., surface)`; new `handleStatus` + `apiStatus`.

**Design system (theme.css / app.css rebuilt, class API kept stable so every page adopts it):**
- **SF Pro Display**, subset to Latin and shipped as woff2 (~35 KB/weight, 5 weights, served from `/fonts`, embedded in the binary).
- **Zen-green signature** (`#15774b` light / `#4cc488` dark) that doubles as the "operational" status colour - the only chroma on screen carries meaning (green up / amber degraded / red down).
- Neutral surfaces, tighter radii (cards 10px, buttons 8px), bare Simple Line Icons (no chip containers), a gently "breathing" healthy status dot.
- New minimal landing (Microsoft-clean), redesigned probe metrics, asset cache bumped to `v=50`.

**Verification:** cross-compiled clean (x86_64-linux-gnu + aarch64 ReleaseFast); deployed to the phone; all four hosts return 200 over Cloudflare; fonts serve as `font/woff2`; `/api/status` reports operational with live tunnel data; operator login -> admin console renders; role bounces are 302 (non-cacheable); single hp-server + watchdog, no errors in log.

### Added: Transactional Email via Brevo HTTP API (2026-06-05)

Wired up real email sending for the signup verification flow (anti-duplicate Layer 3).

**New module:**
- New [`email.zig`](zig/hp-server/src/email.zig): sends transactional email through the Brevo HTTP API (`POST https://api.brevo.com/v3/smtp/email`). The JSON body is piped to `curl` over stdin (`--data-binary @-`), same proven subprocess pattern as [`ai.zig`](zig/hp-server/src/ai.zig)/[`telegram.zig`](zig/hp-server/src/telegram.zig). Every interpolated field (recipient, subject, HTML) is JSON-escaped, so no untrusted data ever touches a shell command line.

**Fixed in [`emailverify.zig`](zig/hp-server/src/emailverify.zig):**
- **STARTTLS bug**: the old SMTP-over-curl path built `smtps://host:587`, but port 587 is STARTTLS (needs `smtp://` + `--ssl-reqd`); `smtps://` is implicit TLS on 465 only. Verification email sends against Brevo would have failed.
- **Shell injection risk**: the old path interpolated email/username/body into a `sh -c` heredoc. Rewritten to build `curl` argv + pipe the message over stdin (no shell).
- Sending now prefers the Brevo HTTP API when `BREVO_API_KEY` is set, with the (now safe) raw-SMTP relay as a fallback.
- Verification emails are now styled HTML (Anthropic-inspired palette) with a plaintext alternative; the username is HTML-escaped.

**Config:**
- New env vars (loaded by `start-zig-server.sh`): `BREVO_API_KEY`, `MAIL_FROM_EMAIL`, `MAIL_FROM_NAME`. `SmtpConfig.isConfigured()` now returns true when the API key is present, which is what gates the verification step in the signup handler.
- New [`scripts/set-email.sh`](scripts/set-email.sh): upserts those three keys into `~/.hp-server.env` without clobbering other secrets, validates the key against `/v3/account`, and offers an optional live test send.
- The `MAIL_FROM_EMAIL` must be a Brevo-verified sender (or an address on a domain authenticated in Brevo). On a fresh account the signup email is auto-verified; verify the `rofihosted.space` domain (SPF + DKIM in Cloudflare) to send from `noreply@rofihosted.space`.

**Verification:** cross-compiled clean for `x86_64-linux-gnu` (Zig 0.14.0); `email.zig` (2) and `emailverify.zig` (6) unit tests pass; live send to the account confirmed (HTTP 201, messageId returned).

### Fixed: Backup System Critical Bug + Minor Issues (2026-06-02)

**CRITICAL: Backup data loss prevented**
- **backup-quick.sh missing critical data**: Previous backups only included 10 config files, missing ALL user data (visits.jsonl, uptime.jsonl, logins.jsonl, audit.jsonl, users.jsonl, cache.db, embeddings.bin). This meant backups were essentially useless for disaster recovery. Fixed to include all 20+ critical files. New backups are 18MB vs 0MB before.

**Backup verification automation:**
- New [`verify-backup.sh`](scripts/verify-backup.sh) script for automated backup integrity checks
- Downloads latest from R2 or checks local backup
- Verifies tarball integrity, critical file presence, and SQLite database integrity
- Outputs JSON summary for monitoring integration
- Can be run monthly via cron

**Minor issues resolved:**
- **Cloudflared stream cancellations**: Investigated - these are normal client disconnects (error code 0), not server bugs. SSE heartbeat already configured at 25s interval.
- **Unsolicited HTTP responses**: No longer appearing in logs after shutdown handler race condition fix.
- **SSH rate limiting**: Confirmed already configured by default (maxauthtries=3, maxstartups=10:30:100, logingracetime=30).

### Fixed: System Audit Remediation (2026-06-02)

Comprehensive audit revealed and fixed 8 critical issues, 5 warnings, and 3 recommendations. All high-priority bugs have been resolved.

**Critical fixes:**
- **Credentials file corruption**: Fixed empty/malformed `~/.hp-server-creds.txt` that only contained password. Restored proper two-line format (username + password). Authentication now works correctly.
- **Watchdog RSS check bug**: Added null check in [`watchdog.sh`](scripts/watchdog.sh):155 to prevent "Illegal number" error when process dies between pgrep and /proc read. RSS monitoring now stable.
- **GPA memory leak detection**: Added proper leak detection in [`main.zig`](zig/hp-server/src/main.zig) GPA deinit. Memory leaks now logged on shutdown for debugging.
- **Shutdown handler race condition**: Replaced unsafe signal handler with async-signal-safe atomic flag pattern. Moved flush() and server.stop() to main thread shutdown loop. Prevents deadlock and undefined behavior per POSIX.
- **WAL checkpoint frequency**: Added periodic `PRAGMA wal_checkpoint(TRUNCATE)` to [`dbcache.zig`](zig/hp-server/src/dbcache.zig) syncLoop. Runs every 5 minutes to reduce WAL file size and improve query performance.

**Documented for future work:**
- **Hardcoded paths**: Added TODO comments in [`main.zig`](zig/hp-server/src/main.zig) for refactoring hardcoded Termux paths to use HOME env var. Paths remain hardcoded but documented.
- **hp-server.log investigation**: Confirmed log file redirection is working correctly. File is empty because Zig binary uses structured logging via JSONL files, not stdout/stderr. This is by design.

**Deployment:**
- All fixes pushed to GitHub (commits 10f4dd7, 6960356, 845e5a3, e1a685c)
- Binary rebuilt and deployed to device
- Watchdog script updated on device
- Server restarted successfully with new binary

See [`AUDIT-REPORT.md`](AUDIT-REPORT.md) for complete findings and remediation details.

## [Unreleased]

### Added: Multi-tenant Phase 3 - Developer Experience

The platform tightens its grip on the developer-experience side. A solo dev can paste a repo URL and have the project running, with database, in under three minutes. MCP and CLI mirror the dashboard so AI assistants can ship code without opening a browser.

**One-click auto-deploy from a repo URL:**
- New `POST /api/projects/auto-deploy` endpoint orchestrates analyze + create + deploy server-side. Body: `repo_url`, optional `branch` and `subdomain_hint`.
- Server validates the URL (https only, no embedded credentials, &le; 512 chars), runs `analyzeRepoCore` (AI-augmented) with deterministic fallback to `previewRepoCore` when AI is disabled or quota-exhausted.
- `deriveAutoSubdomain` lowercases + sanitizes the analyzer's name suggestion, applies a 4-char hex suffix when the result would be too short or hit the reserved list (app/www/dashboard/status/api/files), retries once on collision.
- Project gets stamped with caller's `owner_id` (admin keys may pass `owner_id=` to assign on behalf of a tenant; absence leaves the project unowned per legacy admin convention).
- Wizard step 1 has the existing "Auto-deploy from repo" button rewired to a single fetch + a single SSE follow against `/api/projects/log-stream?id=...&kind=build`. Build markers (`=== build complete`, `=== published`, `=== build failed`) advance the four stage indicator (analyze / create / deploy / live).
- Tenant quota gate runs server-side (`max_projects`) plus client-side (button disabled with tooltip) so the UI never lies about availability.

**DB wizard step:**
- New `Project.db_mode` field on the registry, default `.sqlite`, persists through JSONL load/save with backwards-compat default for legacy projects (no migration).
- Wizard inserts a "Database" step (between Runtime and Env vars) with a `.scope-chips` toggle: SQLite (zero config) or Bring your own Postgres. Static projects skip the step entirely.
- Postgres path: validates `postgres://` / `postgresql://` URL, posts `db_mode=postgres` on create, then writes the URL into the project's encrypted secrets vault as `DATABASE_URL` before kicking off the deploy. Supervisor's existing override logic picks the secret over the auto-injected SQLite URI.
- Resources tab gains a per-project banner showing the active mode and pointing to the right escape hatch.

**Public landing wired to the apex:**
- `handleRoot` now serves `public.html` for unauth requests at `/`, redirects authed users to the console (`/projects` for tenants, `/` console for admins).
- `/v1/public/stats` response shape extended (`projects_running`, `total_users`, `uptime_days`, `version_short`) without breaking existing callers. Short SHA is cached 5 minutes in-process to avoid spawning a `git rev-parse` subprocess per request.
- Hero now leads with Sign up + Sign in dual CTA. Stats strip degrades to `--` placeholders on any failure.

**Developer-facing MCP tools (4 new):**
- `auto_deploy {repo_url, branch?, subdomain_hint?}` mirrors the HTTP endpoint; tenant ownership enforced; admin keys may pass `owner_id`.
- `tail_build_log {project_id, max_lines?}` returns trailing log lines plus a `complete` flag derived from terminal markers.
- `get_db_url {project_id}` returns the effective `DATABASE_URL`. SQLite mode returns the `file:` URI; postgres mode returns a masked form (`postgres://***:***@host:port/dbname`); the raw secret is never exposed via this tool.
- `set_db_url {project_id, url}` toggles modes. Empty/null clears the secret and reverts to sqlite. Non-empty stores the secret and flips db_mode to postgres.
- All four respect the existing tenant scoping in `PROJECT_TOOLS`.

**CLI 0.3.0:**
- `rh deploy <repo-url> [--branch=main] [--sub=name]` is now the primary deploy form. Calls `/api/projects/auto-deploy`, opens the SSE stream, renders a TTY-friendly 4-stage indicator on stderr, exits 0 on `=== published`, 1 on `=== build failed`, 2 on 5-minute timeout. Pipes log lines to stdout for `tee`.
- Existing `rh deploy <dir> <sub>` zip-upload flow is preserved as a secondary path for users who don't want a Git remote.
- New `rh db url <sub>` reads the effective DATABASE_URL (masked when postgres). `rh db url <sub> <postgres-url>` sets the secret + flips db_mode. `rh db url <sub> --clear` reverts to sqlite.
- `rh whoami --json` for scripting; existing `rh whoami` keeps human-readable output.
- `rh --version` reads from package.json so help and version stay in sync.

**API surface (additive):**
- `apiProjectsCreate` and `apiProjectsUpdate` now honor a `db_mode` form field (default sqlite, parses via `projects.DbMode.fromString`).
- `/api/me` exposes `max_projects` and `max_rss_mb` so the dashboard can grey out the New project button when a tenant hits their quota.

Cache busters bumped v=39 -> v=40 across all 20 templates.

Smoke tests: 96/96 -> 108/108 (12 new checks for apex landing, public stats shape, /api/me quota, auto-deploy URL validation, MCP tools/list contents).

Note for the operator: `~/test-everything.sh` lives on the phone outside the rsync set (`self-update.sh` only mirrors `zig/hp-server/`). After this release, scp the new test script:

```sh
scp scripts/test-everything.sh hp:~/test-everything.sh
```

### Added: Zero-config DATABASE_URL + Resources tab (Phase 2.9 - dev experience)

Tenants no longer need to know about hp-server's storage layout to use it. Wizard creates a project, pick the runtime, click deploy - it just works.

**Auto-injected env vars (every project, every spawn):**
- `DATABASE_URL=file:<path>` - per-project SQLite. Picked up automatically by Drizzle, Prisma, Knex, SQLAlchemy, Sequelize, and most ORMs.
- `ROFI_DB_PATH=<path>` - raw path for libraries that want it (better-sqlite3 etc).
- `ROFI_PUBLIC_URL=https://<sub>.rofihosted.space` - so server-side code can build absolute links.
- `ROFI_AUTH_BASE=/auth` - the auth-as-a-service mount point.
- Plus the existing `PORT`, `HOST=127.0.0.1`, `NODE_ENV=production`, `ROFI_PROJECT_ID`, `ROFI_SUBDOMAIN`.

A user-set `DATABASE_URL` via the secrets vault overrides the auto-injected one - useful if you'd rather use Supabase/Turso/Neon Postgres.

**Resources tab on the project detail page:**
- Per-project DB path, code snippets for Node (better-sqlite3, Drizzle), Python (sqlite3, SQLAlchemy).
- Auth endpoints (signup/login/verify) with frontend snippet.
- Full env var reference.
- Cron pointer.
- "Want Postgres?" section pointing to Supabase, Turso, Neon, Upstash free tiers.

**Wizard step 3 (env vars):**
- Now leads with a callout listing every auto-injected var so devs don't accidentally re-add them.

Phone hardware reality: 6 GB RAM, multi-tenant. Cannot host Postgres locally. SQLite is the right choice for typical project workloads (1-10k req/day, &lt;1 GB data). Hosted Postgres via secrets is the escape hatch for anything bigger.

Cache busters bumped v=38 -> v=39.

### Added: Tenant API keys + MCP per-user scoping + project transfer + RAM budget (Phase 2.5 - 2.8)

The platform is now fully ready to host multiple developers safely.

**API keys (Phase 2.5):**
- `Record.owner_id` field. Tenants only see + manage their own keys; admins see all.
- Tenants cannot mint admin-scoped keys (403 `admin_scope_forbidden`).
- Revoke gated on owner match (tenant can revoke own keys; admins can revoke any).
- New `Manager.listJsonFiltered()` and `ownerOf()` helpers.

**MCP per-user scoping (Phase 2.6):**
- POST `/mcp` accepts both admin and per-tenant API keys. The dispatcher derives `caller_owner` from `rec.owner_id`.
- Admin-only tools (exec_shell, trigger_update, list_blocked_ips, list_recent_visits, system_info, get_version, list_backups, trigger_backup, search_audit, block_ip, unblock_ip) refuse non-admin callers with `-32003: this tool is admin-only`.
- Project-scoped tools (start/stop/deploy/secret/db/log) verify `caller_owner == project.owner_id` before dispatching. Cross-tenant access returns `forbidden: not your project`.
- `list_projects` filters by owner so each tenant sees only their own.

**Project ownership transfer (Phase 2.7):**
- `Manager.setOwner()` on projects.zig.
- POST `/api/projects/transfer` (admin-only). Body: `id`, `owner_id`. Empty `owner_id` unowns the project (legacy admin-only state).

**Per-user RAM budget (Phase 2.8):**
- `apiProjectsStart` pre-checks: when a tenant tries to start a backend project, sum the `rss_limit_mb` of their currently-running backend projects + this project. If total > `user.max_rss_mb`, refuse with `rss_quota_exceeded` and a detailed payload (`max_rss_mb`, `currently_used_mb`, `would_use_mb`).
- Admins are unlimited. Static projects don't count.

**Verified end-to-end:**
- Tenant can create / list / revoke own API keys, blocked from admin-scope.
- Tenant MCP key works for project tools (filtered to own); admin tools rejected.
- Admin transfer projects to tenants; tenants see them immediately.
- 96/96 smoke tests across all phases.

Cache busters bumped v=37 -> v=38.

### Added: Role-aware UI + Telegram alerts + CLI signup (Phase 2.2 + 2.3)

Tenants and admins now see different dashboards from the same console.

- `/api/me` returns role + status + user_id (was just username). The dashboard JS uses this to set `body.role-{admin|tenant}` so CSS can hide / reveal sections per role.
- `/admin/*`, `/api/users/*`, `/api/invites/*`: hard-gated server-side. 401 if unauthenticated, friendly 403 HTML if a tenant tries to peek.
- `src/templates/app.js loadCurrentUser()`: drops body classes, fetches pending-user count for admins, badges it on the Users nav so the operator never misses an approval request.
- `src/templates/app.css`: tenants don't see Security or Shell (operator-scoped); `[data-admin-only]` toggling for the Admin nav section.
- All 8 dashboard pages got a hidden Admin nav block (Users + Invites). Visible to admins, hidden from tenants by CSS + JS.
- Cache busters bumped v=35 -> v=36.

### Added: Telegram alerts on pending signup
- `handleSignupSubmit`: when a self-signup goes pending, the operator gets a Telegram message with username, email, reason, and an `/admin/users` link. No-op when Telegram is unconfigured.

### Added: rh signup CLI
- `cli/rh.mjs`: new `rh signup` interactive flow. Walks through username/email/password (with optional invite code). Prints next steps depending on instant approval (invite) or pending review (self).

### Added: Per-project ownership + tenant isolation (Phase 2.1)

Tenants can now create and manage their own projects without seeing or touching anyone else's. Admins continue to see everything.

- `src/projects.zig`: `Project.owner_id` field, persisted in JSONL. Pre-multi-tenant projects (owner_id == "") are admin-only by default. New `listSnapshot()` and `writeProjectJson()` helpers.
- `src/main.zig`:
  - `apiProjectsList`: filters to caller's own projects unless they're an admin.
  - `apiProjectsCreate`: sets owner_id to creator. Enforces `max_projects` quota for tenants (admin unlimited).
  - `guardProjectOwnership()`: centralized ownership pre-check that runs before every `/api/projects/<id-bound>` dispatch. Pulls id from query / form / JSON body, blocks tenants from acting on projects they don't own. Admin API keys (`X-API-Key` with admin scope) bypass.
  - `requireUser()`: cookie-or-admin-API-key identity resolution. Admin keys map to a synthetic legacy admin Identity so all `/v1/projects/*` and CLI flows keep working.
- `/v1/projects` keeps unfiltered admin-API-key listing for the rh CLI / GitHub Actions / MCP.

Verified end-to-end:
- Tenant creates project -> owner_id stamped
- Tenant lists projects -> only sees own
- Tenant deletes their own project -> succeeds
- Tenant attempts to delete someone else's project -> 403 forbidden

### Added: Multi-tenant signup, invites, admin approval

This is the foundation for letting other developers use rofihosted. Phase 1 covers user storage, signup flows, and admin approval. Per-user project ownership and resource quotas come in Phase 2.

- `src/users.zig`: per-user records with role (admin/tenant), status (pending/active/suspended/rejected), per-user salt + HMAC password hash. Persists to `~/.hp-server-users.jsonl`. The legacy operator from `~/.hp-server-creds.txt` is auto-migrated as the first admin on boot so existing logins keep working.
- `src/invites.zig`: single-use (or N-use) invite codes, format `RH-XXXX-XXXX`, optional expiry. Persists to `~/.hp-server-invites.jsonl`.
- `src/auth.zig`: new v2 cookie format `v2.<payload>.<sig>` with per-user HMAC keys derived from `password_hash + pepper`. Changing a user's password instantly invalidates their other sessions. The existing v1 cookie format (legacy operator) is still recognized side-by-side. `currentUser()` and `isAuthenticated()` transparently handle both.
- New routes:
  - `GET /signup`, `POST /signup/submit`, `GET /signup/check-invite`, `GET /signup/pending` (public, no auth).
  - `GET /admin/users`, `GET /admin/invites` (admin-only dashboard pages).
  - `GET /api/users`, `POST /api/users/{approve,reject,suspend,unsuspend}` (admin-scoped JSON).
  - `GET /api/invites`, `POST /api/invites/{create,revoke}` (admin-scoped JSON).
- New templates:
  - `signup.html`: live invite-code validation, two-mode form (instant approval with code, manual approval without).
  - `signup-pending.html`: holding page for self-signups awaiting approval.
  - `app-admin-users.html`: filterable user list with approve/reject/suspend/unsuspend buttons. Auto-polls every 15s.
  - `app-admin-invites.html`: invite generator + table with copy-link buttons.
  - `public.html`: 'Sign up' CTA in the marketing nav.

### Changed: cache busters bumped v=34 to v=35.

### Fixed: operator IP no longer auto-bans itself when running smoke tests

- `src/security.zig`: `AutoBan` now keeps a per-IP "trusted" map. Any request that authenticates (cookie session or admin API key) marks the source IP as trusted for 30 minutes. While trusted, scanner hits are still counted for visibility but never trigger the blocklist.
- `hostRouter` calls `app.autoban.markAuthenticated(ip)` on every authenticated request. The TTL refreshes on each call so an active session keeps the IP trusted indefinitely.
- Closes a real bug: running `~/test-everything.sh` from the operator's IP would intentionally hit scanner paths (`/.env`, `/wp-admin`, `.php` URLs) for honeypot coverage. Even though those requests came from `cls=.self`, parallel anonymous scanner-classified requests from the same IP could trip the 3-strikes auto-ban and lock the operator out of their own dashboard mid-test.

### Fixed: self-update.sh adopted new binaries reliably

- `scripts/self-update.sh`: the file-change detector compared `git diff --name-only "$BEFORE" "$AFTER"`, but `$AFTER` was never set (the variable holding origin/main is `$REMOTE`). The diff returned empty, every legitimate code update was misclassified as `no_restart_needed`, and rebuilt binaries waited around until something else SIGTERM-ed hp-server. Single-character fix: `$AFTER` -> `$REMOTE`.

### Changed: settings page redesign

- `src/templates/app-settings.html`: full rewrite into the same `.layout > .sidebar > .main > .content` shell every other dashboard page uses. New CSS primitives: `.scope-chips` pill toggle (replaces native checkbox the operator complained about), `.stat-grid`, `.info-grid`/`.info-row`, `.ver-row`, `.bk-grid`, `.fresh-key`, `.code-out`. Sections reordered: Credentials, Geo-block, Honeypot, DB cache, API keys, Webhooks, System, Backups, Operator rules.
- `src/templates/app.css`: dropped `max-width: 540px` from `.form-card` so cards span the same fluid width as `.summary-grid` / `.section-head` on every other page. Added `margin-bottom: 1.5rem` directly to `.form-card` so cards still space cleanly without relying on outer flex gap. `.submit-row` gets `flex-wrap: wrap` so the button group never overflows on narrow viewports.
- All HTML templates bumped from `?v=33` to `?v=34` for cache invalidation.

### Changed: smoke test reliability

- `scripts/test-everything.sh`: `R2_CONFIGURED=$(grep -c X || echo 0)` produced multi-line `0\n0` when grep found nothing, breaking `[ "$VAR" -gt 0 ]`. Drop the `|| echo 0` fallback - `grep -c` always emits a single integer. Bumped backup-listing curl timeouts from 5s -> 15s and 60s for the R2 upload step. Test suite now hits 96/96 green.

### Added: Projects (the kingdom-of-one PaaS, all in one phone)

This is the centerpiece. The phone now behaves as Netlify + Vercel + Supabase + Railway combined: paste a repo link, pick a subdomain, click Deploy, and a fullstack app runs 24/7 with built-in database + auth + secrets + scheduled tasks. Five phases of work:

**Phase A: Foundation** (commit `4ac2c68`)
- `src/projects.zig`: registry of projects with id (16-hex), name, subdomain (claimed exclusively), repo_url, branch, runtime (static/node/python/bun/generic), install/build/start commands, port allocator [3000-3999], status, timestamps. Persisted to `~/.hp-server-projects.jsonl`.
- `src/projsecrets.zig`: per-project AES-256-GCM secrets vault. Key derived from per-install pepper plus project id (versioned domain separator). Plaintext only at decrypt time. File magic `RHS1` + 12-byte nonce + 16-byte tag.
- `tryServeProject()` runs in `hostRouter` BEFORE the legacy `hosted.tryServe`. Static-runtime projects served from `~/data/projects/<id>/current/` with pathsafe traversal protection.
- New page `/projects` with a sidebar entry. Card-grid project list and 4-step wizard (Source -> Subdomain -> Runtime -> Secrets) plus detail modal with secrets editor.
- Endpoints: `/api/projects/{list,create,update,delete}` and `/api/projects/secrets/{list,set,delete}`.

**Phase B: GitHub auto-deploy + build pipeline** (commit `8d280cc`)
- `src/builder.zig` orchestrator. `deployAsync(id)` spawns a detached thread that walks: clone (git clone --depth=1, idempotent fetch + reset --hard on re-runs) -> install -> build -> publish (cp -a + atomic ln -sfn).
- Step output captured to `~/data/projects/<id>/logs/build.log` with header/footer markers.
- HMAC-SHA256 GitHub webhook receiver at `/v1/github/<project_id>` (constant-time signature compare). Honors X-GitHub-Event (ping pongs, push deploys if branch matches).
- New endpoints: `/api/projects/deploy`, `/api/projects/logs?id=`. Detail modal gains Deploy button + log tailer + webhook URL/secret reveal.

**Phase C: backend supervisor + reverse proxy** (commit `6c00f61`)
- `src/supervisor.zig`: per-project process. `start(id)` resolves cwd to current/ (or repo/), decrypts secrets vault and merges with hp-server's env, injects `PORT` / `ROFI_PROJECT_ID` / `ROFI_SUBDOMAIN` / `HOST` / `NODE_ENV=production`, spawns `sh -c <start_cmd>` with stdout+stderr piped to a drain thread that appends to runtime.log.
- `stop(id)`: SIGTERM -> 5s grace -> SIGKILL with auto-restart pause to respect manual stops. `restart(id)`: stop + start.
- `autoRestartLoop` runs every 5s. For each entry where state==running but PID is dead, sleeps backoff_ms (1s -> 60s ceiling) and respawns. Backoff resets on success.
- `restartPersisted()` at boot: walks the registry and starts every backend project whose status was `running` at last shutdown.
- `src/proxy.zig` HTTP/1.1 reverse proxy. 5s connect timeout, 30s total, 8 MB request body cap, 16 MB response cap. Decodes chunked transfer-encoding from upstream.
- `tryServeProject` routes backend projects through `proxy.proxy()` when state==running, returns clean 503 'project not running' otherwise.
- New endpoints: `/api/projects/{start,stop,restart}`, `/api/projects/status?id=`, `/api/projects/runtime-logs?id=`.

**Phase D: built-in auth-as-a-service + per-project DB** (commit `7c31131`)
- `src/projauth.zig`: signup/login/verify, password hashing via HMAC-SHA256 with 16-byte random salt + per-install pepper, JWT (HS256) signed with key derived from pepper + project_id (so projects can never sign each other's tokens), TTL 7 days.
- Per-project DB at `~/data/dbs/<project_id>.db` (auto-created, schema: `users(id, email UNIQUE, password_hash, salt, created_at, last_login)`).
- `tryServeAuth()` intercepts `<sub>/auth/{signup,login,verify}` BEFORE the static / proxy paths so even backend projects never see /auth/* requests. CORS preflight handled.
- `supervisor.zig` injects `ROFI_DB_PATH=~/data/dbs/<id>.db` into the project env.

**Phase E: polish - the 'kerjain full' phase** (commit `9356ee4`)
- ZIP upload: `POST /api/projects/upload?id=<pid>` with raw zip bytes as body, validates `PK\x03\x04` magic, builder.deployZip() unpacks and atomic-swaps. 64 MB max body.
- Releases history + atomic rollback: `GET /api/projects/releases?id=`, `POST /api/projects/rollback {id, release}`. Backend projects auto-restart after rollback.
- `POST /api/projects/sql {project_id, sql}` returns parsed JSON rows via `sqlite3 .mode json`. 256 KB SQL cap, 8 MB result cap.
- `src/cron.zig` per-project scheduled tasks at `~/.hp-server-cron.jsonl`. Schedule formats: `every Ns/Nm/Nh/Nd` (floor 30s) and 5-field cron expressions. Loop ticks every 30s. Tasks inherit secrets and ROFI_* env, output captured to cron.log. Endpoints: `/api/projects/cron/{list,create,delete,toggle,run}`.
- Auth UI snippet generator: 'Copy HTML snippet' button generates a complete drop-in signup/login HTML.
- Detail modal now shows: ZIP upload, releases list with rollback buttons, SQL textarea + Run + List tables, cron task table + add form.

### Added: kingdom-of-one expansion (pre-Projects)

- **Static site hosting** at any `<sub>.rofihosted.space`. `~/hosted/sites/<sub>/releases/<UTC ts>/` + `current` symlink. Per-site LRU cache. SPA fallback. New modules `pathsafe.zig` and `hosted.zig`. Cloudflared ingress simplified to wildcard.
- **Persistent sqlite3 subprocess pool** (`dbpool.zig`). 5x lower per-query latency vs spawning per call.
- **API key manager** (`apikey.zig`). SHA-256-hashed scoped tokens.
- **`/v1/execute` SQL-over-HTTP**. Auth via `X-API-Key` header.
- **Outbound webhook dispatcher** (`webhook.zig`). 7 event types subscribable per hook.
- Watchdog v2: explicit `PREFIX` export, HTTP `/health` probe, hard 384 MB RSS ceiling.

### Added: AI v3 (mid-cycle)
- Streaming explain. AI observability. Prompt injection defense. Semantic prompt cache. Reflection pass on weekly policy. Anomaly detection.

### Added: storage v2
- `writebuf.zig` (5s flush + SIGTERM-safe). `rules.zig` (operator rule engine). `dbcache.zig` (SQLite read-side cache). `/api/ai/scrub` log scrubbing.

### Added: AI v2

- **Structured outputs everywhere**: auto-ban annotation and IP explain now use Mistral's `response_format: json_schema` mode and return typed assessments (`actor_type`, `risk_score 0-100`, `confidence 0.0-1.0`, `recommended_action: allow|monitor|block_24h|block_permanent`, indicators array). The Security UI renders these as colored pills and offers a one-click "Apply this action" button when the AI recommends a block.
- **Embeddings + behavioural clusters**: each distinct (UA, path-pattern) is embedded once via `mistral-embed` (1024-dim) and stored in a flat in-memory + on-disk index at `~/data/embeddings.bin`. A "Behavioural clusters" panel on the Security page groups patterns with cosine similarity >= 0.85, surfacing coordinated scanner/bot families. Pure brute-force search at this scale (cap 4096 patterns), no HNSW needed. New module `embeddings.zig`.
- **Weekly policy review**: every 7 days (and on-demand), the server batches the past week's per-IP behavior and asks Mistral to produce a structured list of `{ip, suggested_action, risk_score, rationale}`. Each suggestion in the UI has a one-click "Apply" that pre-fills the rationale into the manual block flow. Persisted at `~/data/policy.jsonl`.
- **AI honeypot (opt-in, default off)**: when enabled in Settings, scanner-classified requests targeting common probe paths (`/wp-admin`, `/.env`, `/.git/config`, etc) get answered with AI-generated decoy content instead of a 403. Generated content uses obviously-fake placeholder values (`honeypot-decoy-00000`, `DECOY-NOT-A-REAL-KEY-XXXX`). Cached forever per kind so we never re-call Mistral. New module `honeypot.zig`.
- **Natural-language query bar**: a small "Ask" button in the topbar of every authenticated page opens a popover where you can type free-form questions like "top scanners today", "failed logins last hour", "explain 1.2.3.4". Mistral plans the call via structured output (`function` enum with strict args schema), the server executes it locally against `~/data/*.jsonl` and the blocklist, and the popover renders the result. No mutations possible. New module `query.zig`.
- New endpoints (auth-required): `POST /api/ai/query`, `GET /api/ai/policy/latest`, `GET /api/ai/policy/run`, `GET /api/embeddings/clusters`, `GET /api/embeddings/stats`, `GET /api/honeypot`, `POST /api/honeypot/update`.
- New per-feature rate limits in `ai.zig`: 1 embed/5s, 1 honeypot-gen/min, 1 policy/week, 1 query/4s.

### Changed (AI v2)
- `ai.zig` reorganised around two primitives: `complete()` for free text (digest only) and `completeJson()` for schema-validated structured output. The latter sends `response_format: {"type":"json_schema","json_schema":{...,"strict":true}}` so Mistral validates server-side.
- `/api/ai/explain` now returns a typed `assessment` field instead of free-text `profile`. Falls back to `raw` if the model fails to conform to the schema.

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
