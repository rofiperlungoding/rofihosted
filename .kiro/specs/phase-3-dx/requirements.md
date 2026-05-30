# Multi-tenant Phase 3 — Developer Experience

## Introduction

rofihosted has reached the multi-tenant phase: tenants can sign up, get approved, and run their own static sites and backend projects with auto-injected SQLite + auth + secrets, all isolated from each other (Phases 1 through 2.9). What's still missing is **the developer experience that turns rofihosted from "a personal cloud Rofi can extend" into "a personal cloud other developers actually want to use"**:

1. The console can build a project from a repo URL, but it takes 4 wizard steps and the user has to pick the runtime and start command themselves. Most of those answers are obvious from the repo contents. There is no "paste link, click deploy, watch it boot" path yet.
2. Tenants can use SQLite zero-config (Phase 2.9), but the wizard never tells them about that or about the Postgres escape hatch. They learn it from the Resources tab *after* the project exists.
3. The public root (`/`) currently shows the login page for anonymous visitors. There is a `public.html` landing template in the codebase but it is not wired up as the default response for unauthenticated `rofihosted.space` traffic. A first-time visitor doesn't see a clear "what is this and why should I sign up".
4. The MCP server exposes 28 tools, but they are all admin-flavored: tenants get filtered down to project tools, but there is no first-class "deploy from repo" or "tail logs" or "follow build progress" tool that mirrors the new auto-deploy flow.
5. The `rh` CLI exists and works, but it has the same gaps as the dashboard: no `rh deploy <repo-url>` (it only does `rh deploy <dir> <sub>` which zips a directory), no "follow the build live with progress markers", no `rh db url` shortcut.

This phase closes those five gaps as one cohesive Developer Experience release. The acceptance bar is the user's quote:

> *"user paste repo URL → AI scan → langsung jalan tanpa ribet, plus mereka bisa pake DB tanpa setup, plus bisa pake MCP/CLI dari editor mereka sendiri"*

## Glossary

- **Tenant**: a non-admin user (`role=tenant`, `status=active`) authenticated by v2 cookie or by their own API key.
- **Caller**: the authenticated identity behind a request, regardless of role.
- **Active project**: a project owned by the caller whose status is `running`, `building`, or `cloning`.
- **Auto-deploy**: the new one-click flow that takes a repo URL and produces a running project without further user input.
- **DB mode**: one of `sqlite` (auto-injected per-project SQLite, the default) or `postgres` (caller-supplied URL stored in the secrets vault, overrides the auto-injected `DATABASE_URL`).
- **Build markers**: the existing log lines emitted by `builder.zig` that the new live progress UI watches for (`=== build complete`, `=== published`, `=== build failed`).

## Requirements

### Requirement 1: One-click auto-deploy from a repo URL

**User story**: As a developer holding a public Git repository URL, I want to paste it into the rofihosted console and watch my project come online without filling in a wizard, so that getting a side-project on the internet costs me one click instead of one form.

**Acceptance criteria** (EARS):

1.1 The project wizard (step 1, "Source") SHALL display a primary action button labeled "Auto-deploy from repo" alongside the existing "Ask AI for best fit" and "Continue manually" controls.

1.2 WHEN the user clicks "Auto-deploy from repo" with a non-empty repo URL field, THEN the system SHALL validate the URL shape (HTTPS git URL, optional `.git` suffix, no embedded credentials) and reject malformed input with an inline error before any backend call is made.

1.3 WHEN the URL passes shape validation, THEN the system SHALL call `POST /api/projects/analyze` with the repo URL, and IF the AI is disabled or returns a non-2xx response THEN the system SHALL fall back to `POST /api/projects/preview-repo` (deterministic file-tree heuristics) before failing the flow.

1.4 The auto-deploy flow SHALL derive a subdomain candidate from the analyzer output. WHEN the candidate is shorter than 3 characters, contains characters outside `[a-z0-9-]`, starts or ends with `-`, or is in the reserved list (`app`, `www`, `dashboard`, `status`, `api`, `files`), THEN the system SHALL substitute a sanitized fallback and append a 4-character random suffix.

