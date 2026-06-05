//! Email verification system for signup flow.
//!
//! Generates 6-digit verification codes, sends them via SMTP, and validates
//! them. Codes expire after 15 minutes and have a max of 3 attempts.
//!
//! SMTP is optional - if not configured, verification is skipped and users
//! are activated immediately (or go to pending approval if no invite).

const std = @import("std");
const mailer = @import("email.zig");

pub const VerificationToken = struct {
    email: []const u8,
    code: []const u8, // 6-digit numeric code
    username: []const u8,
    created_at: i64,
    expires_at: i64,
    attempts: u32,

    pub fn isExpired(self: VerificationToken) bool {
        return std.time.timestamp() > self.expires_at;
    }

    pub fn canAttempt(self: VerificationToken, max_attempts: u32) bool {
        return self.attempts < max_attempts;
    }
};

pub const SmtpConfig = struct {
    enabled: bool = false,
    from_email: []const u8 = "noreply@rofihosted.space",
    from_name: []const u8 = "rofihosted",
    smtp_host: []const u8 = "",
    smtp_port: u16 = 587,
    smtp_user: []const u8 = "",
    smtp_pass: []const u8 = "",
    use_tls: bool = true,
    // Preferred transport: Brevo HTTP API. When set, we send via the API
    // (clean JSON POST, no shell, no STARTTLS guessing) and ignore the raw
    // SMTP fields below.
    api_key: ?[]const u8 = null,

    /// Configured when either the Brevo HTTP API key is present, or the raw
    /// SMTP relay is fully specified. The HTTP API takes precedence.
    pub fn isConfigured(self: SmtpConfig) bool {
        if (self.api_key) |k| {
            if (k.len > 0) return true;
        }
        return self.enabled and self.smtp_host.len > 0 and self.smtp_user.len > 0;
    }

    pub fn fromEnv(allocator: std.mem.Allocator) SmtpConfig {
        var cfg = SmtpConfig{};

        // Brevo HTTP API key (preferred). Also accepts MAIL_FROM_* shared with email.zig.
        if (std.process.getEnvVarOwned(allocator, "BREVO_API_KEY")) |v| {
            cfg.api_key = v; // Leak intentionally for static config
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "ROFI_SMTP_ENABLED")) |v| {
            defer allocator.free(v);
            cfg.enabled = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "ROFI_SMTP_HOST")) |v| {
            cfg.smtp_host = v; // Leak intentionally for static config
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "ROFI_SMTP_PORT")) |v| {
            defer allocator.free(v);
            cfg.smtp_port = std.fmt.parseInt(u16, v, 10) catch 587;
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "ROFI_SMTP_USER")) |v| {
            cfg.smtp_user = v; // Leak
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "ROFI_SMTP_PASS")) |v| {
            cfg.smtp_pass = v; // Leak
        } else |_| {}

        // Sender identity: MAIL_FROM_* (shared with email.zig) wins, then the
        // legacy ROFI_SMTP_FROM_* names.
        if (std.process.getEnvVarOwned(allocator, "MAIL_FROM_EMAIL")) |v| {
            cfg.from_email = v; // Leak
        } else |_| if (std.process.getEnvVarOwned(allocator, "ROFI_SMTP_FROM_EMAIL")) |v| {
            cfg.from_email = v; // Leak
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "MAIL_FROM_NAME")) |v| {
            cfg.from_name = v; // Leak
        } else |_| if (std.process.getEnvVarOwned(allocator, "ROFI_SMTP_FROM_NAME")) |v| {
            cfg.from_name = v; // Leak
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "ROFI_SMTP_USE_TLS")) |v| {
            defer allocator.free(v);
            cfg.use_tls = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
        } else |_| {}

        return cfg;
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    mutex: std.Thread.Mutex,
    tokens: std.StringHashMap(VerificationToken),
    smtp_config: SmtpConfig,
    expiry_minutes: u32,
    max_attempts: u32,
    last_cleanup: i64,

    pub fn init(
        allocator: std.mem.Allocator,
        smtp_config: SmtpConfig,
        expiry_minutes: u32,
        max_attempts: u32,
    ) !*Manager {
        const m = try allocator.create(Manager);
        m.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .mutex = .{},
            .tokens = std.StringHashMap(VerificationToken).init(allocator),
            .smtp_config = smtp_config,
            .expiry_minutes = expiry_minutes,
            .max_attempts = max_attempts,
            .last_cleanup = std.time.timestamp(),
        };
        return m;
    }

    /// Generate and send a verification code. Returns the code for testing/logging.
    pub fn sendVerification(
        self: *Manager,
        email: []const u8,
        username: []const u8,
    ) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.timestamp();
        const arena = self.arena.allocator();

        // Periodic cleanup of expired tokens
        if (now - self.last_cleanup > 300) {
            self.cleanupExpired();
            self.last_cleanup = now;
        }

        // Generate 6-digit code
        const code = try generateCode(arena);

        const token = VerificationToken{
            .email = try arena.dupe(u8, email),
            .code = code,
            .username = try arena.dupe(u8, username),
            .created_at = now,
            .expires_at = now + (@as(i64, self.expiry_minutes) * 60),
            .attempts = 0,
        };

        // Store token (overwrites any existing one for this email)
        const email_key = try arena.dupe(u8, email);
        try self.tokens.put(email_key, token);

        // Send email if SMTP is configured
        if (self.smtp_config.isConfigured()) {
            self.sendEmail(email, username, code) catch |e| {
                std.log.err("Failed to send verification email to {s}: {}", .{ email, e });
                // Don't fail the request - user can still use the code if we log it
            };
        } else {
            std.log.warn("SMTP not configured, verification code for {s}: {s}", .{ email, code });
        }

        return code;
    }

    /// Verify a code. Returns true if valid, false otherwise.
    pub fn verify(self: *Manager, email: []const u8, code: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const token_ptr = self.tokens.getPtr(email) orelse return error.NotFound;

        if (token_ptr.isExpired()) {
            _ = self.tokens.remove(email);
            return error.Expired;
        }

        if (!token_ptr.canAttempt(self.max_attempts)) {
            return error.TooManyAttempts;
        }

        token_ptr.attempts += 1;

        if (std.mem.eql(u8, token_ptr.code, code)) {
            // Success - remove token
            _ = self.tokens.remove(email);
            return true;
        }

        return false; // Wrong code
    }

    /// Check if a verification is pending for an email
    pub fn hasPending(self: *Manager, email: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.tokens.get(email)) |token| {
            return !token.isExpired();
        }
        return false;
    }

    /// Get token info for an email (for debugging/admin)
    pub fn getToken(self: *Manager, email: []const u8) ?VerificationToken {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tokens.get(email);
    }

    fn cleanupExpired(self: *Manager) void {
        const now = std.time.timestamp();
        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit();

        var it = self.tokens.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.expires_at < now) {
                to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |email| {
            _ = self.tokens.remove(email);
        }
    }

    fn sendEmail(self: *Manager, to: []const u8, username: []const u8, code: []const u8) !void {
        // Preferred path: Brevo HTTP API (clean JSON POST, no shell, no
        // STARTTLS guessing). Used whenever an API key is configured.
        if (self.smtp_config.api_key) |key| {
            if (key.len > 0) {
                try self.sendViaApi(key, to, username, code);
                return;
            }
        }
        try self.sendViaSmtp(to, username, code);
    }

    /// Send the verification email through the Brevo HTTP API.
    fn sendViaApi(self: *Manager, key: []const u8, to: []const u8, username: []const u8, code: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const html = try renderVerificationHtml(a, username, code, self.expiry_minutes);
        const text = try std.fmt.allocPrint(a, "Hi {s},\n\nYour rofihosted verification code is: {s}\n\n" ++
            "This code expires in {d} minutes. If you didn't request this, ignore this email.\n\n" ++
            "rofihosted\nhttps://rofihosted.space\n", .{ username, code, self.expiry_minutes });

        const ecfg = mailer.Config{
            .api_key = key,
            .from_email = self.smtp_config.from_email,
            .from_name = self.smtp_config.from_name,
        };
        const ok = mailer.send(self.allocator, ecfg, .{
            .to_email = to,
            .to_name = username,
            .subject = "Your rofihosted verification code",
            .html = html,
            .text = text,
        });
        if (!ok) return error.SmtpFailed;
    }

    /// Raw SMTP fallback. Builds the message via argv + stdin (no shell, so no
    /// injection) and selects the correct transport for the port: implicit TLS
    /// (smtps) on 465, STARTTLS (smtp + --ssl-reqd) everywhere else.
    fn sendViaSmtp(self: *Manager, to: []const u8, username: []const u8, code: []const u8) !void {
        const cfg = self.smtp_config;

        var msg = std.ArrayList(u8).init(self.allocator);
        defer msg.deinit();
        try msg.writer().print(
            "From: {s} <{s}>\r\n" ++
                "To: {s}\r\n" ++
                "Subject: Your rofihosted verification code\r\n" ++
                "MIME-Version: 1.0\r\n" ++
                "Content-Type: text/plain; charset=UTF-8\r\n" ++
                "\r\n" ++
                "Hi {s},\r\n\r\n" ++
                "Your rofihosted verification code is: {s}\r\n\r\n" ++
                "This code expires in {d} minutes.\r\n" ++
                "If you didn't request this, please ignore this email.\r\n\r\n" ++
                "rofihosted\r\nhttps://rofihosted.space\r\n",
            .{ cfg.from_name, cfg.from_email, to, username, code, self.expiry_minutes },
        );

        const use_implicit_tls = (cfg.smtp_port == 465);
        const scheme = if (use_implicit_tls) "smtps" else "smtp";
        const url = try std.fmt.allocPrint(self.allocator, "{s}://{s}:{d}", .{ scheme, cfg.smtp_host, cfg.smtp_port });
        defer self.allocator.free(url);
        const user_arg = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ cfg.smtp_user, cfg.smtp_pass });
        defer self.allocator.free(user_arg);

        var argv = std.ArrayList([]const u8).init(self.allocator);
        defer argv.deinit();
        try argv.appendSlice(&[_][]const u8{
            "curl", "-sS", "--max-time", "15", "--url", url,
        });
        if (!use_implicit_tls and cfg.use_tls) try argv.append("--ssl-reqd");
        try argv.appendSlice(&[_][]const u8{
            "--mail-from",   cfg.from_email,
            "--mail-rcpt",   to,
            "--user",        user_arg,
            "--upload-file", "-",
        });

        var child = std.process.Child.init(argv.items, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        if (child.stdin) |stdin| {
            stdin.writeAll(msg.items) catch {};
            stdin.close();
            child.stdin = null;
        }
        const term = try child.wait();
        if (term != .Exited or term.Exited != 0) {
            return error.SmtpFailed;
        }
    }

    pub fn count(self: *Manager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tokens.count();
    }

    /// Free owned resources. Does not destroy the struct itself; the caller
    /// that allocated it (via init -> allocator.create) owns that memory.
    pub fn deinit(self: *Manager) void {
        self.tokens.deinit();
        self.arena.deinit();
    }
};

