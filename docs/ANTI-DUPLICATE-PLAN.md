# Anti-duplicate account system: technical plan

## Overview

Implementation plan for three-layer account duplication prevention: email verification, IP rate limiting, and device fingerprinting. Designed to prevent abuse while maintaining user experience for legitimate signups.

## Goals

- Prevent single user from creating multiple accounts with different credentials
- Block automated bot and script-based signup abuse
- Prevent signup spam from same IP address
- Maintain user-friendly experience for legitimate users

## Architecture

### Email verification system

**File**: `zig/hp-server/src/emailverify.zig`

Components:
- Token generator (6-digit numeric codes, 15-minute expiry)
- In-memory storage for pending verifications
- SMTP client using external `curl` command
- Automatic cleanup of expired tokens

Flow:
```
User signup → Generate verification token → Send email → 
User clicks link or inputs code → Verify token → Activate account
```

Data structures:
```zig
pub const VerificationToken = struct {
    email: []const u8,
    code: []const u8,        // 6-digit code
    username: []const u8,     // reference
    created_at: i64,
    expires_at: i64,
    attempts: u32,            // max 3 attempts
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    tokens: std.StringHashMap(VerificationToken),
    smtp_config: SmtpConfig,
};
```

SMTP configuration:
```zig
pub const SmtpConfig = struct {
    enabled: bool,
    from_email: []const u8,
    from_name: []const u8,
    smtp_host: []const u8,
    smtp_port: u16,
    smtp_user: []const u8,
    smtp_pass: []const u8,
    use_tls: bool,
};
```

### Device fingerprinting

**File**: `zig/hp-server/src/fingerprint.zig`

Components:
- Hash generator from browser fingerprint data
- Storage for tracking fingerprints per user
- Detector for previously used fingerprints

Browser fingerprint data (collected client-side):
- User Agent
- Screen resolution
- Timezone
- Language
- Canvas fingerprint
- WebGL fingerprint
- Audio context fingerprint
- Installed fonts (via canvas)
- Hardware concurrency (CPU cores)
- Device memory
- Platform

Data structures:
```zig
pub const Fingerprint = struct {
    hash: []const u8,           // SHA256 hash of combined data
    user_agent: []const u8,
    screen_resolution: []const u8,
    timezone: []const u8,
    canvas_hash: []const u8,
    webgl_hash: []const u8,
    first_seen: i64,
    last_seen: i64,
    signup_count: u32,          // number of signups with this fingerprint
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    fingerprints: std.StringHashMap(Fingerprint),
    max_signups_per_device: u32,  // default: 2
};
```

Persisted storage: `~/.hp-server-fingerprints.jsonl`

### Signup rate limiting

**File**: Extension of `zig/hp-server/src/ratelimit.zig`

Components:
- Dedicated limiter for signup (stricter than general rate limit)
- Per-IP tracking with 24-hour window
- Configurable limits

Data structures:
```zig
pub const SignupLimiter = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    attempts: std.StringHashMap(SignupAttempt),
    max_per_ip_per_day: u32,    // default: 3
    window_seconds: i64,         // default: 86400 (24h)
};

const SignupAttempt = struct {
    ip: []const u8,
    count: u32,
    first_attempt: i64,
    last_attempt: i64,
    usernames: std.ArrayList([]const u8),  // for audit
};
```

### User schema updates

**File**: `zig/hp-server/src/users.zig`

New fields:
```zig
pub const User = struct {
    // ... existing fields ...
    
    // Email verification
    email_verified: bool = false,
    email_verified_at: i64 = 0,
    verification_token: ?[]const u8 = null,
    verification_sent_at: i64 = 0,
    
    // Device fingerprinting
    device_fingerprint: ?[]const u8 = null,
    signup_ip: ?[]const u8 = null,
    
    // Anti-abuse tracking
    verification_attempts: u32 = 0,
};
```

Persisted storage: Extended `~/.hp-server-users.jsonl`

## Signup flow

