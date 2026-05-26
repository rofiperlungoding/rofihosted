# Security model

This document describes what `hp-server` defends against, how, and what it does not. Be honest here, especially about the limits.

## Threat model

This is a single-user home server hanging off a residential ISP. The realistic adversaries are:

| Adversary | Goal | Frequency |
| --- | --- | --- |
| CT-log scanners | Index newly-issued TLS certificates and probe the host for known vulns | Within minutes of cert issuance |
| Mass scanners | Sweep IPv4 / known Cloudflare ranges for `.env`, `/wp-admin`, `phpMyAdmin`, etc | Continuous |
| Credential brute-forcers | Try common username/password pairs on `/login` | Continuous if path is reachable |
| Botnet recon | Enumerate routes, fingerprint stack, look for misconfig | Continuous |
| Targeted attacker | Hand-tailored attempts after seeing the site | Rare, higher skill |

What this project is **not** trying to defend against: nation-state adversaries, supply chain attacks on Cloudflare or Termux, physical access to the device, or rooting the phone.

## Attack surface

```
Internet
   |
   v
Cloudflare edge        <- TLS termination, DDoS absorption, IP reputation
   |
cloudflared (Go)       <- Outbound-only mTLS tunnel back to phone
   |
hp-server :8080        <- Where this codebase actually lives
   |
   +-- Termux user processes (sshd on local LAN only)
   +-- /proc reads (read-only, SELinux-confined)
   +-- termux-api subprocess (battery, wifi info)
```

The phone has **no inbound port** open to the internet. Cloudflare establishes the connection outbound; if the tunnel goes down, the public side returns a 1033 from Cloudflare's edge, not a connection error from a routable IP.

## Defenses in place

### TLS
- Termination at Cloudflare with their managed cert. The origin (`hp-server`) speaks plain HTTP over the tunnel, but the tunnel itself is mTLS (`cloudflared` ↔ Cloudflare).
- HSTS header with `max-age=31536000; includeSubDomains` so browsers refuse plain HTTP after first visit.

### Authentication
- Cookie sessions, not HTTP basic auth. Single user. No "register" flow.
- Cookie is `base64url(payload).base64url(hmac256(payload))` where payload is `<unix_expiry>:<username>`.
- HMAC key is `SHA-256("rofi.session.v1:" || password || ":" || username)`. **Changing the password rotates the key**, so every existing session everywhere is invalidated.
- Cookie attributes: `Secure; HttpOnly; SameSite=Lax; Domain=.rofihosted.space; Max-Age=604800` (7 days).
- TTL is enforced both on the cookie and inside the signed payload, so a stolen cookie cannot be used past expiry even if `Max-Age` is stripped.
- Login form uses constant-time comparison for both username and password (`auth.constantTimeEqual`).

### Authorization
- Anonymous can reach: `rofihosted.space/` (placeholder), `/health`, `/login`, and the static asset routes (`theme.css`, `theme.js`, `app.css`, `app.js`).
- Everything else on `app.rofihosted.space` requires a valid session cookie. The check is the very first thing on every protected handler.
- `/api/*` is part of the protected set. There is no public API.

### Request classification (security.zig)
Every request is classified before it reaches a handler:

| Class | Trigger |
| --- | --- |
| `self` | Cookie verifies as the operator |
| `blocked` | Source IP is in the blocklist (and not expired) |
| `scanner` | Path matches a known vuln-scan fragment (`.env`, `/wp-admin`, `/phpmyadmin`, dot-files, common probes) or `.php`/`.asp`/`.aspx`/`.jsp` extension |
| `bot` | Empty UA, declared bot UA (curl, wget, python-, googlebot, ...), or missing `Accept-Language` and `Sec-Fetch-*` headers |
| `unknown` | Browser-like fingerprint but not authenticated |

The full pattern lists live in `security.zig` constants `SCANNER_PATH_FRAGMENTS` and `BOT_UA_PATTERNS`. Both lists were chosen from public mass-scan datasets and the project's own visit log.

### Auto-ban
Two trackers in `security.zig`, both with TTL'd ban entries:

- `AutoBan`: 3 scanner hits from the same IP within 10 minutes triggers a 24-hour ban with reason `auto: scanner attempts exceeded threshold`.
- `LoginTracker`: 5 failed login attempts from the same IP within 15 minutes triggers a 1-hour ban with reason `auto: login brute force`.

