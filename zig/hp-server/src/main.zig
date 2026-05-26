const std = @import("std");
const httpz = @import("httpz");
const store = @import("store.zig");
const sysmon = @import("sysmon.zig");
const hostinfo = @import("hostinfo.zig");
const uptime = @import("uptime.zig");
const auth = @import("auth.zig");
const files = @import("files.zig");
const ratelimit = @import("ratelimit.zig");
const badge = @import("badge.zig");
const telegram = @import("telegram.zig");
const security = @import("security.zig");
const events = @import("events.zig");

const visits_path = "/data/data/com.termux/files/home/data/visits.jsonl";
const uptime_path = "/data/data/com.termux/files/home/data/uptime.jsonl";

const App = struct {
    allocator: std.mem.Allocator,
    started_at: i64,
    store_mutex: *std.Thread.Mutex,
    auth_cfg: *auth.Config,
    tg_cfg: telegram.Config,
    rate_limiter: *ratelimit.Limiter,
    blocklist: *security.Blocklist,
    autoban: *security.AutoBan,
    login_tracker: *security.LoginTracker,
    bus: *events.Bus,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.fs.makeDirAbsolute("/data/data/com.termux/files/home/data") catch {};

    var store_mutex = std.Thread.Mutex{};
    var rl = ratelimit.Limiter.init(allocator, 1.0, 60.0);
    const tg_cfg = telegram.Config.fromEnv(allocator);
    const auth_cfg = try auth.Config.init(allocator);
    const blocklist = try security.Blocklist.init(allocator);
    const autoban = try security.AutoBan.init(allocator, blocklist);
    const login_tracker = try security.LoginTracker.init(allocator, blocklist);
    const bus = try events.Bus.init(allocator);

    var app = App{
        .allocator = allocator,
        .started_at = std.time.timestamp(),
        .store_mutex = &store_mutex,
        .auth_cfg = auth_cfg,
        .tg_cfg = tg_cfg,
        .rate_limiter = &rl,
        .blocklist = blocklist,
        .autoban = autoban,
        .login_tracker = login_tracker,
        .bus = bus,
    };

    // Heartbeat thread keeps SSE clients alive
    const hb = try std.Thread.spawn(.{}, events.heartbeatLoop, .{bus});
    hb.detach();

    // Periodic stats tick (every 2s) so frontend dashboards animate live
    const stats_tick = try std.Thread.spawn(.{}, statsTickLoop, .{ bus, app.started_at });
    stats_tick.detach();

    const checker = try std.Thread.spawn(.{}, uptime.checkerLoop, .{ allocator, uptime_path, &store_mutex, tg_cfg, bus });
    checker.detach();

    const rotator = try std.Thread.spawn(.{}, store.rotatorLoop, .{ allocator, visits_path, uptime_path, &store_mutex });
    rotator.detach();

    var server = try httpz.Server(*App).init(allocator, .{
        .address = "127.0.0.1",
        .port = 8080,
        .request = .{
            .max_body_size = 1024 * 1024,
            .max_form_count = 8,
        },
    }, &app);
    defer server.deinit();

    var router = try server.router(.{});
    router.get("/*", hostRouter, .{});
    router.post("/*", hostRouter, .{});

    std.log.info("hp-server listening on http://127.0.0.1:8080", .{});
    std.log.info("auth user='{s}', telegram={s}", .{ app.auth_cfg.user, if (tg_cfg.enabled()) "ENABLED" else "disabled" });
    try server.listen();
}

