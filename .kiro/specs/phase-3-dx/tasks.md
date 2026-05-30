# Tasks — Multi-tenant Phase 3 (Developer Experience)

> Spec docs:
> - `.kiro/specs/phase-3-dx/requirements.md`
> - `.kiro/specs/phase-3-dx/design.md`
>
> Each task notes the requirement(s) it satisfies. Leaf tasks are the ones the orchestrator dispatches to subagents. Parents auto-complete when children finish.
>
> Convention: `[deps: N.M, K]` means task waits for those siblings/cousins.

## 1. Backend foundation

- [x] 1.1 Add `Project.db_mode` field to registry
  - File: `zig/hp-server/src/projects.zig`
  - Add `pub const DbMode = enum { sqlite, postgres };` and `db_mode: DbMode = .sqlite` on `Project`
  - Persist + read through existing `writeProjectJson` / JSONL replay
  - Default missing field to `.sqlite` for legacy projects (no migration)
  - JSON serialize as lowercase string `"sqlite"` / `"postgres"` for dashboard compatibility
  - _Requirements: 2.7, 1.x (auto-deploy needs to set this)_

- [x] 1.2 Refactor analyzer + preview into reusable cores
  - File: `zig/hp-server/src/main.zig`
  - Extract `apiProjectsAnalyze` body into `pub fn analyzeRepoCore(allocator, repo_url) !AnalysisResult`
  - Extract `apiProjectsPreviewRepo` body into `pub fn previewRepoCore(allocator, repo_url) !PreviewResult`
  - Existing endpoints become thin wrappers calling the cores
  - No behavior change for existing endpoints (smoke test must still pass)
  - _Requirements: 1.3 (auto-deploy reuses these)_
  - [deps: 1.1]

- [x] 1.3 Implement `POST /api/projects/auto-deploy` endpoint
  - File: `zig/hp-server/src/main.zig`
  - New handler `apiProjectsAutoDeploy` per design section "Capability 1.1"
  - Tenant quota gate via `Manager.listJsonFiltered + max_projects`
  - URL shape validation (HTTPS only, no inline credentials, length <= 512)
  - `deriveSubdomain` helper (lowercase, sanitize, suffix if too short or reserved)
  - Call `analyzeRepoCore`, fall back to `previewRepoCore` on failure
  - `Manager.create` with retry on `subdomain_taken`
  - `builder.deployAsync` fire-and-forget
  - Audit log `project_autodeploy`
  - Return `{project_id, subdomain, public_url, stream_url}`
  - Wire into `handleApp` API router
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.11, 1.12_
  - [deps: 1.1, 1.2]

- [x] 1.4 Verify `/v1/public/stats` response shape and CORS
  - File: `zig/hp-server/src/main.zig`, function `v1PublicStats`
  - Confirm fields: `projects_running`, `total_users`, `uptime_days`, `version_short`
  - Add any missing fields
  - Confirm `Access-Control-Allow-Origin: *` and `Cache-Control: public, max-age=30`
  - _Requirements: 3.5, 3.6_

- [x] 1.5 Rewire apex `/` to serve `public.html` for unauth, redirect for authed
  - File: `zig/hp-server/src/main.zig`, function `handleRoot`
  - Add helper `currentRoleOrAnon(app, req) -> enum { anon, tenant, admin }`
  - When path == "/" and anon: serve `@embedFile("templates/public.html")` with status 200, content-type text/html
  - When path == "/" and tenant: 302 to `https://app.rofihosted.space/projects`
  - When path == "/" and admin: 302 to `https://app.rofihosted.space/`
  - _Requirements: 3.1, 3.2, 3.3_
  - [deps: 1.4]

## 2. MCP tool surface

- [x] 2.1 Add four tool schemas to `mcpToolsList` and `/.well-known/mcp.json`
  - File: `zig/hp-server/src/main.zig`
  - Schemas for `auto_deploy`, `tail_build_log`, `get_db_url`, `set_db_url` per design tables
  - Add tool names to `PROJECT_TOOLS` whitelist (so tenant scoping enforced)
  - Update `/.well-known/mcp.json` static response to include them
  - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.6_
  - [deps: 1.3]

