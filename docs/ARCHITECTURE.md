# Architecture

This document describes the design of rofihosted: its process model, request
lifecycle, host routing, module organization, storage strategy, concurrency,
and deployment pipeline. It is the canonical reference for how the system is
put together and why.

---

## 1. Design principles

The system is shaped by four constraints and the principles that follow from
them.

1. **It runs on a phone under Termux.** There is no glibc, the standard
   shipping locations for CRT files are absent, and the Zig standard-library
   HTTP client has DNS difficulties on Bionic. The system therefore prefers
   well-tested external binaries (`curl`, `sqlite3`, `cloudflared`) invoked as
   subprocesses over fragile in-process equivalents.
2. **It is a single node with no replicas.** Recoverability matters more than
   availability engineering. Persistent state is append-only and the durable
   record is plain text that can be inspected and replayed.
3. **It is operated by one person.** The codebase is kept small, dependency-
   light, and readable. Complexity is added only where it earns its keep.
4. **It is exposed to the public internet.** Every request is untrusted until
   classified, and security controls run in the hot path.

---

## 2. Process model

Two cooperating OS processes run on the device:

- **`hp-server`** — the Zig binary. It owns the listening socket on
  `127.0.0.1:8080` and all application logic.
- **`watchdog.sh`** — a shell supervisor. It restarts `hp-server` if the
  process dies or fails an HTTP health probe, restarts `cloudflared` if the
  tunnel drops, and restarts the server proactively if its resident memory
  exceeds a configured ceiling.

Public traffic reaches the server through `cloudflared`, which maintains a
persistent outbound connection to the Cloudflare edge and forwards requests to
the local port. There is no inbound port exposed on the device or the home
network.

Inside `hp-server`, the main thread starts the httpz worker pool and then spawns
a set of long-lived background threads:

| Thread | Responsibility | Cadence |
|--------|----------------|---------|
| httpz workers | Accept and dispatch HTTP / SSE | — |
| uptime checker | Probe configured targets | 60 s |
| store rotator | Bound JSONL files by size | hourly |
| SSE heartbeat | Keep event streams alive | 25 s |
| stats tick | Publish process/memory stats | 2 s |
| daily digest | AI summary (if enabled) | 24 h |
| weekly policy review | AI policy audit (if enabled) | 7 d |
| tunnel health | Poll `cloudflared` metrics | 30 s |
| embeddings persist | Flush vector store | 5 min |
| hourly backup | Offsite snapshot to R2 | 60 min |

Short-lived threads are also spawned per event for asynchronous AI annotation
and embedding generation. (See `docs/ENGINEERING-REVIEW.md`, item P1-2, for a
note on bounding this.)

---

## 3. Request lifecycle

Every request passes through a single host router that applies a uniform
pipeline before dispatching by hostname:

1. Apply strict security headers (HSTS, CSP, `X-Frame-Options`, etc.).
2. Resolve the client IP (from the Cloudflare-provided header), user agent, and
   method; parse the `Host` header.
3. Evaluate the session cookie to determine authenticated identity.
4. Check the blocklist; serve `403` if the IP is banned.
5. Classify the request (`self` / `unknown` / `bot` / `scanner` / `blocked`).
6. Apply geo-blocking if enabled (never for authenticated or local requests).
7. For scanners, record the hit toward auto-ban; optionally serve honeypot
   content.
8. Apply per-IP rate limiting (skipped for the operator and `/health`).
9. Attempt project-subdomain routing, then legacy static-site routing.
10. Dispatch `/v1/*` programmatic API requests (API-key authenticated).
11. Dispatch by host (see Section 4).
12. After the handler returns, record the visit to the append-only log and
    publish it to the SSE event bus.

---

## 4. Host routing

The router maps each public hostname to a handler. Access policy is enforced at
both the host layer and the route layer (defense in depth).

```
rofihosted.space            -> public landing, signup, health, static assets
status.rofihosted.space     -> public status page + GET /api/status
admin.rofihosted.space      -> operator console   (requires role = admin)
app.rofihosted.space        -> tenant console      (requires authentication)
<sub>.rofihosted.space      -> project router (auth intercept, static, or proxy)
www / dashboard / api / files -> redirects to canonical locations
```

Both consoles are served by one handler, `handleConsole`, parameterized by a
`Surface` value (`admin` or `app`):

- On the **admin** surface, an authenticated non-admin is redirected (302) to
  the tenant host.
- On the **app** surface, an authenticated admin is redirected (302) to the
  operator host for page navigations (API calls are left untouched so
  automation continues to work).
- Sensitive routes (`/admin/*`, `/api/users*`, `/api/invites*`, and the system
  endpoints) additionally enforce `role = admin` regardless of host.

The session cookie is scoped to `.rofihosted.space`, so one login is valid
across all surfaces; login and apex redirects choose the destination host by
role.

### Project subdomains

For `<sub>.rofihosted.space`, the router resolves in this order:

1. `/auth/{signup,login,verify}` — intercepted by the per-project
   authentication service before the project's own code can see credentials.
2. `/v1/github/<project_id>` — HMAC-verified GitHub deploy webhook.
3. If the project is static, serve from its current release directory.
4. If the project is a backend, reverse-proxy to its allocated local port.
5. Otherwise, fall through to legacy static-site hosting.

Reserved subdomains (`app`, `www`, `dashboard`, `status`, `api`, `files`,
`admin`) are never claimable by a project.

---

## 5. Module map

The server is organized into focused modules under `zig/hp-server/src/`.

**Core and routing**
- `main.zig` — HTTP routing, request lifecycle, signal handling, and the bulk
  of the handlers. (Decomposition is tracked in the engineering review.)