### Current flow
```
1. User submits form
2. Validate input
3. Check username and email uniqueness
4. Check invite code (optional)
5. Create user (active or pending)
6. Issue session cookie
7. Redirect to dashboard or pending page
```

### New flow
```
1. User submits form with device fingerprint
2. Validate input
3. CHECK: IP rate limit (max 3 signups per 24h per IP)
   REJECT: "Too many signup attempts from this IP"
4. CHECK: Device fingerprint (max 2 signups per device)
   REJECT: "This device has reached signup limit"
5. Check username and email uniqueness
6. Check invite code (optional)
7. Create user (status = pending_verification)
8. Generate verification token (6-digit code)
9. Send verification email
10. Store fingerprint and IP
11. Redirect to verification page
12. User inputs verification code
13. Verify code and activate account
14. Issue session cookie
15. Redirect to dashboard
```

### Special cases

**With invite code**:
- Skip email verification (instant active)
- Still track fingerprint and IP for audit
- Still enforce rate limits

**Admin approval**:
- Email verification still required
- Status: pending_verification → pending_approval → active
- Admin approves in dashboard

## API endpoints

### Modified endpoint

#### POST `/signup/submit`

Changes:
- Accept `device_fingerprint` field
- Return `verification_required: true` if email verification needed
- Return verification instructions

Response when verification required:
```json
{
  "ok": true,
  "verification_required": true,
  "email": "user@example.com",
  "message": "Check your email for verification code"
}
```

### New endpoints

#### POST `/signup/verify-email`

Request:
```json
{
  "email": "user@example.com",
  "code": "123456"
}
```

Response:
```json
{
  "ok": true,
  "status": "active",
  "message": "Email verified successfully"
}
```

#### POST `/signup/resend-verification`

Request:
```json
{
  "email": "user@example.com"
}
```

Response:
```json
{
  "ok": true,
  "message": "Verification code sent"
}
```

Rate limit: Max 3 resends per email per hour

## Frontend changes

### signup.html updates

Add device fingerprinting script:
```javascript
// Collect browser fingerprint
function collectFingerprint() {
  const data = {
    userAgent: navigator.userAgent,
    language: navigator.language,
    languages: navigator.languages.join(','),
    platform: navigator.platform,
    hardwareConcurrency: navigator.hardwareConcurrency || 0,
    deviceMemory: navigator.deviceMemory || 0,
    screenResolution: screen.width + 'x' + screen.height,
    screenDepth: screen.colorDepth,
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    timezoneOffset: new Date().getTimezoneOffset(),
    canvas: getCanvasFingerprint(),
    webgl: getWebGLFingerprint(),
    audio: getAudioFingerprint(),
  };
  
  // Hash all data
  return hashFingerprint(JSON.stringify(data));
}
```

Add to form submission:
```javascript
fd.set('device_fingerprint', collectFingerprint());
```

### New page: signup-verify.html

Purpose: Page for inputting verification code

Features:
- 6-digit code input
- Resend button with cooldown
- Auto-submit on 6 digits
- Error handling
- Countdown timer for expiry

## Configuration

### Environment variables

```bash
# Email verification
ROFI_SMTP_ENABLED=true
ROFI_SMTP_HOST=smtp.gmail.com
ROFI_SMTP_PORT=587
ROFI_SMTP_USER=noreply@rofihosted.space
ROFI_SMTP_PASS=your-app-password
ROFI_SMTP_FROM_EMAIL=noreply@rofihosted.space
ROFI_SMTP_FROM_NAME=rofihosted
ROFI_SMTP_USE_TLS=true

# Rate limiting
ROFI_SIGNUP_MAX_PER_IP=3
ROFI_SIGNUP_WINDOW_HOURS=24

# Device fingerprinting
ROFI_MAX_SIGNUPS_PER_DEVICE=2

# Verification
ROFI_VERIFICATION_CODE_LENGTH=6
ROFI_VERIFICATION_EXPIRY_MINUTES=15
ROFI_VERIFICATION_MAX_ATTEMPTS=3
```

