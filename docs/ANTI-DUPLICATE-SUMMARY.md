# Anti-duplicate account system: executive summary

## Objective

Prevent duplicate account creation on rofihosted using three-layer protection: email verification, IP rate limiting (max 3 per 24h), and device fingerprinting (max 2 per device).

## Expected impact

- Reduce duplicate accounts by 90% or more
- Block automated bot and script abuse
- Maintain user-friendly experience (less than 5% legitimate users blocked)
- Email verification completion rate greater than 80%

## Core components

### Email verification system

**File**: `zig/hp-server/src/emailverify.zig`

- Generate 6-digit verification codes
- Send via SMTP (configurable)
- 15-minute expiry window
- Maximum 3 attempts per code
- Resend with rate limiting

### Device fingerprinting

**File**: `zig/hp-server/src/fingerprint.zig`

- Collect browser fingerprint (canvas, WebGL, audio, etc.)
- Hash with SHA256
- Track signup count per device
- Maximum 2 signups per device
- Persist to `~/.hp-server-fingerprints.jsonl`

### Signup rate limiter

**File**: Extension of `zig/hp-server/src/ratelimit.zig`

- Track signup attempts per IP
- 24-hour window
- Maximum 3 signups per IP
- Automatic cleanup of old entries

### User schema updates

**File**: `zig/hp-server/src/users.zig`

New fields: `email_verified`, `device_fingerprint`, `signup_ip`, `verification_token`, `verification_attempts`

Backward compatible with existing data.

## Signup flow

### Without invite code

```
1. User submits form with device fingerprint
2. Check IP rate limit (3 per 24h)
3. Check device fingerprint (2 max)
4. Check username and email uniqueness
5. Create user (status: pending_verification)
6. Generate and send verification code
7. User inputs code
8. Verify and activate account
9. Redirect to dashboard
```

### With invite code

```
1. User submits form with device fingerprint
2. Check IP rate limit (3 per 24h)
3. Check device fingerprint (2 max)
4. Validate invite code
5. Create user (status: active)
6. Skip email verification
7. Redirect to dashboard
```

## API changes

### Modified endpoint

**POST `/signup/submit`**
- Accept new field: `device_fingerprint`
- Return: `verification_required: true` if verification needed

### New endpoints

- **POST `/signup/verify-email`** - Verify email with code
- **POST `/signup/resend-verification`** - Resend verification code
- **GET `/signup/verification`** - Verification code input page

## Frontend changes

### signup.html

- Add JavaScript to collect device fingerprint
- Capture: user agent, screen, timezone, canvas, WebGL, audio
- Hash all data before sending to backend

### signup-verification.html (new)

- 6-digit code input
- Auto-submit on completion
- Resend button with cooldown
- Countdown timer for expiry

## Configuration

### Environment variables (new)

```bash
# Email
ROFI_SMTP_ENABLED=true
ROFI_SMTP_HOST=smtp.gmail.com
ROFI_SMTP_PORT=587
ROFI_SMTP_USER=noreply@rofihosted.space
ROFI_SMTP_PASS=your-password

# Limits
ROFI_SIGNUP_MAX_PER_IP=3
ROFI_SIGNUP_WINDOW_HOURS=24
ROFI_MAX_SIGNUPS_PER_DEVICE=2

# Verification
ROFI_VERIFICATION_EXPIRY_MINUTES=15
ROFI_VERIFICATION_MAX_ATTEMPTS=3
```

### Fallback behavior

If SMTP not configured:
- Log warning
- Skip email verification
- Still enforce IP and device limits
- User becomes active immediately (or pending approval)

## Security features

### Multi-layer protection

1. Input validation
2. IP rate limiting
3. Device fingerprinting
4. Email verification
5. Username and email uniqueness
6. Invite code validation
7. Admin approval (optional)

### Privacy considerations

- Fingerprint hashed before storage
- Raw fingerprint data not exposed
- GDPR compliant (minimal data, purpose-limited)
- User can request reset via admin

## Monitoring

### Audit events (new)

- `email_verification_sent`
- `email_verification_success`
- `email_verification_failed`
- `signup_blocked_ip_limit`
- `signup_blocked_device_limit`
- `duplicate_device_detected`

### Metrics to track

- Verification success rate
- Blocked signups by reason
- Average time to verify
- Duplicate device attempts

