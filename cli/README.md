# rh - rofihosted CLI

Manage your phone-based hp-server from any laptop. No SSH required.

## Install

```sh
cd cli
npm install -g .
# or for development:
chmod +x rh.mjs
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
| `rh deploy <dir> <sub>` | Zip a directory and upload as a static project |
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

### Deploy a Vite app

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

**`rh deploy` says "non-static deploy not supported via zip upload"** - true.
For Node/Python/etc, push your code to a git repo, set the repo URL via the
dashboard, then `rh redeploy <sub>`.

**`rh exec` returns nothing** - check that your key has the `admin` scope.
`sql` and `mcp` are admin-only operations.
