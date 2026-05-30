# Design — Multi-tenant Phase 3 (Developer Experience)

## Overview

This design realizes the five capabilities from `requirements.md` against the existing rofihosted codebase. Nothing in this phase introduces new languages, runtimes, or external services. Every change lands inside three trees:

- `zig/hp-server/src/` — Zig server: 1 new endpoint, 4 new MCP tools, 1 new `Project` field, 1 router rewire.
- `zig/hp-server/src/templates/` — UI: wizard rework, public landing wiring, cache-buster bump.
- `cli/` — Node CLI: 3 new commands, 1 command form-overload, version bump.

The design is structured per requirement so it stays easy to verify against the acceptance criteria. Every section names the specific file path and function or symbol that owns the change.

## Architecture in one diagram

```
                  rofihosted.space (apex)                   app.rofihosted.space (console)
                          |                                            |
                          v                                            v
                    handleRoot (NEW)                              handleApp (existing)
                    serves public.html                            cookie-gated dashboard
                          |                                            |
   ----------------------------------------------------    -----------------------------
   |                                                  |    |                           |
   /signup       /login                 /v1/public/stats   /api/projects/auto-deploy   /mcp
   (existing)    (existing)             (existing, expanded) (NEW)                     (existing, +4 tools)
                                                                |
                                                                v
                                              builder.deployAsync (existing)
                                              supervisor.start    (existing)
                                              SSE log-stream      (existing, format unchanged)

   ---- CLI (cli/rh.mjs) -----------------------------
   rh deploy <repo-url>  -> POST /api/projects/auto-deploy + SSE follow
   rh db url <sub>       -> GET  /api/projects/secrets/list + projects/list (mask)
   rh db url <sub> <url> -> POST /api/projects/secrets/set + db_mode update
   rh tail <sub> build   -> SSE log-stream kind=build
```

## Component-by-component design

### Capability 1: One-click auto-deploy

#### 1.1 New backend endpoint `POST /api/projects/auto-deploy`

**Location**: `zig/hp-server/src/main.zig`, registered in `handleApp`'s API router next to `apiProjectsCreate`.

**Signature**: `fn apiProjectsAutoDeploy(app: *App, req: *httpz.Request, res: *httpz.Response) !void`

**Behavior**:

1. `requireUser` → identity. Tenant quota gate: if `ident.role == .tenant`, count caller's existing projects via `Manager.listJsonFiltered(owner_id)`; if `>= user.max_projects` return `429 quota_exceeded`.
2. Parse body as `URLSearchParams` (per house style — httpz multipart unreliable). Required: `repo_url`. Optional: `branch`, `subdomain_hint`.
3. Validate `repo_url`: must start with `https://` (reject `http://`, `git@`, `ssh://`, file://). Reject embedded `@` before host (no inline credentials). Reject if length > 512.
4. Derive subdomain (helper `deriveSubdomain` in `main.zig`):
   - If `subdomain_hint` provided AND validates (`pathsafe.isValidSubdomain`): use it.
   - Else: take repo URL path tail, strip `.git`, lowercase, replace non-`[a-z0-9-]` with `-`, collapse repeated dashes, trim leading/trailing dashes.
   - If result < 3 chars OR in reserved list (`app/www/dashboard/status/api/files`): append `-` + 4 random hex chars.
5. Call `apiProjectsAnalyze` core logic (refactor it into a callable helper `analyzeRepo(allocator, repo_url) !AnalysisResult` so this endpoint and the existing `/api/projects/analyze` share code). On AI disabled or non-2xx: fall back to `previewRepoCore(allocator, repo_url) !PreviewResult` (similar refactor of `apiProjectsPreviewRepo`).
6. Build a `CreateProjectInput` struct from the analysis: `{name=subdomain, subdomain, repo_url, branch=branch||detected||"main", runtime, install_cmd, build_cmd, start_cmd, publish_dir, owner_id=ident.user_id, db_mode=.sqlite}`.
7. Try create. On `subdomain_taken` (return type from `Manager.create`): re-derive with fresh 4-hex suffix, retry once. On second failure return `409 subdomain_taken`.
8. Call `builder.deployAsync(project_id)` (existing, fire-and-forget).
9. Emit audit log: `audit.append(.{ .action = "project_autodeploy", .target = project_id, .actor = ident.username, .detail = repo_url, .ok = true })`.
10. Return JSON: `{ ok: true, project_id, subdomain, public_url, stream_url: "/api/projects/log-stream?id=<pid>&kind=build" }`.

**Why a new endpoint instead of reusing `/api/projects/create`**: create is sync over the wire and doesn't run analysis. Auto-deploy is "analyze + create + deploy" as one atomic user intent. Splitting it lets the dashboard, CLI, and MCP tool share one server-side flow with consistent audit semantics, instead of three different orchestrations.

#### 1.2 New `Project.db_mode` field

**Location**: `zig/hp-server/src/projects.zig`.

**Change**: Add `db_mode: DbMode = .sqlite` to the `Project` struct, where `DbMode = enum { sqlite, postgres }`. Persist through the existing `writeProjectJson` path. On read (`readProjectJson` / JSONL replay), default missing field to `.sqlite` so legacy projects don't need migration. JSON serialization uses lowercase string `"sqlite"` / `"postgres"` for compatibility with the dashboard.

**Why**: lets the Resources tab show the active mode, lets MCP `get_db_url` know whether to read the secret or compute the auto-injected file URI, and gives the audit trail visibility.

#### 1.3 Wizard step rework

**Location**: `zig/hp-server/src/templates/app-projects.html` (already partially edited per Task 16 context).

**Change**: Keep the existing 4-step wizard in place. Add a fifth code path: when "Auto-deploy from repo" is clicked in step 1, hide the step-1-2-3-4 carousel and show the existing `#wiz-auto` panel that was added in the previous session. Wire its `Cancel` button to abort fetches and restore the carousel.

**Verify** the JS handler from the previous session matches the new endpoint. The previous session implemented client-side parallel calls (analyze → create → deploy → SSE). Replace those three sequential fetches with a single `POST /api/projects/auto-deploy` and one SSE follow, since the backend now does the orchestration. This collapses ~200 lines of client JS into ~80.

**SSE consumption**: re-use the existing `EventSource` integration (already in the patch). The endpoint format is `data: <line>\n\n` per log line plus `:heartbeat`, terminated by `event: end\ndata: done\n\n`. Build markers to advance the stage:
- `=== build complete` → stage 3 (deploy) → done.
- `=== published` → stage 4 (live) → done.
- `=== build failed` → stage 3 → failed; show "View build log".
- 300 s timeout w/o markers → stage 4 → failed.

#### 1.4 Subdomain validator alignment

**Location**: `zig/hp-server/src/pathsafe.zig`, function `isValidSubdomain`.

**Verify** the existing rule is `len in [1,63] AND chars in [a-z0-9-] AND no leading/trailing -`. Auto-deploy's `deriveSubdomain` MUST produce strings that pass this check, hence the `>= 3` AND suffix step in flow step 4 above. No code change to `pathsafe.zig`; just discipline in the deriver.

### Capability 2: DB wizard step

#### 2.1 New "Database" step in the wizard

**Location**: `zig/hp-server/src/templates/app-projects.html`.

**HTML**: insert a new `.wiz-step` between "Runtime" and "Secrets". Two `.scope-chips` (radio-style, single-select via existing `.chip-group` JS) — `sqlite` and `postgres`. Postgres chip reveals a `<input type="password" id="wiz-pg-url">` plus help text. Both options share a callout summarizing the env vars rofihosted will inject either way.

**Skip rule**: when runtime is `static`, the manual-step navigator skips the Database step. Implementation: `wizGoTo(stepIndex)` adds an `if (currentStep === 2 && wizState.runtime === 'static') skip database` guard.

**Submit**: on wizard finish:
1. `POST /api/projects/create` with `db_mode` set to the selected chip. Receives new `project_id`.
2. If `postgres`: `POST /api/projects/secrets/set` with `key=DATABASE_URL`, `value=<input>`. The supervisor's existing "secrets vault DATABASE_URL overrides auto-injected" logic handles the rest at next start.
3. `POST /api/projects/deploy` (existing manual deploy trigger).

**Validation**: in the JS, before submit, if `db_mode === 'postgres'` AND value not matching `^postgres(ql)?:\/\//` → inline error, prevent submit.

#### 2.2 Resources tab DB mode banner

**Location**: `zig/hp-server/src/templates/app-projects.html`, the Resources tab inside the project detail modal.

**Change**: read `project.db_mode` from the existing `/api/projects` listing. Render a `.callout` at the top:

- `db_mode === 'sqlite'`: "This project uses zero-config SQLite at `<path>`. To switch to Postgres, set the `DATABASE_URL` secret."
- `db_mode === 'postgres'`: "This project uses your Postgres URL via the secrets vault. Auto-injected SQLite is shadowed."

#### 2.3 Auto-deploy default

Per requirement 2.6, the auto-deploy flow does NOT prompt for DB. The auto-deploy endpoint (`apiProjectsAutoDeploy`) hard-codes `db_mode=.sqlite`. Users who want Postgres go through the manual wizard.

### Capability 3: Public landing wiring

#### 3.1 Default response for apex `/`

**Location**: `zig/hp-server/src/main.zig`, function `handleRoot` (already exists, currently serves a basic index page).

**Change**: when `path == "/"` AND request is unauthenticated, serve `public.html` (already embedded in the binary via `@embedFile`). When authenticated, redirect:
- Tenant → `https://app.rofihosted.space/projects` (302).
- Admin → `https://app.rofihosted.space/` (302) which will then render the existing Overview.

**Auth check**: reuse `auth.isAuthenticated(req)` (returns the legacy operator's session) AND check for v2 cookie via `users.identityFromRequest(req)`. The composite check matches what `requireUser` does elsewhere. New helper `currentRoleOrAnon(req) -> enum { anon, tenant, admin }` to keep the logic readable.

#### 3.2 Public stats endpoint already exists

`v1PublicStats` is already wired and returns aggregated counters. Per acceptance criterion 3.5, the landing page must tolerate failure of this endpoint. The existing `public.html` already does: it calls `fetch('/v1/public/stats')` with a `.catch(() => null)` fallback. No backend change needed.

**Verify** the response shape includes `projects_running`, `total_users`, `uptime_days`, `version_short` — if any are missing, add to the Zig handler. The CHANGELOG mentions the endpoint exists; the design adds whatever fields are gaps.

#### 3.3 Landing content updates

**Location**: `zig/hp-server/src/templates/public.html`.

**Change**: update copy to reflect Phase 3 features. Add a "How it works" section with 3 steps. Add a "What you get" feature grid. Add a CTA pair (Sign up / Login). Bump cache buster. No new template; just edits to the existing file.

#### 3.4 Cache busters

**Mechanism**: every `<link rel="stylesheet">` and `<script src=>` in templates uses `?v=N`. Currently mixed `v=38` and `v=39`. Phase 3 bumps everything to `v=40` uniformly.

**Implementation**: a single `str_replace` per template file (per house rule that bulk PowerShell tools sometimes silently fail).

### Capability 4: MCP developer tools

#### 4.1 Tool registry expansion

**Location**: `zig/hp-server/src/main.zig`, function `mcpToolsList` and dispatcher in `handleMcpToolCall`.

**New tools** (added to the existing `PROJECT_TOOLS` whitelist so they're tenant-accessible after owner check):

| Tool | Inputs | Outputs |
|------|--------|---------|
| `auto_deploy` | `{repo_url: string, branch?: string, subdomain_hint?: string}` | `{project_id, subdomain, public_url, stream_url}` |
| `tail_build_log` | `{project_id: string, max_lines?: number=200}` | `{lines: string[], complete: boolean}` |
| `get_db_url` | `{project_id: string}` | `{db_mode: "sqlite" \| "postgres", url: string}` (postgres masked) |
| `set_db_url` | `{project_id: string, url: string \| null}` | `{ok: true, db_mode: "sqlite" \| "postgres"}` |

**Dispatcher additions** in `handleMcpToolCall` after the existing `if std.mem.eql(u8, tool_name, "deploy_project") return ...` block:

```zig
if (std.mem.eql(u8, tool_name, "auto_deploy")) return mcpToolAutoDeploy(app, res, id_json, args, caller_owner);
if (std.mem.eql(u8, tool_name, "tail_build_log")) return mcpToolTailBuildLog(app, res, id_json, args);
if (std.mem.eql(u8, tool_name, "get_db_url")) return mcpToolGetDbUrl(app, res, id_json, args);
if (std.mem.eql(u8, tool_name, "set_db_url")) return mcpToolSetDbUrl(app, res, id_json, args);
```

**Tenant scoping** (acceptance 4.5): all four tools are appended to `PROJECT_TOOLS` so the existing owner-check guard in `handleMcpToolCall` (lines ~4132-4160) refuses non-owners. `auto_deploy` is special: there is no project yet, so the guard is skipped; instead, ownership is stamped *during* dispatch using `caller_owner`. Admin callers passing `owner_id=""` argument leave the project unowned (legacy admin state).

**`tail_build_log` implementation**: read the last N bytes of `~/data/projects/<id>/logs/build.log` (calculate offset from file size), split on newlines, take the last `max_lines`, return them. `complete` flag = true if the tail contains `=== build complete`, `=== published`, or `=== build failed`.

**`get_db_url` implementation**:
- Fetch project via `app.projects.get(project_id)` (verify owner already done by guard).
- If `project.db_mode == .sqlite`: return `{db_mode: "sqlite", url: "file:/data/.../dbs/<id>.db"}`.
- If `project.db_mode == .postgres`: read `DATABASE_URL` from vault, mask user/pass section (`postgres://***:***@host:port/dbname`), return.

**`set_db_url` implementation**:
- Validate `url` starts with `postgres://` or `postgresql://`. If null/empty: clear secret + flip `db_mode = .sqlite`.
- Else: set secret + flip `db_mode = .postgres`.
- Persist project via existing `Manager.update`.

#### 4.2 Discovery doc

**Location**: `zig/hp-server/src/main.zig`, function `mcpToolsList` (returns the array).

Add full JSON Schema entries for each new tool. Also update the static `/.well-known/mcp.json` response.

### Capability 5: CLI commands

#### 5.1 `rh deploy` overload

**Location**: `cli/rh.mjs`, function `cmdDeploy`.

**Existing**: `rh deploy <dir> <sub>` — zips the directory and uploads as static project.

**New disambiguation**: detect repo URL by regex (`/^(https?:\/\/.*\.git$|https?:\/\/(github|gitlab|bitbucket)\.com\/.+)/i`). If first arg matches: route to `cmdDeployRepo(repoUrl, opts)`. Else preserve existing behavior, but if user provides a URL-like string with `.git` suffix and a second arg, emit a deprecation note "for repo URLs, omit the `<sub>` argument".

**`cmdDeployRepo` flow**:
1. POST `/api/projects/auto-deploy` with `repo_url` and optional `branch`, `subdomain_hint`.
2. Receive `{project_id, subdomain, stream_url}`.
3. Open SSE via `EventSource` polyfill (`eventsource` package — but per house rule, prefer zero-deps; use raw `fetch` with `Response.body` async iter and a tiny line-buffer parser, see existing `cmdTail` if it does this).
4. Render 4-stage indicator on stderr using carriage-return rewrites: `[ANALYZE ✓] [CREATE ✓] [DEPLOY  ⏵] [LIVE   ·]`. On terminals without TTY (CI), print one line per stage.
5. Stream every received line to stdout (so users can pipe to `tee`).
6. Exit codes per acceptance 5.2.

#### 5.2 `rh db` subcommand

**Location**: `cli/rh.mjs`, new function `cmdDb`.

**Subcommands**:
- `rh db url <sub>` — read mode + URL from `/api/projects` (find by subdomain) + `/v1/mcp`-equivalent JSON for masked URL. Print one line.
- `rh db url <sub> <postgres-url>` — POST `/api/projects/secrets/set` with the URL + flip `db_mode`. Print confirmation.
- `rh db url <sub> --clear` — DELETE secret + flip `db_mode=sqlite`. Print confirmation.

#### 5.3 `rh tail` accepts kind

**Location**: `cli/rh.mjs`, function `cmdTail`.

**Existing**: `rh tail <sub>` follows runtime log.

**New**: `rh tail <sub> build` and `rh tail <sub> runtime` (latter explicit). Routes to SSE `/api/projects/log-stream?id=<id>&kind=<kind>`.

#### 5.4 Version bump

`cli/package.json`: `0.2.x` → `0.3.0`. `rh --version` reads from package.json.

#### 5.5 README

`cli/README.md` updates: replace existing `rh deploy <dir> <sub>` example with `rh deploy https://github.com/user/repo` as primary path. Add `rh db url` and `rh tail <sub> build` examples. Bump install instructions if `npm install -g .` requires bin name change (it doesn't; still `rh`).

## Sequence diagrams

### Auto-deploy from dashboard

```
User             Browser/JS         hp-server                builder/supervisor
 |  click Auto-deploy with URL                                    |
 |---------------->|                                              |
 |                 | POST /api/projects/auto-deploy {repo_url}     |
 |                 |--------------->|                              |
 |                 |                | analyzeRepo (AI or fallback) |
 |                 |                | deriveSubdomain              |
 |                 |                | Manager.create               |
 |                 |                | builder.deployAsync ---------|--> clone, install, build
 |                 |  201 {project_id, stream_url}                 |
 |                 |<---------------|                              |
 |                 | GET /api/projects/log-stream?id=&kind=build   |
 |                 |--------------->|                              |
 |                 |                | startEventStreamSync          |
 |                 |  data: ===     | poll log file                |
 |                 |  data: ...     |                              |
 |                 |  ...           |                              |
 |                 |  data: === published                          |
 |                 |  event: end                                   |
 |   live link     |<---------------|                              |
 |<----------------|                                                |
```

### Auto-deploy from MCP

```
AI assistant       MCP client         hp-server                builder/supervisor
 |   tools/call auto_deploy {repo_url}                           |
 |------------------>|                                            |
 |                   | POST /mcp { ... }                          |
 |                   |--------------->|                            |
 |                   |                | handleMcpToolCall          |
 |                   |                | mcpToolAutoDeploy          |
 |                   |                |   -> apiProjectsAutoDeploy core |
 |                   |                | builder.deployAsync -------|--> ...
 |                   |  result {project_id, stream_url}           |
 |                   |<---------------|                            |
 |   {project_id, ...}                                            |
 |<------------------|                                            |
 |   tools/call tail_build_log {project_id} (poll loop)           |
 |------------------>|--------------->|                            |
 |                   |                | read logs/build.log tail   |
 |                   |  result {lines, complete}                  |
 |                   |<---------------|                            |
```

## Data model changes

| File | Field added | Type | Default | Migration |
|------|-------------|------|---------|-----------|
| `~/.hp-server-projects.jsonl` | `db_mode` | string `"sqlite"` \| `"postgres"` | `"sqlite"` | None: legacy projects read with default value |

No new files. No schema migrations. No new vault entries beyond what users already create.

## Endpoint inventory

| Method | Path | New / changed | Auth |
|--------|------|---------------|------|
| POST | `/api/projects/auto-deploy` | NEW | cookie or admin/tenant API key |
| GET | `/v1/public/stats` | EXPANDED (verify response shape) | none |
| POST | `/mcp` (tool: `auto_deploy`) | NEW tool | bearer (admin or tenant API key) |
| POST | `/mcp` (tool: `tail_build_log`) | NEW tool | bearer |
| POST | `/mcp` (tool: `get_db_url`) | NEW tool | bearer |
| POST | `/mcp` (tool: `set_db_url`) | NEW tool | bearer |
| GET | `/.well-known/mcp.json` | UPDATED schema | none |
| GET | `/` (apex, unauth) | CHANGED to serve public.html | none |
| GET | `/` (apex, authed) | CHANGED to redirect | cookie |

## Error semantics

All new endpoints return JSON `{ ok: false, err: "<code>" }` with appropriate HTTP status:

| Code | Status | Trigger |
|------|--------|---------|
| `quota_exceeded` | 429 | Tenant at `max_projects` |
| `bad_repo_url` | 400 | URL fails shape check |
| `subdomain_taken` | 409 | Both create attempts collide |
| `analyze_failed` | 502 | AI returns 5xx AND fallback also fails |
| `forbidden` | 403 | MCP non-owner |
| `not_found` | 404 | MCP project_id does not exist |
| `bad_db_url` | 400 | `set_db_url` URL not postgres-shaped |

## Testing strategy

### Smoke test additions (`scripts/test-everything.sh`)

Adds these new checks (target: 102/102 from current 96/96):

1. `POST /api/projects/auto-deploy` with valid public repo URL → expect 200 + `project_id`.
2. SSE consume `/api/projects/log-stream?id=<id>&kind=build` for 30s → expect at least one `data:` event.
3. Tenant `auto_deploy` MCP tool stamps `owner_id` correctly (verify via subsequent `list_projects`).
4. `set_db_url` with valid postgres URL flips `db_mode`; subsequent `get_db_url` returns masked.
5. `set_db_url` with `null` clears secret and flips back to sqlite.
6. Apex `GET /` (unauth) returns 200 + content-type text/html with `<title>` containing "rofihosted".

### Manual end-to-end (post-rebuild)

1. Log in as admin → click Auto-deploy with a public Vite repo → watch 4-stage progress → verify site at `<sub>.rofihosted.space` returns 200.
2. Log in as tenant (`devtest1`) → repeat, verify project appears in their list, NOT admin's.
3. Manual wizard with Postgres mode → finish → verify `db_mode=postgres` in registry, secret stored.
4. `rh deploy <github-url>` from laptop → verify same outcome as dashboard.
5. Apex `https://rofihosted.space/` in incognito → verify landing page, not login.

## Risk and rollback

**Risk 1**: AI analyzer may fail or hallucinate. Mitigated by requirement 1.3's deterministic fallback to `previewRepoCore`. If both fail: surface `analyze_failed` to the user, who can retry through the manual wizard.

**Risk 2**: Public landing page goes live but contains broken links / outdated copy. Mitigated by reusing the existing `public.html` and only editing copy. Rollback: revert one HTML file.

**Risk 3**: New MCP tools break existing MCP clients due to schema validation. Mitigated by additive-only changes (new tools in `tools/list`, no removal or rename). Existing clients ignore unknown tools per MCP spec.

**Risk 4**: `Project.db_mode` field on legacy projects defaults to `sqlite` but user's project was actually using a Postgres URL via secrets. Pre-Phase-3 there was no field, so behavior was: secret-set DATABASE_URL overrides auto-injected. That logic still runs on every supervisor.start, regardless of `db_mode`. So `db_mode` is purely cosmetic for legacy projects; their DATABASE_URL secret continues to take effect. No data loss.

**Rollback procedure**: every change is additive except wizard rework (Capability 2.1) and apex `/` rewire (Capability 3.1). Both have one-commit reverts:
- Wizard rework: revert `app-projects.html`.
- Apex rewire: revert `handleRoot` change in `main.zig`.

## Out-of-scope reaffirmed (from requirements)

Postgres on phone, buildpacks, PR previews, billing, BYO domain. The design above does not include code paths for any of these.

## Open questions

None at this time. All five capabilities have concrete touchpoints and behaviors specified.
