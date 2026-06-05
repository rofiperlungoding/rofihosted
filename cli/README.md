# rofihosted CLI

Deploy and manage apps on your phone-powered server, straight from the terminal. No SSH required.

The package installs **two** commands that do the same thing:

- `rofihosted` - the full brand name (great for scripts, docs, and discoverability)
- `rh` - a short alias for everyday typing

Use whichever you like; this README uses the short `rh` form for brevity.

## Install

```sh
cd cli
npm install -g .
# or, once published:
npm install -g rofihosted

# for development (symlink both names):
chmod +x rh.mjs
ln -s "$PWD/rh.mjs" /usr/local/bin/rofihosted
ln -s "$PWD/rh.mjs" /usr/local/bin/rh
```

Requires Node 18+.

## Setup

1. Open `https://app.rofihosted.space/settings`
2. Scroll to "API keys", click "Create key"
3. Tick the `admin` scope, give it a name
4. Copy the key (shown once)
5. Run `rh login` and paste it

The key is stored in `~/.rofihosted/config.json` (mode 0600).

You can also use environment variables instead:

```sh
export ROFIHOSTED_API_KEY=rh_xxxxxxxxxxxxxxxxxxx
export ROFIHOSTED_BASE=https://app.rofihosted.space  # optional, default
```

## Commands

### Account & system

| Command | Description |
| --- | --- |
| `rh login` | Save API key (interactive) |
| `rh whoami` | Show current API key identity |
| `rh status` | hp-server vitals (battery, mem, disk, version, uptime) |
| `rh power` | Charger and battery status |
| `rh update` | Pull latest commit from GitHub and rebuild |
| `rh backup [--r2]` | Trigger a local backup; with `--r2` also pushes to Cloudflare R2 |
| `rh exec "<cmd>"` | Run an arbitrary shell command on the phone (admin scope) |

### Projects

| Command | Description |
| --- | --- |
| `rh ls` | List all projects with status |
| `rh deploy <repo-url> [--branch=main] [--sub=name]` | One-click deploy from a public Git repo. AI scans, creates project, streams build log live. |
| `rh deploy <dir> <sub>` | (legacy) Zip a directory and upload as a static project |
| `rh redeploy <sub>` | Re-clone the project's repo and rebuild |
| `rh start <sub>` | Start a stopped project |
| `rh stop <sub>` | Stop a running project |
| `rh restart <sub>` | Stop then start with grace |
| `rh logs <sub>` | Show build + runtime logs once |
| `rh tail <sub> [runtime\|build]` | Follow the runtime/build log live (Ctrl-C to stop) |

### Secrets & database