fn hostRouter(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    // Apply security headers to every response
    security.applyHeaders(res);

    const host_full = req.header("host") orelse "rofihosted.space";
    const host = if (std.mem.indexOfScalar(u8, host_full, ':')) |i| host_full[0..i] else host_full;
    const path = req.url.path;
    const ip = req.header("cf-connecting-ip") orelse req.header("x-forwarded-for") orelse "local";
    const ua = req.header("user-agent") orelse "";
    const method = @tagName(req.method);
    const is_local = std.mem.eql(u8, ip, "local");

    // Classify with full request signals
    const is_authed = auth.isAuthenticated(app.auth_cfg, app.allocator, req);
    const blocklisted = !is_local and app.blocklist.isBlocked(ip);

    const cls = security.classify(.{
        .ua = ua,
        .path = path,
        .accept_language = req.header("accept-language"),
        .sec_fetch_site = req.header("sec-fetch-site"),
        .sec_fetch_mode = req.header("sec-fetch-mode"),
        .sec_ch_ua = req.header("sec-ch-ua"),
        .is_authenticated = is_authed,
        .is_blocklisted = blocklisted,
    });

    // Hard block
    if (cls == .blocked) {
        res.status = 403;
        res.content_type = .TEXT;
        res.body = "blocked\n";
        logVisitFull(app, req, ip, ua, host, method, 403, cls);
        return;
    }

    // Auto-ban: scanner hits get tracked even if request itself is rejected later
    if (cls == .scanner and !is_local) {
        app.autoban.recordScannerHit(ip);
    }

    // Rate limit (skip /health, skip self)
    if (!is_local and cls != .self and !std.mem.eql(u8, path, "/health")) {
        if (!app.rate_limiter.allow(ip)) {
            res.status = 429;
            res.header("Retry-After", "60");
            res.content_type = .TEXT;
            res.body = "Too many requests. Slow down.\n";
            logVisitFull(app, req, ip, ua, host, method, 429, cls);
            return;
        }
    }

    // Dispatch by host
    if (std.mem.eql(u8, host, "www.rofihosted.space")) {
        try redirectAbs(res, "https://rofihosted.space", path);
    } else if (std.mem.eql(u8, host, "dashboard.rofihosted.space")) {
        try redirectAbs(res, "https://app.rofihosted.space", path);
    } else if (std.mem.eql(u8, host, "status.rofihosted.space")) {
        const target = if (std.mem.eql(u8, path, "/")) "/status" else path;
        try redirectAbs(res, "https://app.rofihosted.space", target);
    } else if (std.mem.eql(u8, host, "api.rofihosted.space")) {
        const target = if (std.mem.eql(u8, path, "/")) "/api" else path;
        try redirectAbs(res, "https://app.rofihosted.space", target);
    } else if (std.mem.eql(u8, host, "files.rofihosted.space")) {
        const target = if (std.mem.eql(u8, path, "/")) "/files" else path;
        try redirectAbs(res, "https://app.rofihosted.space", target);
    } else if (std.mem.eql(u8, host, "app.rofihosted.space")) {
        try handleApp(app, req, res, path);
    } else {
        try handleRoot(app, req, res, path);
    }

    logVisitFull(app, req, ip, ua, host, method, res.status, cls);
}

fn redirectAbs(res: *httpz.Response, base: []const u8, suffix: []const u8) !void {
    const target = try std.fmt.allocPrint(res.arena, "{s}{s}", .{ base, suffix });
    res.status = 301;
    res.header("Location", target);
    res.body = "";
}

// =================================================================
// PUBLIC SITE - rofihosted.space
// =================================================================
fn handleRoot(_: *App, _: *httpz.Request, res: *httpz.Response, path: []const u8) !void {
    if (std.mem.eql(u8, path, "/health")) {
        res.content_type = .TEXT;
        res.body = "ok\n";
        return;
    }
    if (std.mem.eql(u8, path, "/theme.css")) {
        res.content_type = .CSS;
        res.header("Cache-Control", "public, max-age=3600");
        res.header("Access-Control-Allow-Origin", "*");
        res.body = @embedFile("templates/theme.css");
        return;
    }
    if (std.mem.eql(u8, path, "/theme.js")) {
        res.content_type = .JS;
        res.header("Cache-Control", "public, max-age=3600");
        res.header("Access-Control-Allow-Origin", "*");
        res.body = @embedFile("templates/theme.js");
        return;
    }
    if (std.mem.eql(u8, path, "/app.css")) {
        res.content_type = .CSS;
        res.header("Cache-Control", "public, max-age=3600");
        res.header("Access-Control-Allow-Origin", "*");
        res.body = @embedFile("templates/app.css");
        return;
    }
    if (std.mem.eql(u8, path, "/app.js")) {
        res.content_type = .JS;
        res.header("Cache-Control", "public, max-age=3600");
        res.header("Access-Control-Allow-Origin", "*");
        res.body = @embedFile("templates/app.js");
        return;
    }
    if (std.mem.eql(u8, path, "/")) {
        res.content_type = .HTML;
        res.body = @embedFile("templates/public.html");
        return;
    }
    return notFound(res);
}