**Identity and access**
- `auth.zig` — HMAC session cookies (legacy operator and multi-user v2),
  identity resolution.
- `users.zig` — multi-tenant user store (roles, statuses, password hashing).
- `apikey.zig` — scoped, hashed API keys for the `/v1/*` API.
- `secret.zig` — the per-install random pepper.

**Security**
- `security.zig` — classifier, blocklist, auto-ban, login tracker, headers.
- `ratelimit.zig` — per-IP token bucket.
- `geoblock.zig` — country-based filtering.
- `pathsafe.zig` — path/subdomain validation with `realpath` escape checks.
- `fingerprint.zig`, `signuplimit.zig`, `invites.zig`, `emailverify.zig` —
  the signup anti-abuse pipeline.

**Platform (PaaS)**
- `projects.zig` — project registry.
- `projsecrets.zig` — AES-256-GCM per-project secrets vault.
- `builder.zig` — clone/install/build/publish/rollback orchestration.
- `supervisor.zig` — per-project process supervision and RSS quotas.
- `proxy.zig` — HTTP/1.1 reverse proxy to project ports.
- `projauth.zig` — per-project authentication-as-a-service (HS256 JWT).
- `cron.zig` — scheduled tasks.
- `hosted.zig` — legacy static-site hosting.

**Storage and telemetry**
- `store.zig` — append-only JSONL with size-bounded rotation; uptime history.
- `writebuf.zig` — buffered writer for the visits log.
- `dbcache.zig` — SQLite read-side cache, incrementally synced from JSONL.
- `dbpool.zig` — persistent `sqlite3` worker pool.
- `uptime.zig`, `tunnel_health.zig`, `sysmon.zig`, `hostinfo.zig`,
  `powermon.zig` — monitoring.
- `events.zig` — SSE pub/sub bus with an outbound webhook fan-out hook.
- `rules.zig` — operator rule engine.
- `webhook.zig` — outbound webhook dispatch.

**Communications and AI**
- `email.zig` — transactional email via the Brevo HTTP API.
- `telegram.zig` — optional Telegram notifier.
- `ai.zig`, `embeddings.zig`, `honeypot.zig`, `query.zig` — the AI layer.

**Presentation**
- `templates/` — all HTML, CSS, JavaScript, and fonts, embedded into the
  binary at compile time.

---

## 6. Storage model

The durable record is **append-only JSON Lines** under `~/data/`. SQLite is a
**derived, rebuildable cache**, never the source of truth.

```
~/data/
  visits.jsonl, uptime.jsonl, logins.jsonl, audit.jsonl,
  digests.jsonl, policy.jsonl, anomalies.jsonl, ai-calls.jsonl, scrub.jsonl
  cache.db                  (SQLite read-side cache, rebuildable)
  embeddings.bin            (vector store, custom binary format)
  dbs/<project_id>.db       (per-project SQLite)
  projects/<id>/            (repo, releases, current symlink, secrets, logs)
```

### Why JSONL plus SQLite

Append-only writes are simple, crash-safe, and human-inspectable. But scanning
JSONL for the AI query bar is slow at scale, so a SQLite table (`visits`, with
indexes and an FTS5 virtual table) is maintained as a cache. A background sync
reads new rows from the last-synced byte offset every five minutes and batches
them into a single transaction. Queries use the cache when healthy and fall
back to a JSONL scan otherwise; responses report which source served them.

SQLite is accessed through a pool of persistent `sqlite3` CLI subprocesses
rather than a linked library, because Termux does not ship the CRT files needed
to link `libsqlite3` reliably. A sentinel-based protocol marks query boundaries
on each worker's stdio. This trades a small per-query overhead for a
dependency-free, Termux-correct implementation.

### Configuration and secrets

Configuration and credentials live in mode-600 files outside the repository and
are never committed: the credentials file, blocklist, the random pepper,
geo-block and honeypot toggles, the environment file (third-party API keys),
the operator rule set, API keys, webhooks, the project registry, and the cron
schedule.

---

## 7. Concurrency

Shared state is guarded by mutexes held briefly and released before any I/O
where possible. The append-only logs are written under a store mutex; the
buffered visits writer flushes on an interval. The SSE bus fans out events to
subscribers and, through a registered callback, to the outbound webhook
dispatcher, avoiding an import cycle.

Signal handling uses an async-signal-safe atomic flag; the actual flush and
socket shutdown happen on the main thread's shutdown loop rather than inside
the handler, per POSIX guidance.

---

## 8. Deployment pipeline

```
git push -> GitHub Actions -> POST /v1/system/update (admin API key)
                                      |
                                      v
                          self-update.sh on the device:
              fetch -> reset --hard -> rsync sources -> rebuild -> respawn
```

The device holds a Git clone (`~/rofihosted-src`) separate from the build tree
(`~/zig/hp-server`). `self-update.sh` fetches, resets to the remote head,
rsyncs sources into the build tree (preserving the build cache), rebuilds, and
signals the running server so the watchdog respawns the new binary. Commits
that touch only scripts or documentation skip the restart. The build is
performed on the device today; see the engineering review (P0-2) for the
recommended move to prebuilt artifacts.

---

## 9. Frontend

All presentation assets are embedded into the binary and served from the apex
host with permissive caching and CORS, so every surface can load them
cross-origin. The design system is defined in `theme.css` (tokens, typography,
components) and `app.css` (console shell), using a self-hosted subset of SF Pro
Display delivered as woff2. The visual language is neutral and status-driven:
the only meaningful colour is the operational state (green/amber/red), with a
single green accent that doubles as the "operational" signal.
