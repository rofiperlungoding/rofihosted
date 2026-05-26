# Architecture

This is a single-binary HTTP server written in Zig 0.14, deployed to one user's Termux session on Android 12. It is not designed for horizontal scaling.

## Process model

One process, `hp-server`, started by Termux:Boot at phone startup. Inside that process:

| Thread | Purpose |
| --- | --- |
| Main + httpz pool | Accept TCP, parse HTTP, dispatch to handlers |
| `uptime.checkerLoop` | Probe configured targets every 60s |
| `store.rotatorLoop` | Hourly rotate JSONL logs over 2 MB |
| `events.heartbeatLoop` | Send `:` keepalive to SSE clients every 25s |
| `statsTickLoop` | Read /proc, publish stats every 2s if anyone is subscribed |
| One thread per active SSE client | Owns a TCP stream, written to by the bus |

All shared state goes through `std.Thread.Mutex`. JSONL writes serialise via `store_mutex`; blocklist + autoban + login tracker each have their own mutex. The event bus has its own.

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
  +--> auth.isAuthenticated          (cookie HMAC verify)
  +--> blocklist.isBlocked
  +--> security.classify             (combine path heuristics + UA + browser fingerprint)
  +--> if blocked: 403, log, return
  +--> if scanner: autoban.recordScannerHit
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

Files are rotated hourly when over 2 MB by walking line-by-line and rewriting the tail.

Credentials and blocklist live outside `~/data/` so they aren't swept up in routine backups:

- `~/.hp-server-creds.txt` - mode 600, two lines (user, pass)
- `~/.hp-server-blocklist.txt` - mode 600, TSV: `ip<TAB>blocked_at<TAB>expires_at<TAB>reason`

## Authentication

Cookie name: `rofi_session`. Format: `base64url(payload).base64url(hmac256(payload))`. Payload format: `<unix_expiry>:<username>`.

The HMAC key is derived once on each `auth.Config.recomputeSecret` call as:

```
SHA-256("rofi.session.v1:" || password || ":" || username)
```

Changing either the password or the username via `/settings/change` rotates the secret, instantly invalidating every existing cookie on every device. Cookies are issued with `Secure; HttpOnly; SameSite=Lax; Domain=.rofihosted.space; Max-Age=604800`.

## Real-time events

Each authenticated SSE subscriber connects to `/api/stream`. httpz `startEventStreamSync` switches the response into chunked-streaming mode and disowns the underlying socket. The application registers the stream with `events.Bus`. The bus stores subscribers in an `ArrayList(*Subscriber)` guarded by a mutex.

Publishing iterates subscribers, writes the formatted SSE record (`event: <name>\ndata: <json>\n\n`), and on any write error marks the subscriber dead and removes it. Dead detection is also done via a heartbeat thread that writes `:\n\n` (SSE comment) every 25s.

Events emitted today:

| Event | Where | Payload |
| --- | --- | --- |
| `hello` | Once on connect | `{ts}` |
| `visit` | After every handled request | full Visit record |
| `login_attempt` | After every login submit | `{timestamp, ip, username, success}` |
| `blocklist_change` | On block / unblock | `{action, ip, reason?, timestamp}` |
| `uptime_probe` | After each probe | full UptimeRecord |
| `stats_tick` | Every 2s when at least one subscriber is connected | `{memory, process, timestamp}` |

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

That is the entire dependency graph for the application binary. Cloudflared is a separate Go binary downloaded once at provisioning time.

## Build

```sh
zig build -Doptimize=ReleaseFast
```

ReleaseFast emits ~10 MB binary. The Zig compile step warns about `FileNotFound` while probing for libc; this is harmless on Termux because we don't link libc.

The build must be wrapped in `proot` so the Zig package fetcher can resolve DNS and validate TLS:

```sh
proot \
  -b $PREFIX/etc/resolv.conf:/etc/resolv.conf \
  -b $PREFIX/etc/tls/cert.pem:/etc/ssl/certs/ca-certificates.crt \
  -b $PREFIX/etc/tls/cert.pem:/etc/ssl/cert.pem \
  zig build -Doptimize=ReleaseFast
```

## Boot sequence

`~/.termux/boot/01-server.sh` runs at Termux launch:

1. `termux-wake-lock` to keep the process scheduled when the screen is off
2. `sshd` if not already running
3. `hp-server` from `~/zig/hp-server/zig-out/bin/hp-server`
4. `cloudflared tunnel run` via proot, using `~/.cloudflared/config.yml`

Termux:Boot must be opened once after install for Android to allow it to run on subsequent reboots.