- [x] 2.2 Implement `mcpToolAutoDeploy`
  - File: `zig/hp-server/src/main.zig`
  - Wrapper around `apiProjectsAutoDeploy` core; stamps `owner_id = caller_owner` (or empty for admin)
  - Returns `{project_id, subdomain, public_url, stream_url}` per spec
  - _Requirements: 4.1, 4.5, 4.7_
  - [deps: 2.1]

- [x] 2.3 Implement `mcpToolTailBuildLog`
  - File: `zig/hp-server/src/main.zig`
  - Read tail of `~/data/projects/<id>/logs/build.log`
  - Calculate offset from file size, return last `max_lines` lines (default 200)
  - Set `complete: true` if tail contains `=== build complete`, `=== published`, or `=== build failed`
  - _Requirements: 4.2, 4.5_
  - [deps: 2.1]

- [x] 2.4 Implement `mcpToolGetDbUrl`
  - File: `zig/hp-server/src/main.zig`
  - Read `Project.db_mode`
  - If `sqlite`: return file URI `file:/data/.../dbs/<id>.db`
  - If `postgres`: read DATABASE_URL secret, mask user/pass section, return
  - _Requirements: 4.3, 4.5_
  - [deps: 1.1, 2.1]

- [x] 2.5 Implement `mcpToolSetDbUrl`
  - File: `zig/hp-server/src/main.zig`
  - Validate URL is `postgres://` or `postgresql://` if non-null/non-empty
  - If null/empty: clear `DATABASE_URL` secret + flip `db_mode = .sqlite`
  - Else: set secret + flip `db_mode = .postgres`
  - Persist via `Manager.update`
  - _Requirements: 4.4, 4.5_
  - [deps: 1.1, 2.1]

## 3. Dashboard wizard rework

- [x] 3.1 Add "Database" wizard step UI (HTML)
  - File: `zig/hp-server/src/templates/app-projects.html`
  - Insert new `.wiz-step` between Runtime and Secrets
  - `.scope-chips` with two options: SQLite (zero config) / Bring your own Postgres
  - Postgres reveals `<input type="password" id="wiz-pg-url">` + help text
  - Both options share callout listing auto-injected env vars
  - _Requirements: 2.1, 2.3, 2.4_

- [x] 3.2 Wire DB step JS (skip for static, validate Postgres URL, sequenced submit)
  - File: `zig/hp-server/src/templates/app-projects.html`
  - `wizGoTo` skip Database step when runtime === 'static'
  - Validate Postgres URL on chip select + submit
  - On wizard finish with postgres mode: POST create → POST secrets/set DATABASE_URL → POST deploy
  - On wizard finish with sqlite mode: POST create with `db_mode=sqlite` → POST deploy
  - _Requirements: 2.2, 2.4, 2.5, 2.6_
  - [deps: 3.1]

- [x] 3.3 Resources tab DB mode banner
  - File: `zig/hp-server/src/templates/app-projects.html`
  - Read `project.db_mode` from project listing
  - Render `.callout` at top of Resources tab with mode-specific copy
  - SQLite: "zero-config SQLite at <path>, set DATABASE_URL secret to switch"
  - Postgres: "Your Postgres URL via secrets vault, auto-injected SQLite shadowed"
  - _Requirements: 2.7, 2.8_
  - [deps: 1.1]

- [x] 3.4 Auto-deploy panel: collapse client orchestration to one fetch + one SSE
  - File: `zig/hp-server/src/templates/app-projects.html`
  - The previous session left an `#wiz-auto` panel with client-side analyze+create+deploy chain
  - Replace those with a single `POST /api/projects/auto-deploy` then SSE follow
  - Wire `Cancel` button to abort fetches and restore the carousel
  - 4-stage indicator (analyze/create/deploy/live) advances on build markers per design
  - 300s timeout fallback marks deploy as failed and surfaces "View build log"
  - _Requirements: 1.1, 1.7, 1.8, 1.9, 1.10_
  - [deps: 1.3]

