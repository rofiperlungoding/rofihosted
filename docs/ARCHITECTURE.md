# Architecture

This is a single-binary HTTP server written in Zig 0.14, deployed to one user's Termux session on Android 12. It is not designed for horizontal scaling.

## Process model

Two processes cooperate at runtime:

- `hp-server` (the Zig binary): serves HTTP, runs all in-process loops below.
- `watchdog.sh`: a sibling shell loop that restarts `hp-server` and `cloudflared` if they die, and reacts to the in-process tunnel-restart flag.

Inside `hp-server`:

| Thread | Purpose |
| --- | --- |
| Main + httpz pool | Accept TCP, parse HTTP, dispatch to handlers |
| `uptime.checkerLoop` | Probe configured targets every 60s |
| `store.rotatorLoop` | Hourly rotate JSONL logs over 2 MB |
| `events.heartbeatLoop` | Send `:` keepalive to SSE clients every 25s |
| `statsTickLoop` | Read /proc, publish stats every 2s if anyone is subscribed |
| `digestLoop` | Generate the daily AI digest every 24h (waits 5 min after boot) |
| `tunnel_health.loop` | Poll cloudflared metrics every 30s, classify state, request restart after >2 min downtime |
| One thread per active SSE client | Owns a TCP stream, written to by the bus |
| Per-event short-lived threads | Annotate auto-bans via Mistral (fire-and-forget) |

All shared state goes through `std.Thread.Mutex`. JSONL writes serialise via `store_mutex`. The blocklist, autoban tracker, login tracker, geoblock config, AI annotation cache, tunnel-health status, and event bus each have their own mutex.

The SIGTERM and SIGINT handlers call `httpz.Server.stop()` so the server drains in-flight requests, lets background loops finish their current iteration, and exits cleanly. JSONL appenders use `O_APPEND` so partial writes can never corrupt other lines.

## Request lifecycle

```
TCP accept
  |
httpz.Server worker
  |
  v
hostRouter (one big handler)
  |
  +--> security.applyHeaders         (HSTS, CSP, etc, on every response)
  +--> resolve ip + ua + method
  +--> auth.isAuthenticated          (cookie HMAC verify, with pepper)
  +--> blocklist.isBlocked
  +--> security.classify             (combine path heuristics + UA + browser fingerprint)
  +--> if blocked: 403, log, return
  +--> geoblock.shouldBlock          (skip if authed/local; only when feature is on)
  +--> if scanner: autoban.recordScannerHit -> if did_ban: spawn AI annotation thread
  +--> rateLimit.allow (per IP)      (skip for self + /health)
  +--> dispatch by host:
  |      - rofihosted.space        => handleRoot (public landing + shared assets)
  |      - app.rofihosted.space    => handleApp  (private console + JSON API)
  |      - legacy subdomains       => 301 to app
  +--> after handler returns:
        logVisitFull -> appendJson visits.jsonl + bus.publish(.visit, ...)
```

## Storage

Append-only JSONL files in `~/data/`:

- `visits.jsonl` - every request, fields: `visited_at, ua, ip, path, method, host, status, referer, country, classification`
- `uptime.jsonl` - every probe result
- `logins.jsonl` - every authentication attempt
- `audit.jsonl` - every operator action: block, unblock, change credentials, run digest, geoblock update
- `digests.jsonl` - one line per generated daily digest

Files are rotated hourly when over 2 MB by walking line-by-line and rewriting the tail.

Credentials and policy state live outside `~/data/`:

- `~/.hp-server-creds.txt` - mode 600, two lines (user, pass)
- `~/.hp-server-blocklist.txt` - mode 600, TSV: `ip<TAB>blocked_at<TAB>expires_at<TAB>reason`
- `~/.hp-server-secret.bin` - mode 600, 32 random bytes used as session-secret pepper
- `~/.hp-server-geoblock.txt` - mode 600, line 1 `on`/`off`, line 2 comma-separated country codes
- `~/.hp-server.env` - mode 600, environment variables (`MISTRAL_API_KEY`, optional `TG_*`, optional `BACKUP_PASSPHRASE`, `HP_AUTH_USER`/`HP_AUTH_PASS`)

## Authentication

Cookie name: `rofi_session`. Format: `base64url(payload).base64url(hmac256(payload))`. Payload format: `<unix_expiry>:<username>`.

The HMAC key is derived once on each `auth.Config.recomputeSecret` call as:

```
SHA-256("rofi.session.v1:" || password || ":" || username || ":" || pepper)
```

`pepper` is 32 random bytes loaded from `~/.hp-server-secret.bin` at startup (generated on first boot). Both the credentials file and the pepper file have to be exfiltrated to forge cookies. Changing the password or username via `/settings/change` rotates the secret immediately. Cookies are issued with `Secure; HttpOnly; SameSite=Lax; Domain=.rofihosted.space; Max-Age=604800`.

## Real-time events