1.5 WHEN `POST /api/projects/create` returns `error=subdomain_taken`, THEN the system SHALL retry once with a freshly randomized 4-character suffix before surfacing the error to the user.

1.6 IF the caller is a tenant whose `max_projects` quota is at the limit, THEN the auto-deploy button SHALL be disabled with a tooltip explaining the limit AND the click handler SHALL refuse before any network call.

1.7 WHEN auto-deploy is in progress, THEN the wizard SHALL replace its 4-step layout with a 4-stage progress panel showing `analyze → create → deploy → live`, an elapsed timer, a scrollable log pre, and a Cancel button. The four stages SHALL each show one of `pending / running / done / failed`.

1.8 The progress panel SHALL stream the build log via the existing SSE endpoint `GET /api/projects/log-stream?id=<project_id>`, append every received line to the log pre, and advance the stage marker WHEN the line matches `=== build complete`, `=== published`, or `=== build failed`.

1.9 IF no terminal build marker is observed within 300 seconds AND the supervisor reports the project is not running, THEN the system SHALL mark the deploy stage as failed AND offer a "View build log" link to the project detail page.

1.10 WHEN the project reaches `state=running` (backend) or `state=published` (static), THEN the progress panel SHALL show three actions: "Open site" (links to the public subdomain URL), "Open project page" (links to the dashboard detail), "Close" (returns to the project list).

1.11 The system SHALL emit one audit log entry per auto-deploy attempt with action `project_autodeploy`, including the repo URL, derived subdomain, AI fallback flag, total elapsed seconds, and final outcome.

1.12 The auto-deploy flow SHALL be reachable via HTTP API as `POST /api/projects/auto-deploy` accepting `{repo_url, branch?}` and returning `{project_id, subdomain, stream_url}`. This endpoint is what the CLI and MCP tool will call.

### Requirement 2: Database wizard with explicit SQLite-vs-Postgres choice

**User story**: As a tenant building a backend project, I want to see "where does my database live" as a first-class wizard question, so that I am not surprised by an injected `DATABASE_URL` and I know my Postgres escape hatch exists before I deploy.

**Acceptance criteria** (EARS):

2.1 The project wizard SHALL include a dedicated "Database" step (between Runtime and Secrets) with two mutually-exclusive `.scope-chips` options: "SQLite (zero config)" and "Bring your own Postgres".

2.2 The "Database" step SHALL be skipped automatically WHEN the runtime is `static`, since static projects have no `DATABASE_URL` consumer.

2.3 WHEN "SQLite" is selected, THEN the step SHALL render a callout listing the three injected variables (`DATABASE_URL=file:<path>`, `ROFI_DB_PATH`, plus a sample better-sqlite3 snippet) and require no further input.

2.4 WHEN "Bring your own Postgres" is selected, THEN the step SHALL render a single password-style input for `DATABASE_URL` with placeholder `postgres://user:pass@host:5432/dbname`, validate that the value starts with `postgres://` or `postgresql://`, and explain that the value is stored encrypted in the project's secrets vault.

2.5 The provided Postgres URL SHALL NOT be sent in the create-project request body. Instead, the wizard SHALL call `POST /api/projects/create` first, then `POST /api/projects/secrets/set` with key `DATABASE_URL` for the new project id, before triggering deploy.

2.6 The auto-deploy flow from Requirement 1 SHALL default to SQLite mode and SHALL NOT prompt for a database choice. Postgres remains an opt-in path through the manual wizard.

2.7 The project detail page's Resources tab SHALL show a banner indicating which DB mode the project was created with (`sqlite` or `postgres`), sourced from a new `Project.db_mode` field persisted in the registry.

2.8 The Resources tab Postgres section SHALL link to managed-Postgres providers (Supabase, Neon, Turso, Upstash) with a one-line description of each free-tier limit, matching the existing copy and adding only minimal new content.