- [x] 3.5 Disable auto-deploy button for tenants at quota
  - File: `zig/hp-server/src/templates/app-projects.html`
  - Read `/api/me` (current user) and `/api/projects` (count own)
  - When tenant + count >= max_projects: disable button with tooltip
  - Click handler refuses before any network call
  - _Requirements: 1.6_

## 4. Public landing page polish

- [x] 4.1 Update `public.html` content (hero, How it works, feature grid, dual CTA)
  - File: `zig/hp-server/src/templates/public.html`
  - Add 3-step "How it works" section (sign up → paste repo URL → watch it boot)
  - Add "What you get" feature grid (zero-config DB, secrets vault, CDN tunnel, MCP+CLI)
  - Operator identity block
  - Dual CTA pointing to `/signup` + `/login`
  - No emoji, no native checkboxes, no em-dashes, no underlined links
  - Match `.layout / .form-card` theme
  - _Requirements: 3.4, 3.7_
  - [deps: 1.5]

- [x] 4.2 Verify graceful degradation when `/v1/public/stats` fails
  - File: `zig/hp-server/src/templates/public.html`
  - Confirm existing `fetch().catch(() => null)` keeps placeholder `--` rendering
  - Add `try/catch` around any new dynamic stat consumer added in 4.1
  - _Requirements: 3.5_
  - [deps: 4.1]

## 5. CLI commands

- [x] 5.1 Bump CLI version to 0.3.0
  - File: `cli/package.json`
  - Update `version` field
  - Verify `rh --version` prints new version
  - _Requirements: 5.8_

- [x] 5.2 Implement `rh deploy` repo-URL overload
  - File: `cli/rh.mjs`, function `cmdDeploy`
  - Detect repo URL via regex (https git URL or known forge)
  - Route to new `cmdDeployRepo(repoUrl, opts)` when matched
  - Preserve existing `<dir> <sub>` behavior, emit deprecation note for ambiguous cases
  - `cmdDeployRepo`: POST `/api/projects/auto-deploy` + SSE follow + 4-stage TTY indicator
  - Exit codes: 0 on published, 1 on build failed, 2 on 300s timeout
  - _Requirements: 5.1, 5.2_
  - [deps: 1.3]

- [x] 5.3 Implement `rh db url` subcommand
  - File: `cli/rh.mjs`, new function `cmdDb`
  - `rh db url <sub>`: GET project + show masked URL
  - `rh db url <sub> <postgres-url>`: validate + POST secrets/set + flip db_mode
  - `rh db url <sub> --clear`: revert to sqlite, remove secret
  - _Requirements: 5.3, 5.4_
  - [deps: 1.1, 2.4, 2.5]

- [x] 5.4 Extend `rh tail` to accept kind
  - File: `cli/rh.mjs`, function `cmdTail`
  - Accept `rh tail <sub> [build|runtime]`, default runtime
  - Pass `kind` query to SSE log-stream
  - _Requirements: 5.5_

- [x] 5.5 Add `rh whoami --json`
  - File: `cli/rh.mjs`, function `cmdWhoami`
  - When `--json` flag present: print JSON `{user_id, username, role, status}`
  - Else: keep existing human-readable output
  - _Requirements: 5.6_

- [x] 5.6 Update `cli/README.md`
  - File: `cli/README.md`
  - Replace `rh deploy <dir> <sub>` example with `rh deploy https://github.com/...` as primary
  - Keep dir-zip path as secondary "if you don't want git"
  - Add `rh db url` examples (read, set, clear)
  - Add `rh tail <sub> build` example
  - Document `rh whoami --json` output shape
  - Bump version reference if any
  - _Requirements: 5.7_
  - [deps: 5.1, 5.2, 5.3, 5.4, 5.5]

## 6. Integration and verification

- [x] 6.1 Bump cache busters uniformly
  - Files: every `zig/hp-server/src/templates/*.html`
  - Replace `?v=39` (and any straggler `?v=38`) with `?v=40`
  - Use per-file str_replace (bulk PowerShell sometimes silently fails per house notes)
  - _Requirements: 3.8_
  - [deps: 3.1, 3.2, 3.3, 3.4, 3.5, 4.1]

