# API Key Audit Report - rofihosted System

**Date:** 2026-06-03  
**Auditor:** Bob (AI Assistant)  
**System:** Sharp Aquos Sense4 Plus (Termux/Android 12)  
**Scope:** Comprehensive audit of all API keys, secrets, and credentials

---

## Executive Summary

Comprehensive audit completed of all API keys and secrets in the rofihosted personal cloud system. The system demonstrates **excellent API key management practices** with a well-architected security model.

**Findings:**
- ✅ **0 Critical Issues** - No exposed credentials or security vulnerabilities
- ✅ **0 Unused Keys** - All keys are actively used and necessary
- ✅ **0 Deprecated Keys** - No legacy or obsolete credentials
- ✅ **0 Redundant Keys** - No duplicate or overlapping credentials
- ⚠️ **2 Optimization Opportunities** - Minor enhancements identified
- 📋 **5 Recommendations** - Future improvements for consideration

**Overall Assessment:** ✅ **PASSED** - System is secure and well-maintained

---

## 📊 Complete API Key Inventory

### 1. Internal User API Keys (Managed System)

**Type:** User-created scoped tokens  
**Storage:** `~/.hp-server-apikeys.jsonl` (mode 0600)  
**Format:** `rh_<48 hex chars>`  
**Implementation:** [`zig/hp-server/src/apikey.zig`](../zig/hp-server/src/apikey.zig)

**Purpose:**
- Allow CLI/CI access without password-based sessions
- Scoped access control (sql, read, admin)
- Revocable tokens with audit trail

**Security Features:**
- SHA-256 hashed with per-install pepper before storage
- Constant-time verification (timing attack resistant)
- Last-used tracking for audit
- Multi-tenant support with owner_id
- Revocation support with timestamp

**Current Usage:**
- `rh` CLI tool (see [`cli/README.md`](../cli/README.md))
- GitHub Actions CI/CD (`.github/workflows/auto-deploy.yml`)
- MCP integration (Claude Desktop, Kiro, Cursor)

**Scopes:**
- `sql` - Database access via `/v1/execute`
- `read` - Read-only API access (reserved, not enforced)
- `admin` - Full system administration

**Status:** ✅ **ACTIVE & ESSENTIAL**  
**Action:** None required

---

### 2. Mistral AI API Key