/// Render the HTML verification email. The username is HTML-escaped; the code
/// is always 6 numeric digits from generateCode, so it needs no escaping.
/// Style mirrors the Anthropic-inspired palette used across the dashboard.
fn renderVerificationHtml(allocator: std.mem.Allocator, username: []const u8, code: []const u8, expiry_minutes: u32) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();
    try w.writeAll(
        \\<!DOCTYPE html><html><body style="margin:0;background:#f5f4f0;font-family:-apple-system,'Segoe UI',Roboto,sans-serif;padding:40px 16px;">
        \\<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center">
        \\<table role="presentation" width="460" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #e5e3dd;">
        \\<tr><td style="background:#141413;padding:24px 32px;"><span style="color:#ffffff;font-size:17px;font-weight:600;letter-spacing:-0.01em;">rofihosted</span></td></tr>
        \\<tr><td style="padding:32px 32px 8px;"><h1 style="margin:0 0 10px;font-size:20px;color:#141413;font-weight:600;">Verify your email</h1>
        \\<p style="margin:0;font-size:15px;line-height:1.6;color:#5c5b57;">Hi 
    );
    try writeHtmlEscaped(w, username);
    try w.writeAll(
        \\, enter this code to finish creating your account.</p></td></tr>
        \\<tr><td style="padding:24px 32px;"><div style="background:#f5f4f0;border:1px solid #e5e3dd;border-radius:10px;padding:20px;text-align:center;">
        \\<div style="font-family:'SF Mono',ui-monospace,Menlo,monospace;font-size:34px;font-weight:700;letter-spacing:8px;color:#141413;">
    );
    try w.writeAll(code);
    try w.writeAll(
        \\</div></div></td></tr>
        \\<tr><td style="padding:0 32px 32px;"><p style="margin:0;font-size:13px;line-height:1.6;color:#8a8880;">This code expires in 
    );
    try w.print("{d}", .{expiry_minutes});
    try w.writeAll(
        \\ minutes. If you didn't request this, you can safely ignore this email.</p></td></tr>
        \\<tr><td style="border-top:1px solid #e5e3dd;padding:18px 32px;"><span style="font-size:12px;color:#8a8880;">rofihosted.space</span></td></tr>
        \\</table></td></tr></table></body></html>
    );
    return buf.toOwnedSlice();
}