- [x] 6.2 Add smoke test cases to `scripts/test-everything.sh`
  - File: `scripts/test-everything.sh`
  - Test 1: `POST /api/projects/auto-deploy` returns 200 + project_id (use a tiny known-good public repo)
  - Test 2: SSE log-stream emits at least one `data:` event within 30s
  - Test 3: tenant `auto_deploy` MCP call stamps owner_id correctly
  - Test 4: `set_db_url` postgres URL flips db_mode
  - Test 5: `set_db_url` null reverts to sqlite
  - Test 6: apex `GET /` (unauth) returns 200 with `<title>` containing "rofihosted"
  - Update total expected count from 96 to 102
  - _Requirements: NFR (smoke test)_
  - [deps: 1.3, 1.5, 2.2, 2.5]

- [x] 6.3 Build + diagnostics check
  - Run `getDiagnostics` on `zig/hp-server/src/main.zig`, `projects.zig`, `app-projects.html`, `public.html`, `cli/rh.mjs`
  - Fix any reported errors before proceeding
  - _Requirements: NFR (build time)_
  - [deps: all of 1.x, 2.x, 3.x, 4.x, 5.x, 6.1]

- [x] 6.4 Update CHANGELOG.md with Phase 3 entry
  - File: `CHANGELOG.md`
  - Add section under `## [Unreleased]`: "Phase 3 - Developer Experience"
  - List all five capabilities with one-paragraph each summary
  - Note cache buster bump v=39 -> v=40
  - Note CLI version 0.2.x -> 0.3.0
  - _Requirements: NFR (housekeeping)_
  - [deps: 6.3]

- [x] 6.5 Commit + push to main branch
  - Stage only intended files (no scratch `*.ps1`, `*.log`, `rebuild-tenancy.sh`, etc per .gitignore)
  - Commit message: "feat: Phase 3 - Developer Experience (auto-deploy + DB wizard + landing + MCP + CLI)"
  - Push to `origin main`
  - _Requirements: NFR (housekeeping)_
  - [deps: 6.4]

- [x] 6.6 Trigger rebuild on phone + smoke test
  - Trigger via `/v1/system/update` (POST with admin API key) OR `ssh hp 'bash ~/rebuild-tenancy.sh'`
  - Wait ~240s for ReleaseFast build to finish
  - SIGTERM hp-server so watchdog respawns new binary: `ssh hp '( sleep 3; pkill -TERM -f zig-out/bin/hp-server ) >/dev/null 2>&1 & disown'`
  - Wait ~25-30s for fresh hp-server to come up
  - Run smoke test: `ssh hp 'bash ~/test-everything.sh 2>&1 | tail -8'`
  - Expect 102/102 green; any regression aborts and reverts
  - _Requirements: NFR (smoke test green)_
  - [deps: 6.5]

- [x] 6.7 Manual end-to-end live verification
  - Test 1: log in as admin, click Auto-deploy with a public Vite repo URL, verify 4-stage progress, verify site at `<sub>.rofihosted.space` returns 200
  - Test 2: log in as `devtest1` tenant, repeat, verify project appears in their list (not admin's)
  - Test 3: manual wizard with Postgres mode → finish → verify `db_mode=postgres` in registry, secret stored
  - Test 4: from laptop, `rh deploy https://github.com/<known-good-repo>` → verify same outcome as dashboard
  - Test 5: open `https://rofihosted.space/` in incognito → verify landing page (not login)
  - _Requirements: all_
  - [deps: 6.6]

- [-] 6.8 Cleanup scratch files
  - Delete any `*.ps1` (except `cli/*.ps1`), `unblock.sh`, `gen-key.sh`, `diag-*.sh`, `bump-cache.ps1`, `rebuild-tenancy.sh`, `msg.txt` left at workspace root or `scripts/`
  - Verify `git status` shows clean tree on main
  - _Requirements: NFR (housekeeping)_
  - [deps: 6.7]