| Command | Description |
| --- | --- |
| `rh secret list <sub>` | List secret keys for a project (values are write-only) |
| `rh secret set <sub> <key> [value]` | Set a secret (prompts if value omitted) |
| `rh secret rm <sub> <key>` | Remove a secret |
| `rh sql <sub> "<query>"` | Run SQL against the project's per-project SQLite database |
| `rh db url <sub>` | Show effective `DATABASE_URL` (file:// for sqlite mode, masked for postgres) |
| `rh db url <sub> <postgres-url>` | Set `DATABASE_URL` secret + flip `db_mode=postgres`. Restart for env to apply. |
| `rh db url <sub> --clear` | Remove `DATABASE_URL` secret + revert `db_mode=sqlite` |

### Security

| Command | Description |
| --- | --- |
| `rh ban <ip> [reason]` | Manually block an IP |
| `rh unban <ip>` | Remove an IP from the blocklist |

### MCP integration

| Command | Description |
| --- | --- |
| `rh mcp` | Print MCP config snippets for Claude Desktop, Kiro, Cursor, etc |

## Examples

### Quick health check

```sh
$ rh status
hp-server status
  version    c7cf47c (up to date)
  binary     built 5/29/2026, 12:37:21 PM
  battery    90% full
  memory     2641 / 7574 MB
  disk       80.1 / 93.4 GB free
  uptime     2d 6h
```

### Deploy a public Git repo

```sh
$ rh deploy https://github.com/you/my-vite-app
[ANALYZE -] [CREATE -] [DEPLOY -] [LIVE -]
project_id=a1b2c3d4e5f60718 subdomain=my-vite-app ai_used=true runtime=static
[clone] git clone --depth=1 https://github.com/you/my-vite-app
[install] npm ci
...
=== published
OK deployed: https://my-vite-app.rofihosted.space
```

Server handles AI analysis, subdomain derivation, project creation, and the
build pipeline. The CLI just streams the build log and exits 0 / 1 / 2 on
success / failure / 5-minute timeout.

### Set or rotate a Postgres URL

```sh
# Read current setting
$ rh db url my-app
db_mode: sqlite
url:     file:/data/data/com.termux/files/home/data/dbs/a1b2c3d4e5f60718.db

# Switch to a hosted Postgres
$ rh db url my-app 'postgres://user:pass@db.supabase.co:5432/postgres'
OK my-app: DATABASE_URL stored in vault, db_mode=postgres. Restart for env to apply.
$ rh restart my-app

# Revert to zero-config SQLite
$ rh db url my-app --clear
OK my-app: db_mode reverted to sqlite. Restart for env to apply.
```

### Deploy a static dist directory (legacy zip path)

```sh
$ npm run build
$ rh deploy ./dist my-app
Detected: Vite (build to dist/) (runtime=static)
Creating new static project 'my-app'...
OK created project a1b2c3d4e5f60718
Zipping ./dist...
Uploading 142.3 KB to /v1/projects/upload?id=a1b2c3d4e5f60718...
OK deployed: https://my-app.rofihosted.space
```

Use this path when you don't want to push to a Git remote. For most cases,
prefer the repo-URL form above.

### Set a secret and restart

```sh
$ rh secret set my-app DATABASE_URL postgres://...
OK set DATABASE_URL on my-app (restart project for env to apply)

$ rh restart my-app
OK restart my-app
```

### Tail logs in another terminal while you work

```sh
$ rh tail my-app
Tailing runtime log for my-app. Ctrl-C to stop.
[server] listening on :3001
[server] GET / 200 12ms
...

# Or stream the build log of an in-flight deploy
$ rh tail my-app build
Tailing build log for my-app. Ctrl-C to stop.
[clone] git clone --depth=1 ...
[install] npm ci
...
```

### Identity in a script

```sh
$ rh whoami --json
{"name":"kiro-access","id":"k_abc123"}

$ rh whoami           # human readable
{
  "name": "kiro-access",
  "id": "k_abc123"
}
```

### Run a quick query

```sh
$ rh sql my-app "SELECT count(*) FROM users"
count(*)
--------
       42
```

### Push code, redeploy, watch the build

```sh
$ git push
$ rh redeploy my-app
OK deploy started for my-app. Tail with: rh logs my-app

$ rh tail my-app build
Tailing build log for my-app. Ctrl-C to stop.
[clone] git clone --depth=1 https://github.com/...
[install] npm ci
...
```

### Wire up MCP for Claude Desktop / Kiro

```sh
$ rh mcp

=== Claude Desktop / claude_desktop_config.json ===
{
  "mcpServers": {
    "rofihosted": {
      "url": "https://app.rofihosted.space/mcp",
      "transport": "streamable-http",
      "headers": { "Authorization": "Bearer ${ROFIHOSTED_API_KEY}" }
    }
  }
}
```

After this, your AI assistant can directly call tools like `list_projects`,
`get_system_info`, `query_db`, `set_secret`, `block_ip`, etc.
See `https://app.rofihosted.space/.well-known/mcp.json` for the discovery doc.

## CI integration

The repo's GitHub Actions workflow at `.github/workflows/auto-deploy.yml`
is `rh update` automated on every push to main. Set the `HP_ADMIN_API_KEY`
repository secret to enable it.

## Troubleshooting

**"hp-server did not advance within 4 minutes"** during `rh update` - the
phone is rebuilding. ReleaseFast on a Snapdragon 720G takes 30-300 seconds
depending on cache state. Cloudflare's 100-second gateway timeout means we
can't wait synchronously, so we poll. If it's been 4+ minutes, SSH in and
check `~/logs/self-update.log`.

**`rh deploy` says "non-static deploy not supported via zip upload"** - true,
but only for the legacy directory-zip path. For backend projects, prefer the
repo-URL flow:

```sh
rh deploy https://github.com/you/my-api
```

The server will run install + build + start automatically.

**`rh exec` returns nothing** - check that your key has the `admin` scope.
`sql` and `mcp` are admin-only operations.