// =================================================================
// PRIVATE CONSOLE - app.rofihosted.space
// =================================================================
fn handleApp(app: *App, req: *httpz.Request, res: *httpz.Response, path: []const u8) !void {
    // Public sub-paths inside app.* (no auth needed)
    if (std.mem.eql(u8, path, "/login")) return handleLoginPage(app, req, res);
    if (std.mem.eql(u8, path, "/login/submit")) return handleLoginSubmit(app, req, res, "/");
    if (std.mem.eql(u8, path, "/logout")) return handleLogout(req, res);
    if (std.mem.eql(u8, path, "/health")) {
        res.content_type = .TEXT;
        res.body = "ok\n";
        return;
    }

    // Protected gate for everything else
    if (!try guard(app, req, res, path)) return;

    // Internal API for the console (consumed by JS)
    if (std.mem.eql(u8, path, "/api/me")) {
        const user = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "";
        try res.json(.{ .username = user }, .{});
        return;
    }
    if (std.mem.eql(u8, path, "/api/stream")) return apiStream(app, req, res);
    if (std.mem.eql(u8, path, "/api/stats")) return apiStats(app, req, res);
    if (std.mem.eql(u8, path, "/api/host")) return apiHost(app, req, res);
    if (std.mem.eql(u8, path, "/api/tunnel")) return apiTunnel(app, req, res);
    if (std.mem.eql(u8, path, "/api/visits")) return apiVisits(app, req, res);
    if (std.mem.eql(u8, path, "/api/uptime")) return apiUptime(app, req, res);
    if (std.mem.eql(u8, path, "/api/security")) return apiSecurity(app, req, res);
    if (std.mem.eql(u8, path, "/api/security/block")) return apiSecurityBlock(app, req, res);
    if (std.mem.eql(u8, path, "/api/security/unblock")) return apiSecurityUnblock(app, req, res);
    if (std.mem.startsWith(u8, path, "/api/files/list")) return apiFilesList(app, req, res);

    // Status badges (private, auth-gated)
    if (std.mem.startsWith(u8, path, "/badge/") and std.mem.endsWith(u8, path, ".svg")) {
        const name = path[7 .. path.len - 4];
        return apiBadge(app, req, res, name);
    }
    if (std.mem.eql(u8, path, "/badge.svg")) return apiBadge(app, req, res, "*");

    // Settings POST
    if (std.mem.eql(u8, path, "/settings/change")) return handleChangeCreds(app, req, res);

    // Pages (all share sidebar)
    if (std.mem.eql(u8, path, "/")) {
        res.content_type = .HTML;
        res.body = @embedFile("templates/app-overview.html");
        return;
    }
    if (std.mem.eql(u8, path, "/status")) {
        res.content_type = .HTML;
        res.body = @embedFile("templates/app-status.html");
        return;
    }
    if (std.mem.eql(u8, path, "/files")) {
        res.content_type = .HTML;
        res.body = @embedFile("templates/app-files.html");
        return;
    }
    if (std.mem.eql(u8, path, "/api")) {
        res.content_type = .HTML;
        res.body = @embedFile("templates/app-api.html");
        return;
    }
    if (std.mem.eql(u8, path, "/settings")) {
        res.content_type = .HTML;
        res.body = @embedFile("templates/app-settings.html");
        return;
    }
    if (std.mem.eql(u8, path, "/security")) {
        res.content_type = .HTML;
        res.body = @embedFile("templates/app-security.html");
        return;
    }
    return notFound(res);
}

