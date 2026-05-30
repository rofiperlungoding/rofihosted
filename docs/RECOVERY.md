# Recovery (cold boot, watchdog, OOM)

Sharp Aquos Sense4 Plus is the only piece of hardware running rofihosted, and the battery is failing — pulling the charger reliably bootloops the device. This document covers what happens between "phone went dark" and "site is serving traffic again."

## TL;DR

The phone reboots, Termux:Boot fires `~/.termux/boot/01-server.sh`, that script starts hp-server + cloudflared + watchdog + sshd, hp-server's `restartPersisted()` brings every project that was `running` at last shutdown back online, and the watchdog keeps everything alive from then on. Hp-server itself watches the watchdog (`watchdogSentinelLoop`), so a dead watchdog is also self-healing.

End-to-end: ~15 to 30 seconds from kernel boot to "first request served."

## The recovery chain

```
power on
  v
Android 12 boot
  v
Termux:Boot package fires
  v
~/.termux/boot/01-server.sh                        (`boot_script_present`)
  | export env from ~/.hp-server.env
  | termux-wake-lock
  | sshd
  | hp-server (Zig binary)                         (uptime_seconds)
  | cloudflared --tunnel run                       (`cloudflared_running`)
  | ~/watchdog.sh (long-lived loop)                (`watchdog_running`)
  | ~/backup.sh (one-shot at boot)
  v
hp-server.main()
  | supervisor.restartPersisted()                  (`projects_running`)
  | digestLoop, policyLoop, embeddings, dbcache
  | watchdogSentinelLoop (re-spawns watchdog if it dies)
  | hourlyBackupLoop
  v
serving traffic
```

Every node in that chain is reflected in `GET /v1/system/recovery` so the smoke test can assert all of it.

## Components

### Termux:Boot

- Package: `com.termux.boot` from F-Droid.
- Granted "Run on boot" permission once during install.
- Runs every script in `~/.termux/boot/` at OS boot. The only file there is `01-server.sh`.
- If this is missing (uninstalled, permission revoked) the entire chain stops at the kernel. There is no fallback.

### `~/.termux/boot/01-server.sh`

The master boot script. Idempotent — every step checks `pgrep` first so re-running it during a hot reboot is safe. Sequence:

1. Append to `~/logs/boot.log`. The mtime on this file is what `/v1/system/recovery.boot_log_recent_unix` reports.
2. Source `~/.hp-server.env` so children inherit credentials and API keys.
3. `termux-wake-lock` to prevent Android's aggressive sleep killing background services.
4. `sshd` (port 8022, key-only).
5. `hp-server` (Zig binary at `~/zig/hp-server/zig-out/bin/hp-server`).
6. `cloudflared tunnel run` via `proot` (so DNS + CA paths resolve correctly under Bionic).
7. `~/watchdog.sh` if not already running.
8. One-shot `~/backup.sh` if `BACKUP_PASSPHRASE` is set.

### `~/watchdog.sh`

Bash loop, 30 s interval. Five checks per tick:

| # | Check | Action on failure |
|---|---|---|
| 1 | `pgrep -f 'hp-server$'` | Spawn fresh hp-server |
| 2 | `curl /health` succeeds | After 3 consecutive failures, force-restart hp-server (catches deadlocks pgrep misses) |
| 3 | hp-server RSS &le; 384 MB | SIGTERM, then respawn (lets writebuf flush before Android OOM kills it) |
| 4 | `pgrep -f 'cloudflared.*tunnel'` | Spawn cloudflared |
| 5 | `~/data/.tunnel-restart-requested` flag | Restart cloudflared (hp-server's tunnel-health watchdog drops the flag when the tunnel goes dark) |

### `watchdogSentinelLoop` (inside hp-server)

What kept the watchdog alive before? Nothing — if the watchdog itself died, no one was watching. So hp-server now also watches the watchdog. Every 90 seconds:

- `pgrep -f 'watchdog\.sh'`
- If exit code != 0 (no match), respawn it via `setsid nohup ~/watchdog.sh > ~/logs/watchdog.log 2>&1 < /dev/null &`

This forms a loop: hp-server watches watchdog, watchdog watches hp-server. The only way both die simultaneously is a kernel-level event (panic, OOM hitting both processes in the same scan). At that point Termux:Boot picks up the pieces on next cold boot.

### `supervisor.restartPersisted()`

Walks `~/.hp-server-projects.jsonl` at hp-server boot. For every project with `status == "running"` at last shutdown:

1. Read its secrets vault.
2. Inject `PORT`, `HOST`, `NODE_ENV`, `DATABASE_URL`, etc. (Phase 2.9 zero-config env).
3. `sh -c <start_cmd>` with stdout/stderr piped to `~/data/projects/<id>/logs/runtime.log`.

Static projects don't need a process — they're just files under `current/`, served by hp-server's HTTP layer.

This is why a clean reboot leaves every project online without operator intervention.

## Verifying recovery is wired correctly

`GET /v1/system/recovery` (admin scope):

```json
{
  "ok": true,
  "boot_script_present": true,
  "watchdog_script_present": true,
  "watchdog_running": true,
  "cloudflared_running": true,
  "boot_log_recent_unix": 1780125425,
  "uptime_seconds": 12347,
  "projects_running": 2,
  "projects_total": 5
}
```

Smoke test (`scripts/test-everything.sh` "BOOT RECOVERY CHAIN" section) asserts each `*_present` and `*_running` field is true. If any are false, a real cold boot will leave the platform broken.

## Reboot drill (manual full test)

1. Save current uptime as baseline:

   ```sh
   curl -sm 5 -H "X-API-Key: $HP_ADMIN_KEY" \
     https://app.rofihosted.space/v1/system/recovery
   ```

2. Trigger a reboot. From the phone or a connected SSH session:

   ```sh
   # On phone
   reboot
   # Or via API (requires admin scope, will hang at 524)
   curl -sm 10 -H "X-API-Key: $HP_ADMIN_KEY" -X POST \
     "https://app.rofihosted.space/api/system/exec" \
     -H "Content-Type: application/json" \
     -d '{"cmd":"reboot","timeout_ms":5000}'
   ```

3. Wait 60-120 seconds. Cloudflared takes longest to come back (named tunnel registration).

4. Re-check:

   ```sh
   curl -sm 5 -H "X-API-Key: $HP_ADMIN_KEY" \
     https://app.rofihosted.space/v1/system/recovery
   ```

   - `uptime_seconds` should be a small number (< 200).
   - `boot_log_recent_unix` should be very recent.
   - `watchdog_running` and `cloudflared_running` must be true.
   - `projects_running` should match what was running before reboot.

5. Run smoke test for full coverage:

   ```sh
   ssh hp 'bash ~/test-everything.sh 2>&1 | tail -10'
   ```

   The "BOOT RECOVERY CHAIN" section should be all green.

## Failure modes and recovery paths

| Failure | Recovery layer that catches it | Time to recover |
|---|---|---|
| hp-server crashes (segfault, panic) | `watchdog.sh` step 1 | &le; 30 s |
| hp-server hangs (deadlock, infinite loop) | `watchdog.sh` step 2 | &le; 90 s |
| hp-server leaks RAM | `watchdog.sh` step 3 | &le; 30 s after threshold |
| cloudflared crashes | `watchdog.sh` step 4 | &le; 30 s |
| cloudflared running but tunnel never registered (e.g. WiFi reconnect after reboot) | `watchdog.sh` step 5 (tunnel state via metrics endpoint) | &le; 5 min |
| cloudflared connected but no traffic | `watchdog.sh` step 6 (via hp-server flag) | 2-5 min |
| `watchdog.sh` dies | `watchdogSentinelLoop` in hp-server | &le; 90 s |
| Both watchdog + hp-server die | next cold boot via Termux:Boot | depends on operator |
| Phone power off / battery yanked | `01-server.sh` on next power-on | 60-120 s after kernel up |
| Termux:Boot uninstalled | None — operator must reinstall | manual |
| `~/.hp-server.env` deleted | hp-server boots without auth keys; data still safe; operator must restore from backup | minutes |
| Disk full | hp-server logs warnings, no automatic recovery; backups will fail | operator must clear |
| Cloudflare account disabled / DNS broken | None — outside the device | external |

## Things that are NOT auto-recovered

- **Termux:Boot uninstalled OR battery-optimized.** If the operator removes Termux:Boot, revokes its boot permission, OR Android puts Termux/Termux:Boot under battery optimization, the entire chain stops at the kernel. Sharp Aquos Android 12 in particular ships with aggressive battery optimization. To exempt:

  ```
  Settings -> Apps -> Termux         -> Battery -> Unrestricted
  Settings -> Apps -> Termux:Boot    -> Battery -> Unrestricted
  Settings -> Apps -> Termux:API     -> Battery -> Unrestricted
  ```

  Also disable "Adaptive battery" globally for these apps if the option is present. Without this, Android will SIGKILL Termux background processes during Doze mode.

- **WiFi takes too long to reconnect after reboot.** The boot script now waits up to 90 seconds for `https://1.1.1.1/` to be reachable before spawning cloudflared (Phase 3 hardening). If WiFi still hasn't connected after that, the script proceeds and the watchdog handles cloudflared retries. Worst case, hp comes back online ~1-2 min after WiFi finally connects.
- **Cloudflare credentials expired or rotated.** The named tunnel uses long-lived credentials at `~/.cloudflared/`. If those are revoked, cloudflared fails to register. Operator must run `scripts/cf-login.sh` again.
- **`~/.hp-server.env` deleted.** hp-server boots in a degraded mode (no AI, no Telegram, no R2 backup, possibly no auth) but doesn't crash. The operator restores from the latest age-encrypted backup.
- **Pepper file deleted.** `~/.hp-server-secret.bin` rotation invalidates every session and every secret encrypted at rest. There is no automatic recovery — restore from a backup that has the matching pepper, or do a clean reset.
- **Disk full.** Every layer logs warnings, none can free space on its own. Hourly backup will fail; smoke test will show it.

## Re-installing the recovery chain from scratch

If the phone is wiped or the operator is rebuilding from a backup:

```sh
# 1. Install Termux + Termux:Boot from F-Droid
# 2. pkg install openssh nodejs zig curl git rclone age termux-api
# 3. Clone the repo
git clone https://github.com/rofiperlungoding/rofihosted.git ~/rofihosted-src

# 4. Copy boot script
cp ~/rofihosted-src/scripts/boot-all.sh ~/.termux/boot/01-server.sh
chmod +x ~/.termux/boot/01-server.sh

# 5. Restore env + secrets from latest backup
age -d -i ~/.age-key ~/backups/latest.tar.age | tar -xf - -C ~

# 6. Build the binary
cd ~/zig/hp-server && ~/rebuild.sh

# 7. Run boot script once manually to verify
bash ~/.termux/boot/01-server.sh

# 8. Reboot to confirm Termux:Boot fires
reboot
```

Time-to-restore is usually 15-30 minutes including the Zig build.