### Requirement 3: Public landing page wired to the apex domain

**User story**: As a first-time visitor reaching `rofihosted.space` from a link, I want to immediately see what the project is, who runs it, and how to sign up, so that I am not greeted by a login form for an account I don't have.

**Acceptance criteria** (EARS):

3.1 WHEN an unauthenticated request arrives at the apex host (`rofihosted.space` and `www.rofihosted.space`) for path `/`, THEN the system SHALL serve `public.html` (the existing template) with a 200 status code instead of the login page.

3.2 WHEN an unauthenticated request arrives at the console host (`app.rofihosted.space`) for path `/`, THEN the system SHALL continue to serve the login page, since `app.*` is the private console.

3.3 WHEN an authenticated request arrives at `/` on either host, THEN the system SHALL redirect to `/projects` (302) for tenants and to the existing dashboard (Overview) for admins.

3.4 The public landing page SHALL contain at least: a hero section with project name and one-sentence pitch, a "How it works" section with 3 steps (sign up, paste repo URL, watch it boot), a "What you get" feature grid (zero-config DB, secrets vault, CDN through CF Tunnel, MCP + CLI), an "Operator" identity block, and a primary CTA pointing at `/signup` plus a secondary CTA pointing at `/login`.

3.5 The page SHALL NOT depend on any authenticated API. WHEN `fetch /v1/public/stats` returns 4xx or fails, THEN every dynamic statistic SHALL fall back to the placeholder `--` without breaking layout.

3.6 The system SHALL expose a new endpoint `GET /v1/public/stats` returning `{projects_running, total_users, uptime_days, version_short}` aggregated from the existing in-memory state, with no auth required, cached for 30 seconds in-process to bound load.

3.7 The page SHALL NOT contain emoji, native checkboxes, em-dashes, or underlined links, and SHALL match the existing `.layout / .form-card` theme primitives.

3.8 Cache busters across all updated templates and static assets SHALL bump uniformly from `?v=39` to `?v=40` for this phase.

### Requirement 4: Developer-facing MCP tool surface

**User story**: As a developer using Claude Desktop, Kiro, or Cursor, I want MCP tools that match the new auto-deploy and DB workflows, so that I can tell my AI assistant "ship this repo to my rofihosted account" and it can do the whole thing without me opening a browser.

**Acceptance criteria** (EARS):

4.1 The MCP server SHALL register a new tool `auto_deploy` that accepts `{repo_url, branch?, subdomain_hint?}`, calls the same `POST /api/projects/auto-deploy` endpoint, and returns `{project_id, subdomain, public_url, stream_url}`.

4.2 The MCP server SHALL register a new tool `tail_build_log` that accepts `{project_id, max_lines?}` (default 200), reads up to `max_lines` from the build log, and returns the lines plus a `complete: bool` flag derived from the presence of a terminal marker in the tail.

4.3 The MCP server SHALL register a new tool `get_db_url` that accepts `{project_id}` and returns the project's effective `DATABASE_URL` value: WHEN `db_mode=sqlite` THEN the auto-injected file URI, WHEN `db_mode=postgres` THEN the masked form (`postgres://***:***@host:port/dbname`) of the secret, never the raw secret.

4.4 The MCP server SHALL register a new tool `set_db_url` that accepts `{project_id, url}`, validates the URL is `postgres://` or `postgresql://`, sets the secret, flips `Project.db_mode` to `postgres`, and returns `{ok: true}`. WHEN the URL is empty or `null`, THEN the tool SHALL clear the secret and revert `db_mode` to `sqlite`.

4.5 All four new tools SHALL respect the existing tenant scoping: `auto_deploy` SHALL stamp the new project with the caller's `owner_id`, and `tail_build_log` / `get_db_url` / `set_db_url` SHALL refuse with `forbidden: not your project` when `caller_owner != project.owner_id`, matching the pattern of the existing `start_project` / `stop_project` tools.