// Authentication guard. Redirects unauthenticated users to /login?next=...
fn guard(app: *App, req: *httpz.Request, res: *httpz.Response, return_to: []const u8) !bool {
    if (auth.isAuthenticated(app.auth_cfg, app.allocator, req)) return true;
    const target = try std.fmt.allocPrint(res.arena, "https://app.rofihosted.space/login?next={s}", .{return_to});
    res.status = 302;
    res.header("Location", target);
    res.body = "";
    return false;
}

// =================================================================
// LOGIN HANDLERS
// =================================================================
fn handleLoginPage(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    res.body = @embedFile("templates/login.html");
}

fn handleLoginSubmit(app: *App, req: *httpz.Request, res: *httpz.Response, default_next: []const u8) !void {
    const ip = req.header("cf-connecting-ip") orelse req.header("x-forwarded-for") orelse "local";
    const ua = req.header("user-agent") orelse "";

    // Defense in depth: even if blocklist already returned 403 in router, double-check
    if (!std.mem.eql(u8, ip, "local") and app.blocklist.isBlocked(ip)) {
        res.status = 403;
        res.body = "blocked";
        return;
    }

    // Pull username for logging (before login() consumes form)
    var attempted_user: []const u8 = "";
    if (req.formData()) |form| {
        if (form.get("username")) |u| attempted_user = u;
    } else |_| {}

    const ok = try auth.login(app.auth_cfg, req, res);

    // Track outcome (rate-limit failed attempts -> auto-ban after 5 fails / 15min)
    app.login_tracker.record(ip, ua, attempted_user, ok);

    // Realtime broadcast (mask the username if it's wrong - just log "?" then)
    app.bus.publish(.login_attempt, .{
        .timestamp = std.time.timestamp(),
        .ip = ip,
        .username = if (ok) attempted_user else "?",
        .success = ok,
    });

    var next: []const u8 = default_next;
    if (req.formData()) |form| {
        if (form.get("next")) |n| {
            if (n.len > 0 and n[0] == '/') next = n;
        }
    } else |_| {}

    if (!ok) {
        const target = try std.fmt.allocPrint(res.arena, "https://app.rofihosted.space/login?error=1&next={s}", .{next});
        res.status = 302;
        res.header("Location", target);
        res.body = "";
        return;
    }

    const target = try std.fmt.allocPrint(res.arena, "https://app.rofihosted.space{s}", .{next});
    res.status = 302;
    res.header("Location", target);
    res.body = "";
}

fn handleLogout(_: *httpz.Request, res: *httpz.Response) !void {
    try auth.logout(res);
    res.status = 302;
    res.header("Location", "https://app.rofihosted.space/login");
    res.body = "";
}

fn handleChangeCreds(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const ok = auth.changeCredentials(app.auth_cfg, req, res) catch false;
    res.status = 302;
    res.header("Location", if (ok)
        "https://app.rofihosted.space/settings?ok=1"
    else
        "https://app.rofihosted.space/settings?error=1");
    res.body = "";
}

// =================================================================
// 404
// =================================================================
fn notFound(res: *httpz.Response) !void {
    res.status = 404;
    res.content_type = .HTML;
    res.body = @embedFile("templates/404.html");
}

