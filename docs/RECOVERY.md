# Disaster Recovery

This document covers what to do when the Sharp Aquos S40P device that runs
rofihosted dies, gets stolen, breaks, or otherwise becomes unreachable.

## Known device quirks

The device has a faulty charging circuit. It bootloops the moment AC power
is removed if it's currently powered on. To shut down cleanly, you must:

1. Plug the charger in
2. Hold power, choose Shutdown
3. Wait until fully off
4. Then unplug

To boot it back up, you must:

1. Plug the charger in first
2. Press power
3. Wait for Android to load before doing anything else

The battery itself is fine; the issue is at the charging IC level. The
in-process `powermon` module on hp-server alerts via Telegram the second
plug status changes from CHARGING/FULL to DISCHARGING/NOT_CHARGING, so you
get notified in seconds and can plug the cable back before the device
loses power.

## What gets lost when the phone dies

| Asset                                | Where it lives                        | Replaceable from        |
|--------------------------------------|---------------------------------------|-------------------------|
| hp-server source code                | github.com/rofiperlungoding/rofihosted| GitHub                  |
| hp-server compiled binary            | `~/zig/hp-server/zig-out/bin/`        | rebuild from source     |
| Project registry                     | `~/.hp-server-projects.jsonl`         | NOT replaceable, backup |
| Per-project data DB                  | `~/data/dbs/<id>.db`                  | NOT replaceable, backup |
| Per-project secrets vault            | `~/data/projects/<id>/secrets.bin`    | NOT replaceable, backup |
| Per-project working tree (build)     | `~/data/projects/<id>/`               | re-clone from repo URL  |
| Auth pepper                          | `~/.hp-server-secret.bin`             | regenerate (logs out)   |
| Cloudflare tunnel credentials        | `~/.cloudflared/<tunnel-id>.json`     | recreate via cloudflared|
| Cloudflare tunnel certificate        | `~/.cloudflared/cert.pem`             | re-login via cloudflared|

The first three rows are the only assets that are truly irreplaceable: the
project registry, the per-project DBs, and the encrypted secrets vaults.
Those are what backups should target.

## Backup strategy

### Option A: rsync to your laptop (manual, reliable)

When the phone is reachable on LAN:

```sh
# from your laptop
mkdir -p ~/rofihosted-backups/$(date +%Y%m%d)
rsync -av --include='/.hp-server-projects.jsonl' \
         --include='/.hp-server-creds.txt' \
         --include='/.hp-server-secret.bin' \
         --include='/.hp-server-blocklist.txt' \
         --include='/data/' \
         --include='/data/dbs/***' \
         --include='/data/projects/' \
         --include='/data/projects/*/' \
         --include='/data/projects/*/secrets.bin' \
         --exclude='*' \
         hp:/data/data/com.termux/files/home/ ~/rofihosted-backups/$(date +%Y%m%d)/
```

This grabs everything irreplaceable and skips the working trees (which
re-clone from GitHub on demand).

### Option B: trigger from /shell (works from anywhere)

Once the built-in shell is up, run from `app.rofihosted.space/shell`:

```sh
mkdir -p ~/backups
ts=$(date +%Y%m%d-%H%M%S)
tar czf ~/backups/rofihosted-$ts.tar.gz \
  ~/.hp-server-projects.jsonl \
  ~/.hp-server-creds.txt \
  ~/.hp-server-secret.bin \
  ~/.hp-server-blocklist.txt \
  ~/data/dbs/ \
  $(find ~/data/projects -name 'secrets.bin' 2>/dev/null) 2>/dev/null
ls -la ~/backups/
```

Then download via the `/files` page or scp from your laptop.

## Recovery on a brand new device

Assume new phone, fresh Termux install, no apps yet.

### 1. Install Termux + dependencies

```sh
pkg update && pkg upgrade -y
pkg install -y git openssh openssl-tool curl unzip nodejs python proot termux-api
```

(termux-api needs the Termux:API APK from F-Droid for battery status to work.)

### 2. Install Zig

```sh
curl -fsSL https://raw.githubusercontent.com/rofiperlungoding/rofihosted/main/scripts/install-zig-014.sh | sh
```

### 3. Clone the source

```sh
git clone https://github.com/rofiperlungoding/rofihosted ~/zig
cd ~/zig/hp-server
```

### 4. Restore the irreplaceable data

Unpack the most recent backup:

```sh
cd ~
tar xzf /path/to/rofihosted-YYYYMMDD-HHMMSS.tar.gz
```

This drops `.hp-server-*` files in `$HOME` and rebuilds `~/data/dbs/` and
the per-project `secrets.bin` files.

### 5. Re-create the Cloudflare tunnel

```sh
~/scripts/install-cloudflared.sh
~/scripts/cf-login.sh        # opens browser, sign in to Cloudflare
~/scripts/recreate-tunnel.sh # creates rofihosted-tunnel and rotates DNS
```

### 6. Build hp-server

```sh
~/rebuild.sh
```

### 7. Start the watchdog

```sh
~/scripts/watchdog.sh &
```

The watchdog spawns hp-server, hp-server reads the registry, and supervisor
auto-starts every project marked `running`. Project working trees that are
gone get re-cloned on the next deploy.

### 8. Verify

```sh
~/verify-everything.sh
```

Should show 30/30 PASS plus the project list from before.

## What to do RIGHT NOW

1. Set up Telegram bot via `scripts/set-telegram.sh` so charger-disconnect
   alerts actually reach you.
2. Run option A or B above weekly. Set a calendar reminder.
3. Keep at least one charger cable that works permanently with the device.
   Buy a spare; this is the single point of failure.
4. Consider a UPS or battery pack between mains and the phone so brief
   power outages don't kill it.

## What hp-server already does for you

- `powermon` polls battery_status every 30s and fires Telegram alerts on
  charger-disconnect.
- On disconnect, hp-server runs `sync` to flush filesystem buffers before
  the device potentially bootloops.
- SQLite uses WAL mode + atomic rename writes for the registry, so a
  sudden power loss doesn't corrupt the project list (worst case: loses
  the last few seconds of changes).
- Watchdog (`scripts/watchdog.sh`) auto-restarts hp-server if it crashes
  and respawns cloudflared if the tunnel dies.
- supervisor.zig writes a pidfile per project so child processes get
  reaped cleanly across hp-server restarts.

## Failure modes and what they look like

**Charger cable dies overnight**: device bootloops, all projects offline
until you replace the cable. Telegram pings you instantly when status
flips to DISCHARGING. Backup is fine; just plug in and reboot.

**Phone storage corrupts**: rare, but if `~/data/dbs/<id>.db` becomes
unreadable, the project's auth + app data is gone. Restore from latest
backup. Project source code and Cloudflare config are unaffected.

**Phone gets stolen / lost**: replace device, follow recovery steps above.
Cloudflare tunnel credentials let attackers proxy traffic through your
account, so revoke the tunnel from Cloudflare dashboard immediately.

**Cloudflare account compromised**: revoke tunnel, revoke API tokens,
rotate `~/.cloudflared/cert.pem` and tunnel JSON, re-issue, redeploy.
Project data on the phone is unaffected.