### Fallback behavior

If SMTP not configured:
- Log warning
- Skip email verification
- Still enforce IP and fingerprint limits
- User becomes active immediately (or pending approval if no invite)

## Monitoring and audit

### Audit events

```zig
// Email verification
"email_verification_sent"
"email_verification_success"
"email_verification_failed"
"email_verification_expired"

// Rate limiting
"signup_blocked_ip_limit"
"signup_blocked_device_limit"

// Fingerprinting
"duplicate_device_detected"
"suspicious_signup_pattern"
```

### Metrics to track

- Verification success rate
- Average time to verify
- Blocked signups by reason (IP, device, other)
- Duplicate device attempts
- Email bounce rate

## Testing strategy

### Unit tests

**Email verification**:
- Token generation uniqueness
- Token expiry
- Max attempts enforcement
- Code validation

**Fingerprinting**:
- Hash consistency
- Duplicate detection
- Max signups per device

**Rate limiting**:
- Window sliding
- Count accuracy
- Cleanup of old entries

### Integration tests

**Happy path**:
- Signup → Receive email → Verify → Login

**Rate limit**:
- 3 signups from same IP → 4th blocked

**Device limit**:
- 2 signups from same device → 3rd blocked

**Expired token**:
- Wait 15 minutes → Verify fails → Resend works

**With invite**:
- Signup with invite → Skip verification → Instant active

## Implementation order

1. Phase 1: Foundation (complete)
   - Analyze existing code
   - Design architecture
   - Create plan document

2. Phase 2: Backend core
   - Implement fingerprint.zig
   - Implement emailverify.zig
   - Extend ratelimit.zig
   - Update users.zig schema

3. Phase 3: Integration
   - Modify signup flow in main.zig
   - Add verification endpoints
   - Wire up all components

4. Phase 4: Frontend
   - Add fingerprinting script
   - Create verification page
   - Update signup form

5. Phase 5: Configuration
   - Add SMTP config
   - Environment variables
   - Fallback handling

6. Phase 6: Testing and documentation
   - Write tests
   - Create user documentation
   - Update API docs

## Security considerations

### Email verification
- Use cryptographically secure random for codes
- Rate limit verification attempts
- Expire tokens after 15 minutes
- Log all verification attempts

### Fingerprinting
- Hash fingerprints before storage (privacy)
- Do not expose raw fingerprint data
- Allow legitimate users to reset (admin action)
- Consider privacy implications (GDPR)

### Rate limiting
- Use IP from X-Forwarded-For (behind proxy)
- Validate IP format
- Consider VPN and proxy users
- Allow admin override

### General
- All new endpoints need CSRF protection
- Audit all blocked attempts
- Monitor for abuse patterns
- Implement gradual backoff for repeated failures

## User communication

### Verification email template

```
Subject: Verify your rofihosted account

Hi there,

Thanks for signing up for rofihosted! 

Your verification code is: 123456

This code will expire in 15 minutes.

If you didn't request this, please ignore this email.

---
rofihosted
https://rofihosted.space
```

### Error messages

- **IP rate limit**: "Too many signup attempts from your network. Please try again in 24 hours."
- **Device limit**: "This device has reached the signup limit. Please contact support if you need assistance."
- **Invalid code**: "Invalid verification code. Please check and try again."
- **Expired code**: "Verification code expired. Click 'Resend' to get a new code."
- **Max attempts**: "Too many failed attempts. Please request a new verification code."

## Success metrics

- Reduce duplicate accounts by 90% or more
- Block bot signups effectively
- Maintain user experience: less than 5% legitimate users blocked
- Verification completion rate: greater than 80%
- Average verification time: less than 5 minutes

## Future enhancements

1. Phone verification (optional alternative to email)
2. CAPTCHA integration (for high-risk IPs)
3. Machine learning (detect suspicious patterns)
4. Reputation system (trust score per IP or device)
5. Admin dashboard (view blocked attempts, override limits)
6. Whitelist and blacklist (manual IP or device management)