// =================================================================
// VISIT LOG
// =================================================================
fn logVisitFull(
    app: *App,
    req: *httpz.Request,
    ip: []const u8,
    ua: []const u8,
    host: []const u8,
    method: []const u8,
    status: u16,
    cls: security.Classification,
) void {
    const referer = req.header("referer") orelse "";
    const country = req.header("cf-ipcountry") orelse "";
    const path = req.url.path;

    const visit = store.Visit{
        .visited_at = std.time.timestamp(),
        .ua = ua,
        .ip = ip,
        .path = path,
        .method = method,
        .host = host,
        .status = status,
        .referer = referer,
        .country = country,
        .classification = cls.label(),
    };
    app.store_mutex.lock();
    store.appendJson(visits_path, visit) catch {};
    app.store_mutex.unlock();

    // Realtime broadcast
    app.bus.publish(.visit, visit);
}

// =================================================================
// STATS TICK LOOP (publishes self+memory stats every 2 seconds)
// =================================================================
fn statsTickLoop(bus: *events.Bus, started_at: i64) void {
    while (true) {
        std.Thread.sleep(2 * std.time.ns_per_s);
        if (bus.count() == 0) continue;

        const mem = sysmon.readMemory();
        const self_stats = sysmon.readSelfStats(started_at);

        bus.publish(.stats_tick, .{
            .timestamp = std.time.timestamp(),
            .memory = if (mem) |m| .{
                .total_kb = m.total_kb,
                .used_kb = m.used_kb,
                .available_kb = m.available_kb,
                .free_kb = m.free_kb,
                .cached_kb = m.cached_kb,
                .percent = m.percent,
                .swap_total_kb = m.swap_total_kb,
                .swap_used_kb = m.swap_used_kb,
                .swap_free_kb = m.swap_free_kb,
            } else null,
            .process = if (self_stats) |s| .{
                .rss_kb = s.rss_kb,
                .vsz_kb = s.vsz_kb,
                .threads = s.threads,
                .open_fds = s.open_fds,
                .uptime_seconds = s.uptime_seconds,
            } else null,
        });
    }
}

// =================================================================
// API HANDLERS (private, only inside app.* with auth)
// =================================================================
fn apiStats(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const caps = sysmon.capabilities();
    const mem = sysmon.readMemory();
    const self_stats = sysmon.readSelfStats(app.started_at);

    try res.json(.{
        .timestamp = std.time.timestamp(),
        .capabilities = .{
            .meminfo = caps.has_meminfo,
            .self_proc = caps.has_self,
            .global_cpu = caps.has_global_cpu,
            .loadavg = caps.has_loadavg,
            .global_uptime = caps.has_global_uptime,
            .net_stats = caps.has_net_stats,
            .note = "Android 12 SELinux blocks /proc/stat, /proc/loadavg, /proc/uptime and /proc/net/* for non-root processes. Self process stats and memory remain readable.",
        },
        .memory = if (mem) |m| .{
            .total_kb = m.total_kb,
            .used_kb = m.used_kb,
            .available_kb = m.available_kb,
            .free_kb = m.free_kb,
            .cached_kb = m.cached_kb,
            .percent = m.percent,
            .swap_total_kb = m.swap_total_kb,
            .swap_used_kb = m.swap_used_kb,
            .swap_free_kb = m.swap_free_kb,
        } else null,
        .process = if (self_stats) |s| .{
            .rss_kb = s.rss_kb,
            .vsz_kb = s.vsz_kb,
            .threads = s.threads,
            .open_fds = s.open_fds,
            .uptime_seconds = s.uptime_seconds,
        } else null,
    }, .{});
}

fn apiHost(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const battery = hostinfo.readBattery(res.arena);
    const wifi = hostinfo.readWifi(res.arena);
    try res.json(.{
        .timestamp = std.time.timestamp(),
        .battery = if (battery) |b| .{
            .percentage = b.percentage,
            .status = b.status,
            .plugged = b.plugged,
            .health = b.health,
            .technology = b.technology,
            .temperature_c = b.temperature_c,
            .voltage_mv = b.voltage_mv,
            .current_ma = b.current_ma,
        } else null,
        .wifi = if (wifi) |w| .{
            .ssid = w.ssid,
            .bssid = w.bssid,
            .ip = w.ip,
            .link_speed_mbps = w.link_speed_mbps,
            .rssi = w.rssi,
            .frequency_mhz = w.frequency_mhz,
        } else null,
    }, .{});
}