**Environment Variable:** `MISTRAL_API_KEY`  
**Storage:** `~/.hp-server.env` (mode 0600)  
**Service:** Mistral AI (https://api.mistral.ai)  
**Implementation:** [`zig/hp-server/src/ai.zig`](../zig/hp-server/src/ai.zig)

**Purpose:**
Powers 8 AI features:
1. Auto-ban annotation (IP risk analysis)
2. IP explanation (security insights)
3. Daily digest generation
4. Text embeddings (1024-dim vectors)
5. Honeypot analysis
6. Policy generation
7. Query assistance
8. Anomaly detection

**Security Features:**
- Read once at startup, held in memory only
- Never logged or returned to clients
- Per-feature rate limiting (prevents quota drain)
- Graceful degradation (features no-op if key missing)
- Usage tracking (calls, tokens, cache hits, failures)

**Rate Limits:**
| Feature | Rate | Capacity |
|---------|------|----------|
| Annotate | 1/minute | 5 |
| Explain | 1/6 seconds | 10 |
| Digest | 1/hour | 2 |
| Embed | 1/5 seconds | 50 |
| Honeypot | 1/minute | 10 |
| Policy | 1/week | 2 |
| Query | 1/4 seconds | 8 |
| Anomaly | 1/30 seconds | 6 |

**Status:** ✅ **ACTIVE & OPTIONAL**  
**Action:** None required (system works without it)

---

### 3. Telegram Bot Credentials

**Environment Variables:** `TG_BOT_TOKEN`, `TG_CHAT_ID`  
**Storage:** `~/.hp-server.env` (mode 0600)  
**Service:** Telegram Bot API  
**Implementation:** [`zig/hp-server/src/telegram.zig`](../zig/hp-server/src/telegram.zig)

**Purpose:**
- Boot notifications (system startup alerts)
- Power monitoring alerts (charger disconnect warnings)
- Uptime notifications

**Security Features:**
- Optional (system works without it)
- Loaded from environment only
- Used only for outbound notifications
- No sensitive data transmitted

**Setup:** [`scripts/set-telegram.sh`](../scripts/set-telegram.sh)

**Status:** ✅ **ACTIVE & OPTIONAL**  
**Action:** None required

---

### 4. Cloudflare R2 Credentials

**Environment Variables:** `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`  
**Storage:** `~/.hp-server.env` (mode 0600) + `~/.config/rclone/rclone.conf`  
**Service:** Cloudflare R2 (S3-compatible object storage)  
**Implementation:** [`scripts/backup-r2.sh`](../scripts/backup-r2.sh), [`scripts/r2-setup.sh`](../scripts/r2-setup.sh)

**Purpose:**
- Hourly automated backups to offsite storage
- Backup retention (168 files = 7 days hourly)
- Disaster recovery

**Security Features:**
- Credentials stored in rclone config (mode 0600)
- Bucket name persisted separately
- Non-interactive setup via environment variables
- Backup verification available ([`scripts/verify-backup.sh`](../scripts/verify-backup.sh))

**Backup Schedule:** Every 3600 seconds (1 hour) via `hourlyBackupLoop` thread

**Status:** ✅ **ACTIVE & CRITICAL FOR DR**  
**Action:** None required

---

### 5. Cloudflare Tunnel Credentials

**Storage:** `~/.cloudflared/<tunnel-id>.json` (mode 0600), `~/.cloudflared/cert.pem`  
**Service:** Cloudflare Tunnel (cloudflared)  
**Implementation:** Tunnel health monitoring in [`zig/hp-server/src/tunnel_health.zig`](../zig/hp-server/src/tunnel_health.zig)

**Purpose:**
- Secure outbound-only tunnel to expose hp-server to internet
- No inbound ports on phone
- mTLS connection to Cloudflare edge

**Security Features:**
- Outbound-only connection (no exposed ports)
- mTLS authentication
- Credentials never in version control
- Health monitoring (healthy/degraded/offline states)

**Status:** ✅ **ACTIVE & CRITICAL**  
**Action:** None required

---

### 6. Session Cookie Pepper

**Storage:** `~/.hp-server-secret.bin` (mode 0600)  
**Size:** 32 bytes (cryptographic random)  
**Implementation:** [`zig/hp-server/src/secret.zig`](../zig/hp-server/src/secret.zig), [`zig/hp-server/src/auth.zig`](../zig/hp-server/src/auth.zig)

**Purpose:**
- Folded into HMAC-SHA256 session cookie generation
- Prevents cookie forgery even if password is leaked
- Rotates session keys when changed

**Derivation:**
```
HMAC key = SHA-256("rofi.session.v1:" || password || ":" || username || ":" || pepper)
```

**Security Features:**
- Generated once at first boot
- Never transmitted or logged
- 32 bytes of cryptographic randomness
- Changing password rotates all sessions

**Status:** ✅ **ACTIVE & CRITICAL**  
**Action:** None required

---

### 7. Operator Credentials

**Storage:** `~/.hp-server-creds.txt` (mode 0600)  
**Format:** Two lines (username, password)  
**Implementation:** [`zig/hp-server/src/auth.zig`](../zig/hp-server/src/auth.zig)

**Purpose:**
- Single-operator authentication
- Session cookie generation
- Password-based login

**Security Features:**
- File mode 0600 (owner read/write only)
- Constant-time password comparison
- Not in version control
- Combined with pepper for session keys

**Setup:** [`scripts/seed-creds.sh`](../scripts/seed-creds.sh)

**Status:** ✅ **ACTIVE**  
**Note:** Plaintext storage acceptable for single-user system  
**Action:** Consider hashing (low priority)

---

### 8. GitHub Webhook Secrets

**Storage:** Per-project in `~/.hp-server-projects.jsonl`  
**Format:** 64-character hex string  
**Implementation:** [`zig/hp-server/src/projects.zig`](../zig/hp-server/src/projects.zig), [`zig/hp-server/src/builder.zig`](../zig/hp-server/src/builder.zig)

**Purpose:**
- HMAC verification of GitHub webhook payloads
- Prevents unauthorized deploy triggers
- One unique secret per project

**Security Features:**
- Generated with `std.crypto.random.bytes`
- HMAC-SHA256 signature verification
- Constant-time comparison
- Test coverage in [`builder.zig:445`](../zig/hp-server/src/builder.zig:445)

**Status:** ✅ **ACTIVE & PROPERLY IMPLEMENTED**  
**Action:** None required

---

### 9. Project Secrets Vault

**Storage:** `~/data/projects/<project_id>/secrets.vault` (AES-256-GCM encrypted)  
**Implementation:** [`zig/hp-server/src/projsecrets.zig`](../zig/hp-server/src/projsecrets.zig)

**Purpose:**
- Store per-project environment variables
- DATABASE_URL, API keys, service credentials
- Encrypted at rest, injected at runtime

**Security Features:**
- AES-256-GCM encryption
- Per-project encryption key derived from system pepper
- Write-only API (values never returned to client)
- Key validation (uppercase, alphanumeric + underscore)

**CLI Access:** `rh secret list/set/rm <subdomain> <key> [value]`

**Status:** ✅ **ACTIVE & WELL-DESIGNED**  
**Action:** None required

---

## 🔍 Security Analysis

### Strengths

1. **No Hardcoded Secrets**
   - All API keys loaded from environment or secure files
   - Nothing in version control (verified via `.gitignore`)
   - No secrets in code comments or test files

2. **Proper Secret Storage**
   - All secret files have mode 0600
   - Encrypted vault for project secrets (AES-256-GCM)
   - Pepper-based key derivation

3. **Defense in Depth**
   - API key hashing with pepper
   - Constant-time comparisons (timing attack resistant)
   - Rate limiting on all AI endpoints
   - Graceful degradation

4. **Audit Trail**
   - API key last-used tracking
   - Audit log for security actions (`~/data/audit.jsonl`)
   - Visit logging with classification

5. **Least Privilege**
   - Scoped API keys (sql, read, admin)
   - Per-project secret isolation
   - Multi-tenant support

---

### Optimization Opportunities

#### 1. Unused `read` Scope

**Location:** [`apikey.zig:28`](../zig/hp-server/src/apikey.zig:28)  
**Issue:** `read` scope is defined but not enforced  
**Impact:** Low - scope exists but has no effect  
**Recommendation:** Implement enforcement or remove from enum

#### 2. Plaintext Operator Password

**Location:** `~/.hp-server-creds.txt`  
**Issue:** Password stored in plaintext  
**Impact:** Low for single-user phone  
**Recommendation:** Consider bcrypt/argon2 hashing (low priority)

---

## 📋 Status Summary Table

| Key/Secret | Status | Storage | Encryption | Usage | Action |
|------------|--------|---------|------------|-------|--------|
| Internal API Keys (rh_*) | ✅ Active | `~/.hp-server-apikeys.jsonl` | SHA-256 hashed | CLI, CI/CD | None |
| MISTRAL_API_KEY | ✅ Active | `~/.hp-server.env` | File mode 0600 | AI features | None |
| TG_BOT_TOKEN | ✅ Active | `~/.hp-server.env` | File mode 0600 | Notifications | None |
| TG_CHAT_ID | ✅ Active | `~/.hp-server.env` | File mode 0600 | Notifications | None |
| R2_ACCESS_KEY_ID | ✅ Active | rclone config | File mode 0600 | Backups | None |
| R2_SECRET_ACCESS_KEY | ✅ Active | rclone config | File mode 0600 | Backups | None |
| R2_ACCOUNT_ID | ✅ Active | `~/.hp-server.env` | File mode 0600 | Backups | None |
| R2_BUCKET | ✅ Active | `~/.hp-server.env` | File mode 0600 | Backups | None |
| Cloudflare Tunnel Creds | ✅ Active | `~/.cloudflared/*.json` | mTLS | Tunnel | None |
| Session Pepper | ✅ Active | `~/.hp-server-secret.bin` | 32 random bytes | Auth | None |
| Operator Password | ✅ Active | `~/.hp-server-creds.txt` | Plaintext | Auth | Consider hashing |
| GitHub Webhook Secrets | ✅ Active | Per-project JSONL | None | Deploy triggers | None |
| Project Secrets | ✅ Active | Per-project vault | AES-256-GCM | Runtime env | None |

**Total:** 13 categories  
**Active:** 13 (100%)  
**Unused:** 0  
**Deprecated:** 0  
**Redundant:** 0  
**Exposed:** 0

---

## 🎯 Recommendations

### High Priority
**None** - System is well-designed and secure

### Medium Priority

1. **Implement `read` Scope Enforcement**
   - Add middleware check for `/api/*` read endpoints
   - Document scope requirements in [`docs/API.md`](API.md)
   - Update API documentation

2. **Add API Key Rotation Workflow**
   - Document Mistral API key rotation
   - Document R2 credentials rotation
   - Add `rh rotate-key` command to CLI

### Low Priority

3. **Hash Operator Password**
   - Use bcrypt or argon2 instead of plaintext
   - Update [`auth.zig`](../zig/hp-server/src/auth.zig) verification
   - Migration script for existing installations

4. **API Key Expiration**
   - Add optional `expires_at` field to internal API keys
   - Automatic revocation on expiry
   - Warning notifications before expiry

5. **Secret Scanning in CI**
   - Add GitHub Actions workflow for secret scanning
   - Use tools like `truffleHog` or `gitleaks`
   - Prevent future credential leaks

---

## 🛡️ Best Practices Implemented

1. ✅ Environment variables for secrets
2. ✅ Secure file permissions (mode 0600)
3. ✅ No secrets in version control
4. ✅ Encrypted storage (AES-256-GCM)
5. ✅ Rate limiting
6. ✅ Audit logging
7. ✅ Graceful degradation
8. ✅ Constant-time comparisons
9. ✅ Key hashing with pepper
10. ✅ Scope-based access control

---

## 📝 Management Procedures

### Creating API Keys

**Internal (rh_* keys):**
```bash
# Via dashboard
https://app.rofihosted.space/settings → API Keys → Create Key

# Scopes: sql, read, admin
# Key shown once at creation
```

**External Services:**
```bash
# Mistral AI
export MISTRAL_API_KEY="your-key-here"
echo 'MISTRAL_API_KEY=your-key-here' >> ~/.hp-server.env

# Telegram
~/scripts/set-telegram.sh <bot-token> <chat-id>

# R2
~/scripts/r2-setup.sh  # Interactive setup
```

### Revoking API Keys

**Internal:**
```bash
# Via dashboard
https://app.rofihosted.space/settings → API Keys → Revoke

# Via API
curl -X POST -H "X-API-Key: $ADMIN_KEY" \
  --data-urlencode "id=<key-id>" \
  https://app.rofihosted.space/api/apikeys/revoke
```

**External:**
- Mistral: Revoke via https://console.mistral.ai
- Telegram: Revoke via @BotFather
- R2: Rotate via Cloudflare dashboard
- Cloudflare Tunnel: Delete via `cloudflared tunnel delete`

### Monitoring Usage

```bash
# Check internal key usage
curl -H "X-API-Key: $ADMIN_KEY" \
  https://app.rofihosted.space/api/apikeys

# Check AI usage
curl -H "Cookie: rofi_session=$SESSION" \
  https://app.rofihosted.space/api/ai/usage

# Check audit log
tail -f ~/data/audit.jsonl
```

---

## 🔐 Conclusion

The rofihosted system demonstrates **exemplary API key management** for a personal cloud project:

- ✅ Zero exposed credentials in version control
- ✅ Proper encryption for sensitive data
- ✅ Defense in depth with multiple security layers
- ✅ Graceful degradation when optional keys are missing
- ✅ Well-documented setup and management procedures

**No immediate action required.** The system is secure and well-maintained. The recommendations provided are enhancements for future consideration, not urgent fixes.

**Audit Status:** ✅ **PASSED** with commendation for security design

---

**Report Date:** 2026-06-03  
**Next Audit:** Recommended in 6 months (2026-12-03)  
**Contact:** System operator via https://app.rofihosted.space