fn writeHtmlEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(c),
    };
}

fn generateCode(allocator: std.mem.Allocator) ![]const u8 {
    // Generate a 6-digit numeric code
    var bytes: [3]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    // Convert to 6-digit number (000000-999999)
    const num = (@as(u32, bytes[0]) << 16) | (@as(u32, bytes[1]) << 8) | @as(u32, bytes[2]);
    const code_num = num % 1_000_000;

    return std.fmt.allocPrint(allocator, "{d:0>6}", .{code_num});
}

test "generateCode" {
    const allocator = std.testing.allocator;
    const code = try generateCode(allocator);
    defer allocator.free(code);

    try std.testing.expectEqual(@as(usize, 6), code.len);
    for (code) |c| {
        try std.testing.expect(c >= '0' and c <= '9');
    }
}

test "verification flow" {
    const allocator = std.testing.allocator;
    const smtp_config = SmtpConfig{ .enabled = false };
    const mgr = try Manager.init(allocator, smtp_config, 15, 3);
    defer {
        mgr.deinit();
        allocator.destroy(mgr);
    }

    const email = "test@example.com";
    const username = "testuser";

    // Send verification
    const code = try mgr.sendVerification(email, username);
    try std.testing.expect(code.len == 6);

    // Verify with correct code
    const result = try mgr.verify(email, code);
    try std.testing.expect(result);

    // Token should be removed after successful verification
    try std.testing.expect(!mgr.hasPending(email));
}

