# rh - rofihosted CLI

Manage your phone-based hp-server from any laptop without SSH.

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

1. Open `https://app.rofihosted.space/security`
2. Click "New API key"
3. Set scope to `admin`
4. Copy the key value
5. Run `rh login` and paste it

The key is stored in `~/.rofihosted/config.json` mode 0600.

You can also use environment variables instead:

```sh
export ROFIHOSTED_API_KEY=xxx
export ROFIHOSTED_BASE=https://app.rofihosted.space  # optional, this is the default
```

## Commands

```
rh login              save API key (interactive)
rh whoami             show key identity
rh status             full hp-server vitals (battery, mem, disk, version)
rh power              charger status
rh update             pull latest commit and rebuild on the phone
rh backup             trigger a local backup
rh backup --r2        trigger a local + R2 backup
```

## Examples

```sh
# Quick health check
$ rh status
hp-server status
  version    35ed412 (up to date)
  binary     built 5/28/2026, 7:30:10 PM
  battery    90% full
  memory     2641 / 7574 MB
  disk       80.1 / 93.4 GB free
  uptime     2d 6h

# Push code to GitHub, then deploy
$ git push
$ rh update
Triggering /v1/system/update on https://app.rofihosted.space...
(this can take 30-90s for full rebuilds)
OK updated 35ed412 -> a1b2c3d (hp-server is restarting)

# Just before going to sleep, snapshot to R2
$ rh backup --r2
{
  "ok": true,
  "target": "r2",
  "exit_code": 0,
  "elapsed_ms": 1340,
  "stdout": "...{...,\"size_bytes\":4096,\"upload_ms\":820}\n",
  "stderr": ""
}
```

## CI integration

GitHub Actions workflow at `.github/workflows/auto-deploy.yml` does the
same thing as `rh update` automatically on every push to main.
Set the `HP_ADMIN_API_KEY` repository secret to enable it.

## What's not yet supported

All planned commands now work:
- `rh login` - save API key
- `rh whoami` - identity check
- `rh status` - full vitals
- `rh power` - charger status
- `rh update` - self-update from GitHub
- `rh backup [--r2]` - snapshot to local + R2
- `rh ls` - list projects
- `rh deploy <dir> <sub>` - zip + upload a directory
- `rh logs <sub>` - tail build + runtime logs

For things not in the CLI yet (project secrets, env vars, cron tasks),
use the dashboard at `https://app.rofihosted.space/projects`.