fn apiTunnel(_: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const tunnel = hostinfo.readTunnelStats(res.arena);
    try res.json(.{
        .timestamp = std.time.timestamp(),
        .tunnel = if (tunnel) |t| .{
            .connections = t.connections,
            .edge_locations = t.edge_locations,
            .total_requests = t.total_requests,
            .request_errors = t.register_errors,
            .quic_connections = t.quic_connections,
            .response_codes = t.response_codes,
        } else null,
    }, .{});
}

// =================================================================
// SECURITY HANDLERS
// =================================================================
fn apiSecurity(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    app.store_mutex.lock();
    const visits = store.readVisits(res.arena, visits_path, 1000) catch {
        app.store_mutex.unlock();
        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"error\":\"store error\"}";
        return;
    };
    app.store_mutex.unlock();

    const arena = res.arena;

    var ip_counts = std.StringHashMap(IpAgg).init(arena);
    var ua_counts = std.StringHashMap(u32).init(arena);
    var path_counts = std.StringHashMap(u32).init(arena);
    var country_counts = std.StringHashMap(u32).init(arena);

    var totals = struct {
        self: u32 = 0,
        unknown: u32 = 0,
        bot: u32 = 0,
        scanner: u32 = 0,
        blocked: u32 = 0,
        legacy: u32 = 0,
        @"4xx": u32 = 0,
        @"5xx": u32 = 0,
    }{};

    const now = std.time.timestamp();
    var requests_last_hour: u32 = 0;
    var requests_last_24h: u32 = 0;

    for (visits) |v| {
        if (now - v.visited_at < 3600) requests_last_hour += 1;
        if (now - v.visited_at < 86400) requests_last_24h += 1;

        if (std.mem.eql(u8, v.classification, "self")) totals.self += 1
        else if (std.mem.eql(u8, v.classification, "unknown")) totals.unknown += 1
        else if (std.mem.eql(u8, v.classification, "bot")) totals.bot += 1
        else if (std.mem.eql(u8, v.classification, "scanner")) totals.scanner += 1
        else if (std.mem.eql(u8, v.classification, "blocked")) totals.blocked += 1
        else totals.legacy += 1;

        if (v.status >= 400 and v.status < 500) totals.@"4xx" += 1;
        if (v.status >= 500) totals.@"5xx" += 1;

        if (v.ip.len > 0) {
            const gop = ip_counts.getOrPut(v.ip) catch continue;
            if (!gop.found_existing) {
                gop.key_ptr.* = arena.dupe(u8, v.ip) catch continue;
                gop.value_ptr.* = .{ .count = 0, .last_seen = 0, .last_path = "", .last_classification = "", .last_status = 0, .country = "" };
            }
            gop.value_ptr.count += 1;
            if (v.visited_at > gop.value_ptr.last_seen) {
                gop.value_ptr.last_seen = v.visited_at;
                gop.value_ptr.last_path = arena.dupe(u8, v.path) catch "";
                gop.value_ptr.last_classification = arena.dupe(u8, v.classification) catch "";
                gop.value_ptr.last_status = v.status;
                if (v.country.len > 0) gop.value_ptr.country = arena.dupe(u8, v.country) catch "";
            }
        }
        if (v.ua.len > 0) {
            const gop = ua_counts.getOrPut(v.ua) catch continue;
            if (!gop.found_existing) {
                gop.key_ptr.* = arena.dupe(u8, v.ua) catch continue;
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += 1;
        }
        if (v.path.len > 0) {
            const gop = path_counts.getOrPut(v.path) catch continue;
            if (!gop.found_existing) {
                gop.key_ptr.* = arena.dupe(u8, v.path) catch continue;
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += 1;
        }
        if (v.country.len > 0) {
            const gop = country_counts.getOrPut(v.country) catch continue;
            if (!gop.found_existing) {
                gop.key_ptr.* = arena.dupe(u8, v.country) catch continue;
                gop.value_ptr.* = 0;
            }
            gop.value_ptr.* += 1;
        }
    }

    const top_ips = try topIps(arena, &ip_counts, 20);
    const top_uas = try topStrCount(arena, &ua_counts, 10);
    const top_paths = try topStrCount(arena, &path_counts, 15);
    const top_countries = try topStrCount(arena, &country_counts, 10);
    const blocklist = try app.blocklist.snapshot(arena);
    const logins = security.readLoginAttempts(arena, 30) catch &[_]security.LoginAttempt{};

    try res.json(.{
        .timestamp = now,
        .total_requests = visits.len,
        .requests_last_hour = requests_last_hour,
        .requests_last_24h = requests_last_24h,
        .classification = .{
            .self = totals.self,
            .unknown = totals.unknown,
            .bot = totals.bot,
            .scanner = totals.scanner,
            .blocked = totals.blocked,
            .legacy = totals.legacy,
        },
        .errors = .{
            .@"4xx" = totals.@"4xx",
            .@"5xx" = totals.@"5xx",
        },
        .top_ips = top_ips,
        .top_user_agents = top_uas,
        .top_paths = top_paths,
        .top_countries = top_countries,
        .blocklist = blocklist,
        .recent_logins = logins,
    }, .{});
}

const IpAgg = struct {
    count: u32,
    last_seen: i64,
    last_path: []const u8,
    last_classification: []const u8,
    last_status: u16,
    country: []const u8,
};

const TopIp = struct {
    ip: []const u8,
    count: u32,
    last_seen: i64,
    last_path: []const u8,
    last_classification: []const u8,
    last_status: u16,
    country: []const u8,
};

const StrCount = struct { value: []const u8, count: u32 };

fn topIps(arena: std.mem.Allocator, map: *std.StringHashMap(IpAgg), limit: usize) ![]TopIp {
    var entries = try std.ArrayList(TopIp).initCapacity(arena, map.count());
    var it = map.iterator();
    while (it.next()) |e| {
        try entries.append(.{
            .ip = e.key_ptr.*,
            .count = e.value_ptr.count,
            .last_seen = e.value_ptr.last_seen,
            .last_path = e.value_ptr.last_path,
            .last_classification = e.value_ptr.last_classification,
            .last_status = e.value_ptr.last_status,
            .country = e.value_ptr.country,
        });
    }
    std.mem.sort(TopIp, entries.items, {}, struct {
        fn cmp(_: void, a: TopIp, b: TopIp) bool { return a.count > b.count; }
    }.cmp);
    const n = @min(limit, entries.items.len);
    return entries.items[0..n];
}

fn topStrCount(arena: std.mem.Allocator, map: *std.StringHashMap(u32), limit: usize) ![]StrCount {
    var entries = try std.ArrayList(StrCount).initCapacity(arena, map.count());
    var it = map.iterator();
    while (it.next()) |e| {
        try entries.append(.{ .value = e.key_ptr.*, .count = e.value_ptr.* });
    }
    std.mem.sort(StrCount, entries.items, {}, struct {
        fn cmp(_: void, a: StrCount, b: StrCount) bool { return a.count > b.count; }
    }.cmp);
    const n = @min(limit, entries.items.len);
    return entries.items[0..n];
}

fn apiSecurityBlock(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const form = req.formData() catch {
        res.status = 400;
        res.content_type = .JSON;
        res.body = "{\"error\":\"bad form\"}";
        return;
    };
    const ip = form.get("ip") orelse {
        res.status = 400;
        res.content_type = .JSON;
        res.body = "{\"error\":\"missing ip\"}";
        return;
    };
    const reason = form.get("reason") orelse "manual";
    app.blocklist.block(ip, reason, 0) catch {
        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"error\":\"failed to write blocklist\"}";
        return;
    };
    app.bus.publish(.blocklist_change, .{ .action = "block", .ip = ip, .reason = reason, .timestamp = std.time.timestamp() });
    try res.json(.{ .ok = true, .blocked = ip }, .{});
}

fn apiSecurityUnblock(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const form = req.formData() catch {
        res.status = 400;
        res.content_type = .JSON;
        res.body = "{\"error\":\"bad form\"}";
        return;
    };
    const ip = form.get("ip") orelse {
        res.status = 400;
        res.content_type = .JSON;
        res.body = "{\"error\":\"missing ip\"}";
        return;
    };
    app.blocklist.unblock(ip) catch {
        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"error\":\"failed to write blocklist\"}";
        return;
    };
    app.bus.publish(.blocklist_change, .{ .action = "unblock", .ip = ip, .timestamp = std.time.timestamp() });
    try res.json(.{ .ok = true, .unblocked = ip }, .{});
}

// =================================================================
// SSE STREAM
// =================================================================
fn apiStream(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    const stream = try res.startEventStreamSync();
    // Initial event so the client knows we are connected
    const hello = "event: hello\ndata: {\"ts\":" ++ "0" ++ "}\n\n";
    _ = stream.writeAll(hello) catch {};

    // Register; bus owns the stream until publish/heartbeat fails on it
    _ = app.bus.subscribe(stream) catch {
        return;
    };
    // After this returns, httpz keeps the connection open because
    // startEventStreamSync called disown(). Bus references the stream.
}

fn apiVisits(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    app.store_mutex.lock();
    defer app.store_mutex.unlock();
    const visits = store.readVisits(res.arena, visits_path, 50) catch {
        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"error\":\"store error\"}";
        return;
    };
    try res.json(visits, .{});
}

fn apiUptime(app: *App, _: *httpz.Request, res: *httpz.Response) !void {
    app.store_mutex.lock();
    defer app.store_mutex.unlock();
    const records = store.readLatestUptime(res.arena, uptime_path) catch {
        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"error\":\"store error\"}";
        return;
    };
    try res.json(records, .{});
}

fn apiFilesList(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = app;
    const q = req.query() catch null;
    const sub_path = if (q) |qq| qq.get("path") orelse "/" else "/";
    const list = files.list(res.arena, sub_path) catch {
        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"error\":\"unable to list\"}";
        return;
    };
    try res.json(.{ .path = sub_path, .entries = list }, .{});
}

fn apiBadge(app: *App, _: *httpz.Request, res: *httpz.Response, target_name: []const u8) !void {
    app.store_mutex.lock();
    const records = store.readLatestUptime(res.arena, uptime_path) catch {
        app.store_mutex.unlock();
        res.status = 500;
        return;
    };
    app.store_mutex.unlock();

    var label: []const u8 = undefined;
    var message: []const u8 = "unknown";
    var style = badge.Style.unknown;

    if (std.mem.eql(u8, target_name, "*")) {
        label = "status";
        var ups: u32 = 0;
        var downs: u32 = 0;
        for (records) |r| if (r.ok) {
            ups += 1;
        } else {
            downs += 1;
        };
        if (downs == 0 and ups > 0) {
            message = "all systems go";
            style = .up;
        } else if (downs > 0 and ups > 0) {
            message = try std.fmt.allocPrint(res.arena, "{d} down", .{downs});
            style = .down;
        } else if (downs > 0) {
            message = "all down";
            style = .down;
        }
    } else {
        label = target_name;
        for (records) |r| {
            if (std.mem.eql(u8, r.target, target_name)) {
                if (r.ok) { message = "up"; style = .up; } else { message = "down"; style = .down; }
                break;
            }
        }
    }

    const svg = try badge.render(res.arena, label, message, style);
    res.content_type = .SVG;
    res.header("Cache-Control", "max-age=60");
    res.body = svg;
}