test "verification expiry" {
    const allocator = std.testing.allocator;
    const smtp_config = SmtpConfig{ .enabled = false };
    const mgr = try Manager.init(allocator, smtp_config, 0, 3); // 0 minutes = instant expiry
    defer {
        mgr.deinit();
        allocator.destroy(mgr);
    }

    const email = "test@example.com";
    const code = try mgr.sendVerification(email, "testuser");

    // timestamp() has 1-second resolution and expires_at == now (0 min expiry),
    // so we must sleep past the next whole-second boundary to guarantee the
    // token is seen as expired (sleeping >1s advances timestamp() by >=1).
    std.time.sleep(1100 * std.time.ns_per_ms);

    // Should fail with Expired
    const result = mgr.verify(email, code);
    try std.testing.expectError(error.Expired, result);
}

test "max attempts" {
    const allocator = std.testing.allocator;
    const smtp_config = SmtpConfig{ .enabled = false };
    const mgr = try Manager.init(allocator, smtp_config, 15, 3);
    defer {
        mgr.deinit();
        allocator.destroy(mgr);
    }

    const email = "test@example.com";
    const real = try mgr.sendVerification(email, "testuser");

    // Pick a guess guaranteed to differ from the real code so verify never
    // succeeds early (the code is random, so a fixed guess could collide).
    const wrong: []const u8 = if (std.mem.eql(u8, real, "000000")) "999999" else "000000";

    // Three wrong attempts exhaust the allowance (max_attempts = 3).
    _ = try mgr.verify(email, wrong);
    _ = try mgr.verify(email, wrong);
    _ = try mgr.verify(email, wrong);

    // 4th attempt should fail with TooManyAttempts.
    const result = mgr.verify(email, wrong);
    try std.testing.expectError(error.TooManyAttempts, result);
}
