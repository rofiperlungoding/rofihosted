# API Key Inventory - Quick Reference

**Last Updated:** 2026-06-03  
**System:** rofihosted.space  
**Status:** All keys active and necessary

---

## 🔑 Active API Keys & Secrets

### External Service Keys

| Service | Key Name | Storage Location | Purpose | Optional |
|---------|----------|------------------|---------|----------|
| Mistral AI | `MISTRAL_API_KEY` | `~/.hp-server.env` | AI features (8 endpoints) | Yes |
| Telegram | `TG_BOT_TOKEN` | `~/.hp-server.env` | Boot/power notifications | Yes |
| Telegram | `TG_CHAT_ID` | `~/.hp-server.env` | Notification target | Yes |
| Cloudflare R2 | `R2_ACCESS_KEY_ID` | `~/.config/rclone/rclone.conf` | Backup storage | No |
| Cloudflare R2 | `R2_SECRET_ACCESS_KEY` | `~/.config/rclone/rclone.conf` | Backup storage | No |
| Cloudflare R2 | `R2_ACCOUNT_ID` | `~/.hp-server.env` | Backup storage | No |
| Cloudflare R2 | `R2_BUCKET` | `~/.hp-server.env` | Backup storage | No |
| Cloudflare Tunnel | Tunnel credentials | `~/.cloudflared/*.json` | Internet exposure | No |

### Internal System Secrets

| Secret | Storage Location | Purpose | Format |
|--------|------------------|---------|--------|
| User API Keys | `~/.hp-server-apikeys.jsonl` | CLI/CI access | `rh_<48 hex>` (SHA-256 hashed) |
| Session Pepper | `~/.hp-server-secret.bin` | Cookie HMAC key | 32 random bytes |
| Operator Credentials | `~/.hp-server-creds.txt` | Login auth | username + password (plaintext) |
| Webhook Secrets | `~/.hp-server-projects.jsonl` | GitHub deploy triggers | 64 hex chars per project |
| Project Secrets | `~/data/projects/*/secrets.vault` | Per-project env vars | AES-256-GCM encrypted |

---

## 📊 Key Statistics

- **Total Keys/Secrets:** 13 categories
- **External Services:** 4 (Mistral, Telegram, R2, Cloudflare)
- **Internal Secrets:** 5 types
- **Optional Keys:** 3 (Mistral, Telegram x2)
- **Critical Keys:** 10 (required for operation)
- **Unused Keys:** 0
- **Deprecated Keys:** 0

---

## 🔐 Security Status

| Security Measure | Status |
|------------------|--------|
| No secrets in version control | ✅ Verified |
| File permissions (mode 0600) | ✅ All secret files |
| Encryption at rest | ✅ Project secrets (AES-256-GCM) |
| Key hashing | ✅ User API keys (SHA-256 + pepper) |
| Rate limiting | ✅ All AI endpoints |
| Audit logging | ✅ Security actions logged |
| Constant-time comparisons | ✅ Auth + API keys |
| Graceful degradation | ✅ Optional keys |

---

## 🎯 Quick Actions

### View API Keys
```bash
# Internal user keys (via dashboard)
https://app.rofihosted.space/settings → API Keys

# Internal user keys (via API)
curl -H "X-API-Key: $ADMIN_KEY" \
  https://app.rofihosted.space/api/apikeys
```

### Create API Key
```bash
# Via dashboard (recommended)
https://app.rofihosted.space/settings → API Keys → Create Key

# Choose scope: sql, read, or admin
# Key shown once at creation - save it!
```

### Revoke API Key
```bash
# Via dashboard
https://app.rofihosted.space/settings → API Keys → Revoke

# Via API
curl -X POST -H "X-API-Key: $ADMIN_KEY" \
  --data-urlencode "id=<key-id>" \
  https://app.rofihosted.space/api/apikeys/revoke
```

### Check AI Usage
```bash
curl -H "Cookie: rofi_session=$SESSION" \
  https://app.rofihosted.space/api/ai/usage
```

### Monitor Audit Log
```bash
tail -f ~/data/audit.jsonl
```

---

## 📝 Key Rotation Schedule

| Key Type | Rotation Frequency | Last Rotated | Next Due |
|----------|-------------------|--------------|----------|
| User API Keys | On demand | N/A | As needed |
| Mistral API Key | Annually | N/A | 2027-06-03 |
| Telegram Bot Token | On compromise | N/A | As needed |
| R2 Credentials | Annually | N/A | 2027-06-03 |
| Cloudflare Tunnel | On compromise | N/A | As needed |
| Session Pepper | Never (unless leaked) | N/A | N/A |
| Operator Password | Every 90 days | N/A | 2026-09-01 |

---

## 🚨 Emergency Procedures

### If API Key is Compromised

1. **Immediate Actions:**
   ```bash
   # Revoke internal key
   curl -X POST -H "X-API-Key: $ADMIN_KEY" \
     --data-urlencode "id=<compromised-key-id>" \
     https://app.rofihosted.space/api/apikeys/revoke
   
   # Check audit log for unauthorized usage
   grep "<compromised-key-id>" ~/data/audit.jsonl
   ```

2. **External Service Keys:**
   - Mistral: Revoke at https://console.mistral.ai
   - Telegram: Revoke via @BotFather
   - R2: Rotate via Cloudflare dashboard
   - Cloudflare Tunnel: Delete and recreate tunnel

3. **Post-Incident:**
   - Review audit logs
   - Update documentation
   - Notify affected parties
   - Schedule security review

### If Operator Password is Compromised

1. **Change password immediately:**
   ```bash
   # Via SSH
   echo "new-username" > ~/.hp-server-creds.txt
   echo "new-password" >> ~/.hp-server-creds.txt
   chmod 600 ~/.hp-server-creds.txt
   
   # Restart hp-server
   pkill hp-server
   # Watchdog will restart it
   ```

2. **All existing sessions are invalidated automatically** (pepper-based HMAC)

3. **Revoke all API keys and reissue:**
   ```bash
   # Via dashboard
   https://app.rofihosted.space/settings → API Keys → Revoke All
   ```

---

## 📚 Related Documentation

- [API Key Audit Report](API-KEY-AUDIT.md) - Comprehensive security analysis
- [Security Model](SECURITY.md) - Overall security architecture
- [API Reference](API.md) - API endpoint documentation
- [Operations Guide](OPERATIONS.md) - System administration
- [CLI Documentation](../cli/README.md) - `rh` command reference

---

## ✅ Audit Status

**Last Audit:** 2026-06-03  
**Next Audit:** 2026-12-03 (6 months)  
**Status:** ✅ PASSED  
**Issues Found:** 0 critical, 0 warnings  
**Recommendations:** 5 optional enhancements

---

**Maintained by:** System operator  
**Contact:** https://app.rofihosted.space  
**Version:** 1.0