## Implementation phases

### Phase 1: Foundation (complete)

- [x] Analyze existing code
- [x] Design architecture
- [x] Create plan documents

### Phase 2: Backend core

- [ ] Implement `fingerprint.zig`
- [ ] Implement `emailverify.zig`
- [ ] Extend `ratelimit.zig`
- [ ] Update `users.zig` schema

### Phase 3: Integration

- [ ] Modify signup flow in `main.zig`
- [ ] Add verification endpoints
- [ ] Wire up all components

### Phase 4: Frontend

- [ ] Add fingerprinting script
- [ ] Create verification page
- [ ] Update signup form

### Phase 5: Configuration

- [ ] Add SMTP config
- [ ] Environment variables
- [ ] Fallback handling

### Phase 6: Testing and documentation

- [ ] Write tests
- [ ] User documentation
- [ ] API documentation

## Files to create or modify

### New files (6)

1. `zig/hp-server/src/emailverify.zig` - Email verification system
2. `zig/hp-server/src/fingerprint.zig` - Device fingerprinting
3. `zig/hp-server/src/templates/signup-verification.html` - Verification page
4. `docs/ANTI-DUPLICATE-PLAN.md` - Detailed plan
5. `docs/ANTI-DUPLICATE-DIAGRAMS.md` - Flow diagrams
6. `docs/ANTI-DUPLICATE-SUMMARY.md` - This file

### Modified files (4)

1. `zig/hp-server/src/ratelimit.zig` - Add signup limiter
2. `zig/hp-server/src/users.zig` - Add new fields
3. `zig/hp-server/src/main.zig` - Update signup flow
4. `zig/hp-server/src/templates/signup.html` - Add fingerprinting

### New storage files (1)

1. `~/.hp-server-fingerprints.jsonl` - Fingerprint database

## Breaking changes

**None** - Fully backward compatible.

- Existing users unaffected
- Existing signup flow continues to function
- New features optional (fallback if SMTP not configured)

## Success criteria

### Must have

- Block duplicate signups from same IP (3 per 24h)
- Block duplicate signups from same device (2 max)
- Email verification working (if SMTP configured)
- Backward compatible with existing system

### Nice to have

- Admin dashboard for viewing blocked attempts
- Whitelist and blacklist management
- Detailed analytics

### Performance

- Signup latency less than 500ms (excluding email send)
- Verification check less than 100ms
- Memory overhead less than 10MB for 1000 users

## Cost estimate

### Development time

- Backend: 8-12 hours
- Frontend: 4-6 hours
- Testing: 4-6 hours
- Documentation: 2-3 hours
- **Total**: 18-27 hours

### Infrastructure

- No additional cost (pure Zig, no external services required)
- SMTP: Use existing email service (Gmail, SendGrid, etc.)
- Storage: Minimal (approximately 1KB per user for fingerprints)

## Rollback plan

If issues occur:

1. Set `ROFI_SMTP_ENABLED=false` - Disable email verification
2. Set `ROFI_SIGNUP_MAX_PER_IP=999` - Disable IP limit
3. Set `ROFI_MAX_SIGNUPS_PER_DEVICE=999` - Disable device limit
4. Revert code changes via git
5. Restart server

## Documentation

### For users

- Signup guide with email verification
- FAQ about verification codes
- Troubleshooting common issues

### For admins

- Configuration guide
- Monitoring guide
- Whitelist and blacklist management
- User limit reset procedures

### For developers

- Architecture overview
- API documentation
- Testing guide
- Deployment guide

## Next steps

1. **Review and approve** - Review this plan and provide feedback
2. **Start implementation** - Begin Phase 2 (Backend core)
3. **Iterative development** - Build, test, iterate
4. **Deploy and monitor** - Deploy to production and monitor metrics

## Questions for discussion

1. **SMTP provider** - Gmail, SendGrid, or other?
2. **Rate limits** - Is 3 signups per 24h per IP strict enough?
3. **Device limit** - Is 2 signups per device reasonable?
4. **Verification expiry** - Is 15 minutes sufficient or too short?
5. **Privacy** - Any concerns about fingerprinting?

---

**Status**: Planning complete - Awaiting approval  
**Estimated completion**: 2-3 working days after approval  
**Risk level**: Low (backward compatible, well-tested approach)