Bans persist to disk (`~/.hp-server-blocklist.txt`, mode 600) so they survive restarts. The file format is TSV: `ip<TAB>blocked_at<TAB>expires_at<TAB>reason`. Expired entries are evicted lazily on read.

### Per-IP rate limit
Token bucket per source IP, refilled continuously. The bucket is bypassed for `127.0.0.1` (self) and `/health`. Limits are defined in `ratelimit.zig`.

### Security headers (every response)
- `Strict-Transport-Security: max-age=31536000; includeSubDomains`
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY` (clickjacking prevention)
- `Referrer-Policy: strict-origin-when-cross-origin`
- `Permissions-Policy: camera=(), microphone=(), geolocation=(), interest-cohort=(), payment=(), usb=()`
- `Content-Security-Policy`: scoped to `'self' https://rofihosted.space https://*.rofihosted.space`, plus `cdnjs.cloudflare.com` for the icon font. `frame-ancestors 'none'`, `base-uri 'self'`, `form-action 'self' + own subdomains`.

### Audit logs
- `~/data/visits.jsonl`: every request with `visited_at`, `ua`, `ip`, `path`, `method`, `host`, `status`, `referer`, `country`, `classification`.
- `~/data/logins.jsonl`: every login attempt with `timestamp`, `ip`, `ua`, `username`, `success`.
- `~/data/uptime.jsonl`: every probe result.

Files rotate hourly when over 2 MB. Logs are visible from the Security and Status pages in real time.

## Secrets

Files that **never** leave the device:

| File | Purpose | Mode |
| --- | --- | --- |
| `~/.hp-server-creds.txt` | username + password (line 1: user, line 2: pass) | 0600 |
| `~/.hp-server-blocklist.txt` | persistent IP blocklist | 0600 |
| `~/.cloudflared/<tunnel-id>.json` | tunnel credentials issued by Cloudflare | 0600 |
| `~/.cloudflared/cert.pem` | account cert for `cloudflared tunnel` operations | 0600 |

None of these are tracked in git. The `.gitignore` excludes the `~/data/`, `~/.hp-server-*`, and `~/.cloudflared/` paths even if the workspace ever picks them up by accident.

The HMAC session key is derived in memory only. It is never persisted.

## Known limitations / not defended against

- **Origin IP exposure if cloudflared misconfigures.** The phone's residential IP would leak. Mitigated by running `cloudflared` with `protocol: http2` and never binding any port directly to a public interface.
- **DDoS at the cloudflared link.** Cloudflare's free plan absorbs L3/L4 floods, but a sufficiently large L7 flood would saturate the tunnel before reaching the phone. There is no fallback.
- **Compromised Cloudflare account.** If the dashboard is taken over, the attacker can reroute the domain or issue new certs. Two-factor auth is on; no further mitigation in this project.
- **Compromised SSH key.** SSH on the phone is reachable over LAN only (192.168.100.x), key-based auth, password auth disabled. If the operator's laptop key is stolen and the attacker is on the same WiFi, they get shell.
- **Side channels.** No defense against timing leaks beyond the constant-time HMAC and password compare. Cache-timing on shared infrastructure isn't relevant since the binary runs on a phone with no other tenants.
- **Physical access.** Anyone holding the phone can unlock Termux, read all files, and impersonate the operator. The phone's lockscreen is the only barrier.
- **Subdomain takeover.** All DNS records point to the same tunnel. If the tunnel is deleted but DNS lingers, no third party can claim a Cloudflare tunnel name they don't own (Cloudflare scopes tunnel names to the account), so this isn't currently a risk.

## Reporting

This is a personal project. If you find a vulnerability, open an issue at <https://github.com/rofiperlungoding/rofihosted/issues>. Do not include exploit details in the title.

## Verification checklist

When changing security-related code, verify the following manually:

- [ ] Login still requires both correct username and correct password
- [ ] Wrong password 5 times from the same IP within 15 minutes results in a 1-hour ban
- [ ] Hitting `/wp-admin` 3 times within 10 minutes results in a 24-hour ban
- [ ] After changing password via `/settings`, all old cookies on other devices stop working
- [ ] `curl -I https://app.rofihosted.space/` returns all six security headers
- [ ] `/api/*` endpoints return 401 without a valid cookie
- [ ] Static assets (`/theme.css`, etc) on `app.rofihosted.space` are reachable without auth (so the login page can load them)