Each authenticated SSE subscriber connects to `/api/stream`. httpz `startEventStreamSync` switches the response into chunked-streaming mode and disowns the underlying socket. The application registers the stream with `events.Bus`. The bus stores subscribers in an `ArrayList(*Subscriber)` guarded by a mutex.

Publishing iterates subscribers, writes the formatted SSE record (`event: <name>\ndata: <json>\n\n`), and on any write error marks the subscriber dead and removes it. Dead detection is also done via a heartbeat thread that writes `:\n\n` (SSE comment) every 25s.

Events emitted today:

| Event | Where | Payload |
| --- | --- | --- |
| `hello` | Once on connect | `{ts}` |
| `visit` | After every handled request | full Visit record |
| `login_attempt` | After every login submit | `{timestamp, ip, username, success}` |
| `blocklist_change` | On block / unblock / annotate | `{action, ip, reason?, timestamp}` |
| `uptime_probe` | After each probe | full UptimeRecord |
| `stats_tick` | Every 2s when at least one subscriber is connected | `{memory, process, timestamp}` |
| `tunnel_health` | On state transition | `{state, connections, timestamp}` |
| `digest_ready` | After each digest run | `{timestamp, summary}` |

## AI features (optional)

When `MISTRAL_API_KEY` is set, three opt-in features call out to `https://api.mistral.ai/v1/chat/completions` with model `mistral-small-latest`. Implementation lives in `ai.zig`; calls are made via `curl` subprocess (Zig `std.http` had Bionic-libc DNS issues).

| Feature | Trigger | Rate limit |
| --- | --- | --- |
| Auto-ban annotation | Background thread after `recordScannerHit` results in a ban | 1/min, burst 5; 24h per-IP cache |
| Explain IP | `POST /api/ai/explain` (operator click) | 1/6s, burst 10 |
| Daily digest | `digestLoop` thread or `GET /api/ai/digest/run` | 1/hour, burst 2 |

If the key is unset, all features no-op silently and the server keeps serving normal traffic.

## What we cannot read

Android 12 SELinux blocks several `/proc` paths for non-root user processes. The `/api/stats` capabilities object surfaces these honestly:

| Path | State |
| --- | --- |
| `/proc/meminfo` | readable |
| `/proc/self/*` | readable |
| `/proc/stat` (global CPU) | blocked |
| `/proc/loadavg` | blocked |
| `/proc/uptime` | blocked |
| `/proc/net/*` | blocked |

For data that lives outside our process we shell out to `termux-api` (`termux-battery-status`, `termux-wifi-connectioninfo`) and scrape `cloudflared` Prometheus metrics at `:20241/metrics`.

## Dependencies

- httpz (https://github.com/karlseguin/http.zig) tracking the `zig-0.14` branch
  - which transitively pulls metrics.zig and websocket.zig

That is the entire dependency graph for the application binary. Cloudflared is a separate Go binary downloaded once at provisioning time. `age` is required only for `scripts/backup.sh`.

## Source-file encoding

Every `.zig`, `.html`, `.css`, and `.js` file in `zig/hp-server/src/` is pure 7-bit ASCII. JS uses Unicode escapes (`\u00B0`, `\u2014`); HTML uses entities (`&deg;`, `&mdash;`); Zig sources avoid any non-ASCII glyph. This means a sloppy `tar | ssh` transfer cannot mangle multi-byte sequences and corrupt the running binary. The only binary asset is `Simple-Line-Icons.woff2`, which must always be transferred via `scp` (or `tar -czf`).

## Build

```sh
zig build -Doptimize=ReleaseFast
```

ReleaseFast emits ~12 MB binary (font + AI module add a small amount over the 10 MB pre-AI baseline). The Zig compile step warns about `FileNotFound` while probing for libc; this is harmless on Termux because we don't link libc.

The build must be wrapped in `proot` so the Zig package fetcher can resolve DNS and validate TLS:

```sh
proot \
  -b $PREFIX/etc/tls/cert.pem:/etc/ssl/certs/ca-certificates.crt \
  -b $PREFIX/etc/tls/cert.pem:/etc/ssl/cert.pem \
  zig build -Doptimize=ReleaseFast
```

## Boot sequence

`~/.termux/boot/01-server.sh` runs at Termux launch (see `scripts/boot-all.sh`):

1. Source `~/.hp-server.env` (with `set -a` so children inherit env vars)
2. `termux-wake-lock` to keep the process scheduled when the screen is off
3. `sshd` if not already running
4. `hp-server` from `~/zig/hp-server/zig-out/bin/hp-server`
5. `cloudflared tunnel run` via proot, using `~/.cloudflared/config.yml`
6. `watchdog.sh` (long-lived, restarts services if they die)
7. One-shot `backup.sh` if `BACKUP_PASSPHRASE` is set

Termux:Boot must be opened once after install for Android to allow it to run on subsequent reboots.