4.6 The MCP discovery document at `/.well-known/mcp.json` and the inline `tools/list` response SHALL include the four new tools with full JSON schema for inputs and outputs, so MCP clients see them in their tool picker without a server restart on the client side.

4.7 IF the caller is admin, THEN `auto_deploy` MAY be invoked without an `owner_id` argument and SHALL leave the project unowned (legacy admin-only state), preserving the existing admin escape hatch.

### Requirement 5: CLI commands for the new workflows

**User story**: As a developer who lives in the terminal, I want `rh deploy <repo-url>` and `rh db url` and `rh tail --build` to do the same thing the dashboard auto-deploy and Resources tab do, so that I never have to open the browser for routine deploys.

**Acceptance criteria** (EARS):

5.1 The CLI SHALL support a new invocation form `rh deploy <repo-url> [--branch=main] [--sub=<name>]` that distinguishes a repo URL (`http(s)://...git` or `git@...`) from a directory path. WHEN the first argument is a directory, THEN the existing zip-and-upload behavior SHALL be preserved with the deprecation note "for repo URLs, omit the `<sub>` argument".

5.2 WHEN `rh deploy <repo-url>` is invoked, THEN the CLI SHALL POST to `/api/projects/auto-deploy`, then open the SSE stream `/api/projects/log-stream?id=<id>`, render a 4-stage progress indicator on stderr (with the same `analyze → create → deploy → live` labels as the dashboard), pipe the log lines to stdout, and exit `0` on `=== published` / state=running, `1` on `=== build failed`, or `2` on the 300-second timeout.

5.3 The CLI SHALL support `rh db url <sub>` printing the masked DB URL (the same value `get_db_url` returns), and `rh db url <sub> <postgres-url>` setting the URL via the secrets vault and flipping `db_mode`.

5.4 The CLI SHALL support `rh db url <sub> --clear` reverting the project to `db_mode=sqlite` and removing the `DATABASE_URL` secret.

5.5 The existing `rh tail <sub>` SHALL accept a new optional first argument `build` (currently it only supports the implicit `runtime`) so users can stream the build log of an in-flight deploy without opening the dashboard.

5.6 The CLI SHALL support `rh signup` already (Phase 2.3); this phase adds `rh whoami --json` returning the caller's identity (user_id, username, role, status) as JSON for scripting.

5.7 The `cli/README.md` SHALL be updated with examples for each new command, replacing the existing `rh deploy <dir> <sub>` example with the new repo-URL-based one as the primary path and keeping the directory-zip path as a secondary "if you don't want git" example.

5.8 The CLI version in `cli/package.json` SHALL be bumped to `0.3.0` for this DX phase, and the `rh --version` output SHALL match.

## Out of scope

The following are explicitly NOT in this phase and SHALL be deferred to a future spec:

- Hosted Postgres on the phone itself (the phone has 6 GB RAM; a real Postgres process plus tenant traffic OOMs).
- Buildpacks / Dockerfile / multi-language autodetect beyond what `analyzeProject` already does.
- A "deploy preview" environment per pull request (the platform doesn't model branches yet).
- Billing, usage metering, or paid tiers.
- A self-serve domain bring-your-own (`*.rofihosted.space` is the only public surface for now).

## Non-functional requirements

- **Backward compatibility**: existing projects (created pre-Phase-3) SHALL continue to work without migration. `Project.db_mode` defaults to `sqlite` for any project missing the field.
- **Build time**: the binary SHALL still build in under 5 minutes ReleaseFast on the phone (Snapdragon 720G, 6 GB RAM); no new dependencies are added.
- **Memory**: total RSS SHALL stay under the watchdog's 384 MB ceiling; the new `/v1/public/stats` cache adds at most 1 KB of state.
- **Smoke tests**: `~/test-everything.sh` SHALL go from 96/96 to N/N where N includes new coverage for auto-deploy, DB mode persistence, public landing page, MCP new tools, and CLI new commands. No green-to-red regression is acceptable.
