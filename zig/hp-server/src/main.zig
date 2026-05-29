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
const ai = @import("ai.zig");
const audit = @import("audit.zig");
const tunnel_health = @import("tunnel_health.zig");
const geoblock = @import("geoblock.zig");
const secret = @import("secret.zig");
const embeddings = @import("embeddings.zig");
const honeypot = @import("honeypot.zig");
const query = @import("query.zig");
const writebuf = @import("writebuf.zig");
const rules = @import("rules.zig");
const dbcache = @import("dbcache.zig");
const dbpool = @import("dbpool.zig");
const pathsafe = @import("pathsafe.zig");
const hosted = @import("hosted.zig");
const apikey = @import("apikey.zig");
const webhook = @import("webhook.zig");
const projects = @import("projects.zig");
const powermon = @import("powermon.zig");
const projsecrets = @import("projsecrets.zig");
const builder = @import("builder.zig");
const supervisor = @import("supervisor.zig");
const proxy = @import("proxy.zig");
const projauth = @import("projauth.zig");
const cron = @import("cron.zig");
const detect = @import("detect.zig");
const mcp = @import("mcp.zig");
const users = @import("users.zig");
const invites = @import("invites.zig");

const visits_path = "/data/data/com.termux/files/home/data/visits.jsonl";
const uptime_path = "/data/data/com.termux/files/home/data/uptime.jsonl";
const digests_path = "/data/data/com.termux/files/home/data/digests.jsonl";
const policy_path = "/data/data/com.termux/files/home/data/policy.jsonl";

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
    ai_cfg: *ai.Config,
    annotation_cache: *ai.AnnotationCache,
    semantic_cache: *ai.SemanticCache,
    tunnel_status: *tunnel_health.Status,
    geoblock: *geoblock.Config,
    embeddings: *embeddings.Store,
    honeypot: *honeypot.Config,
    visit_buf: *writebuf.Buffer,
    rules: *rules.Engine,
    dbcache: *dbcache.Cache,
    dbpool: *dbpool.Pool,
    hosted: *hosted.Manager,
    apikey: *apikey.Manager,
    webhook: *webhook.Manager,
    projects: *projects.Manager,
    builder: *builder.Orchestrator,
    supervisor: *supervisor.Supervisor,
    cron: *cron.Manager,
    powermon: *powermon.PowerMon,
    users: *users.Manager,
    invites: *invites.Manager,
    pepper: []const u8,
    /// Type-erased pointer to the httpz.Server(*App), set after server init.
    /// Used only by the SIGTERM handler to call .stop(). Casting back to the
    /// concrete type avoids a struct-cycle compilation error.
    server_ptr: ?*anyopaque = null,
};

/// Global pointer used only by the SIGTERM handler. Set in main(), null otherwise.
var g_app: ?*App = null;

fn shutdownHandler(_: c_int) callconv(.c) void {
    std.log.info("hp-server: SIGTERM received, shutting down gracefully (build: self-update flow)", .{});
    if (g_app) |app| {
        // Flush buffered writes BEFORE httpz.stop() so we don't lose data
        app.visit_buf.flush() catch |e| {
            std.log.warn("shutdown: visit_buf flush failed: {}", .{e});
        };
        if (app.server_ptr) |ptr| {
            const s: *httpz.Server(*App) = @ptrCast(@alignCast(ptr));
            s.stop();
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.fs.makeDirAbsolute("/data/data/com.termux/files/home/data") catch {};

    var store_mutex = std.Thread.Mutex{};
    var rl = ratelimit.Limiter.init(allocator, 1.0, 60.0);
    const tg_cfg = telegram.Config.fromEnv(allocator);

    // Persistent random pepper for session HMAC. Generated once on first boot.
    var pepper: [secret.PEPPER_LEN]u8 = undefined;
    try secret.loadOrInit(&pepper);

    const auth_cfg = try auth.Config.init(allocator, pepper);
    const blocklist = try security.Blocklist.init(allocator);
    const autoban = try security.AutoBan.init(allocator, blocklist);
    const login_tracker = try security.LoginTracker.init(allocator, blocklist);
    const bus = try events.Bus.init(allocator);
    const ai_cfg = try allocator.create(ai.Config);
    ai_cfg.* = ai.Config.fromEnv(allocator);
    const annotation_cache = try allocator.create(ai.AnnotationCache);
    annotation_cache.* = ai.AnnotationCache.init(allocator);
    const semantic_cache = try allocator.create(ai.SemanticCache);
    semantic_cache.* = ai.SemanticCache.init(allocator);
    const tunnel_status = try allocator.create(tunnel_health.Status);
    tunnel_status.* = .{};
    const geo_cfg = try geoblock.Config.init(allocator);
    const emb_store = try embeddings.Store.init(allocator);
    const honey_cfg = try honeypot.Config.init(allocator);
    const visit_buf = try allocator.create(writebuf.Buffer);
    visit_buf.* = writebuf.Buffer.init(allocator, visits_path);
    const rules_engine = try rules.Engine.init(allocator, blocklist);
    const db_cache = try dbcache.Cache.init(allocator, visits_path);
    const db_pool = try dbpool.Pool.init(allocator, .{
        .db_path = dbcache.PATH,
        .workers = 3,
        .query_timeout_ms = 15_000,
        .max_response_bytes = 8 * 1024 * 1024,
    });
    db_cache.pool = db_pool;
    const hosted_mgr = try hosted.Manager.init(allocator);
    const pepper_slice = try allocator.dupe(u8, &pepper);
    const apikey_mgr = try apikey.Manager.init(allocator, pepper_slice);
    const webhook_mgr = try webhook.Manager.init(allocator);
    const projects_mgr = try projects.Manager.init(allocator);
    const builder_orch = try builder.Orchestrator.init(allocator, pepper_slice, projects_mgr);
    const supervisor_mgr = try supervisor.Supervisor.init(allocator, pepper_slice, projects_mgr);
    builder_orch.supervisor = @ptrCast(supervisor_mgr);
    const cron_mgr = try cron.Manager.init(allocator, pepper_slice, projects_mgr);
    const powermon_inst = try allocator.create(powermon.PowerMon);
    powermon_inst.* = powermon.PowerMon.init(allocator, tg_cfg, bus);
    const users_mgr = try users.Manager.init(allocator, pepper_slice);
    const invites_mgr = try invites.Manager.init(allocator);
    // First-boot: copy the legacy operator into users.zig as u_admin so the
    // multi-user pages have someone to point at as the admin.
    users_mgr.migrateLegacyOperator(auth_cfg.user, auth_cfg.pass) catch {};
    // Wire bus -> webhook fan-out so any event published also fires matching
    // webhooks (operator-configured outbound HTTP, optional, opt-in per hook).
    bus.pub_callback = webhookFanOut;
    bus.pub_ctx = @ptrCast(webhook_mgr);

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
        .ai_cfg = ai_cfg,
        .annotation_cache = annotation_cache,
        .semantic_cache = semantic_cache,
        .tunnel_status = tunnel_status,
        .geoblock = geo_cfg,
        .embeddings = emb_store,
        .honeypot = honey_cfg,
        .visit_buf = visit_buf,
        .rules = rules_engine,
        .dbcache = db_cache,
        .dbpool = db_pool,
        .hosted = hosted_mgr,
        .apikey = apikey_mgr,
        .webhook = webhook_mgr,
        .projects = projects_mgr,
        .builder = builder_orch,
        .supervisor = supervisor_mgr,
        .cron = cron_mgr,
        .powermon = powermon_inst,
        .users = users_mgr,
        .invites = invites_mgr,
        .pepper = pepper_slice,
    };
    g_app = &app;

    // Install SIGTERM/SIGINT handler for graceful shutdown.
    var act = std.posix.Sigaction{
        .handler = .{ .handler = shutdownHandler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);

    // Heartbeat thread keeps SSE clients alive
    const hb = try std.Thread.spawn(.{}, events.heartbeatLoop, .{bus});
    hb.detach();

    // Periodic stats tick (every 2s) so frontend dashboards animate live
    const stats_tick = try std.Thread.spawn(.{}, statsTickLoop, .{ bus, app.started_at });
    stats_tick.detach();

    const checker = try std.Thread.spawn(.{}, uptime.checkerLoop, .{ allocator, uptime_path, &store_mutex, tg_cfg, bus });
    checker.detach();

    // Power monitor: alerts on charger disconnect (this device bootloops on
    // unplug, so plug-status changes are critical).
    const power_thread = try std.Thread.spawn(.{}, powermon.PowerMon.run, .{powermon_inst});
    power_thread.detach();

    // Hourly backup loop: triggers ~/backup-r2.sh every 3600s. Best-effort,
    // skips silently if R2 is not configured. The script also rotates remote
    // copies (keeps last 168 = 7 days hourly).
    const backup_thread = try std.Thread.spawn(.{}, hourlyBackupLoop, .{});
    backup_thread.detach();

    const rotator = try std.Thread.spawn(.{}, store.rotatorLoop, .{ allocator, visits_path, uptime_path, &store_mutex });
    rotator.detach();

    var server = try httpz.Server(*App).init(allocator, .{
        .address = "127.0.0.1",
        .port = 8080,
        .request = .{
            .max_body_size = 64 * 1024 * 1024, // 64 MB so ZIP uploads fit
            .max_form_count = 16,
        },
    }, &app);
    defer server.deinit();
    app.server_ptr = @ptrCast(&server);

    var router = try server.router(.{});
    router.get("/*", hostRouter, .{});
    router.post("/*", hostRouter, .{});

    std.log.info("hp-server listening on http://127.0.0.1:8080", .{});
    std.log.info("auth user='{s}', telegram={s}, ai={s}", .{
        app.auth_cfg.user,
        if (tg_cfg.enabled()) "ENABLED" else "disabled",
        if (ai_cfg.enabled()) "ENABLED" else "disabled",
    });

    // Daily digest loop
    const digest_thread = try std.Thread.spawn(.{}, digestLoop, .{&app});
    digest_thread.detach();

    // Weekly policy review loop
    const policy_thread = try std.Thread.spawn(.{}, policyLoop, .{&app});
    policy_thread.detach();

    // Embeddings persist loop (every 5 min if dirty)
    const emb_thread = try std.Thread.spawn(.{}, embeddings.Store.persistLoop, .{emb_store});
    emb_thread.detach();

    // Tunnel health watchdog
    const th = try std.Thread.spawn(.{}, tunnel_health.loop, .{ allocator, tunnel_status, bus });
    th.detach();

    // Buffered visit writer flush loop (every 5s)
    const vbuf_thread = try std.Thread.spawn(.{}, writebuf.flushLoop, .{visit_buf});
    vbuf_thread.detach();

    // SQLite read-side cache sync loop (every 5 min)
    const dbsync_thread = try std.Thread.spawn(.{}, dbcache.syncLoop, .{db_cache});
    dbsync_thread.detach();

    // Auto-restart any backend project that was running at last shutdown.
    supervisor_mgr.restartPersisted();
    // Background loop that respawns crashed children with exponential backoff.
    const supervisor_thread = try std.Thread.spawn(.{}, supervisor.Supervisor.autoRestartLoop, .{supervisor_mgr});
    supervisor_thread.detach();

    // Cron loop: tick every 30s, fire matching tasks.
    const cron_thread = try std.Thread.spawn(.{}, cron.Manager.loop, .{cron_mgr});
    cron_thread.detach();

    try server.listen();
    std.log.info("hp-server: server.listen returned, exiting cleanly", .{});
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
    const is_authed_cookie = auth.isAuthenticated(app.auth_cfg, app.allocator, req);
    // Treat presence of X-API-Key on /v1/* as authenticated for classification
    // purposes, so botched API requests don't get auto-banned during dev.
    // Real key validation happens inside handleV1.
    const has_apikey_header = (req.header("x-api-key") orelse req.header("X-Api-Key") orelse "").len > 0;
    const is_v1 = std.mem.startsWith(u8, path, "/v1/");

    // Admin API key holders bypass the blocklist entirely. A valid admin key
    // is proof of identity; blocking them defeats the purpose of the key.
    // We verify the key here (not just check presence) to prevent spoofing.
    const has_admin_key = blk: {
        const raw = req.header("x-api-key") orelse req.header("X-Api-Key") orelse "";
        if (raw.len == 0) break :blk false;
        if (app.apikey.verify(raw)) |rec| {
            break :blk rec.hasScope(.admin);
        }
        break :blk false;
    };

    const is_authed = is_authed_cookie or (is_v1 and has_apikey_header) or has_admin_key;
    const blocklisted = !is_local and !has_admin_key and app.blocklist.isBlocked(ip);

    // Trust memory: any authenticated request from this IP exempts it from
    // auto-ban for the next TRUSTED_TTL seconds. Prevents the operator's IP
    // from getting auto-banned because a parallel test request from the same
    // IP hit a scanner path (e.g. /.env in the smoke test).
    if (is_authed and !is_local) {
        app.autoban.markAuthenticated(ip);
    }

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

    // Geo-block: optional, off by default. Cloudflare sets cf-ipcountry on every request.
    // Skip for self-authenticated, local, and /health.
    if (!is_authed and !is_local and !std.mem.eql(u8, path, "/health")) {
        const country = req.header("cf-ipcountry") orelse "";
        if (app.geoblock.shouldBlock(country)) {
            res.status = 403;
            res.content_type = .TEXT;
            res.body = "blocked by geo-policy\n";
            logVisitFull(app, req, ip, ua, host, method, 403, cls);
            return;
        }
    }

    // Auto-ban: scanner hits get tracked even if request itself is rejected later
    if (cls == .scanner and !is_local) {
        const did_ban = app.autoban.recordScannerHit(ip);
        if (did_ban) {
            app.bus.publish(.blocklist_change, .{
                .action = "block",
                .ip = ip,
                .reason = "auto: scanner attempts exceeded threshold",
                .timestamp = std.time.timestamp(),
            });
            // Fire-and-forget AI annotation
            spawnAnnotateBan(app, ip, ua) catch {};
        }
        // Honeypot: if enabled, serve plausible decoy instead of falling through to 403/handler.
        if (app.honeypot.isEnabled()) {
            if (app.honeypot.getOrGenerate(app.ai_cfg, path)) |entry| {
                res.status = 200;
                res.header("Content-Type", entry.content_type);
                res.body = entry.body;
                logVisitFull(app, req, ip, ua, host, method, 200, cls);
                return;
            }
        }
    }

    // Embeddings: track unique (ua, path) combos for non-self traffic.
    // Async fire-and-forget so request latency is unaffected.
    if (!is_authed and !is_local and cls != .blocked) {
        spawnEmbedRequest(app, ua, path) catch {};
    }

    // Rule engine: dispatch on_visit. Rules can block, log, or bump counters
    // synchronously. They should be fast (no I/O beyond the blocklist).
    {
        const country_hdr = req.header("cf-ipcountry") orelse "";
        app.rules.dispatch(.on_visit, .{
            .ip = ip,
            .path = path,
            .country = country_hdr,
            .ua = ua,
            .classification = cls.label(),
            .method = method,
            .host = host,
        });
        // A rule action may have just blocked this IP. Re-check before serving.
        if (!is_local and app.blocklist.isBlocked(ip)) {
            res.status = 403;
            res.content_type = .TEXT;
            res.body = "blocked\n";
            logVisitFull(app, req, ip, ua, host, method, 403, .blocked);
            return;
        }
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

    // Project-aware subdomain routing. Static projects served from
    // ~/data/projects/<id>/current/. Backend projects (later phase) reverse-proxied.
    if (try tryServeProject(app, req, host, path, ip, res)) {
        logVisitFull(app, req, ip, ua, host, method, res.status, cls);
        return;
    }

    // Static hosting: try *.rofihosted.space subdomains before fixed routing.
    // Returns true if served (any subdomain that has ~/hosted/sites/<sub>/current/).
    if (try hosted.tryServe(app.hosted, host, path, res)) {
        logVisitFull(app, req, ip, ua, host, method, res.status, cls);
        return;
    }

    // Public API for external apps/scripts. Auth via X-API-Key header (NOT cookie).
    // Available on api.rofihosted.space AND app.rofihosted.space.
    if (std.mem.startsWith(u8, path, "/v1/")) {
        try handleV1(app, req, res, path);
        logVisitFull(app, req, ip, ua, host, method, res.status, cls);
        return;
    }

    // MCP (Model Context Protocol) endpoint. JSON-RPC 2.0 over a single
    // POST /mcp. Auth via Authorization: Bearer <api_key> with admin scope.
    // Stateless mode - no session ID, no SSE streaming.
    if (std.mem.eql(u8, path, "/mcp")) {
        try handleMcp(app, req, res);
        logVisitFull(app, req, ip, ua, host, method, res.status, cls);
        return;
    }
    if (std.mem.eql(u8, path, "/.well-known/mcp.json")) {
        try handleMcpDiscovery(app, res);
        logVisitFull(app, req, ip, ua, host, method, res.status, cls);
        return;
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
fn handleRoot(app: *App, req: *httpz.Request, res: *httpz.Response, path: []const u8) !void {
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
    if (std.mem.eql(u8, path, "/icons.css")) {
        res.content_type = .CSS;
        res.header("Cache-Control", "public, max-age=86400");
        res.header("Access-Control-Allow-Origin", "*");
        res.body = @embedFile("templates/icons.css");
        return;
    }
    if (std.mem.eql(u8, path, "/fonts/Simple-Line-Icons.woff2")) {
        res.content_type = .BINARY;
        res.header("Content-Type", "font/woff2");
        res.header("Cache-Control", "public, max-age=2592000");
        res.header("Access-Control-Allow-Origin", "*");
        res.body = @embedFile("templates/Simple-Line-Icons.woff2");
        return;
    }
    if (std.mem.eql(u8, path, "/")) {
        res.content_type = .HTML;
        res.body = @embedFile("templates/public.html");
        return;
    }
    if (std.mem.eql(u8, path, "/signup")) {
        res.content_type = .HTML;
        res.body = @embedFile("templates/signup.html");
        return;
    }
    if (std.mem.eql(u8, path, "/signup/submit")) {
        return handleSignupSubmit(app, req, res);
    }
    if (std.mem.eql(u8, path, "/signup/check-invite")) {
        return handleCheckInvite(app, req, res);
    }
    if (std.mem.eql(u8, path, "/signup/pending")) {
        res.content_type = .HTML;
        res.body = @embedFile("templates/signup-pending.html");
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
    if (std.mem.eql(u8, path, "/api/ai/explain")) return apiAiExplain(app, req, res);
    if (std.mem.eql(u8, path, "/api/ai/explain/stream")) return apiAiExplainStream(app, req, res);
    if (std.mem.eql(u8, path, "/api/ai/digest/latest")) return apiDigestLatest(app, res);
    if (std.mem.eql(u8, path, "/api/ai/digest/run")) return apiDigestRun(app, req, res);
    if (std.mem.eql(u8, path, "/api/ai/policy/latest")) return apiPolicyLatest(app, res);
    if (std.mem.eql(u8, path, "/api/ai/policy/run")) return apiPolicyRun(app, req, res);
    if (std.mem.eql(u8, path, "/api/ai/query")) return apiAiQuery(app, req, res);
    if (std.mem.eql(u8, path, "/api/ai/usage")) return apiAiUsage(app, res);
    if (std.mem.eql(u8, path, "/api/embeddings/clusters")) return apiEmbeddingsClusters(app, res);
    if (std.mem.eql(u8, path, "/api/embeddings/stats")) return apiEmbeddingsStats(app, res);
    if (std.mem.eql(u8, path, "/api/honeypot")) return apiHoneypotGet(app, res);
    if (std.mem.eql(u8, path, "/api/honeypot/update")) return apiHoneypotUpdate(app, req, res);
    if (std.mem.eql(u8, path, "/api/rules")) return apiRulesGet(app, res);
    if (std.mem.eql(u8, path, "/api/rules/replace")) return apiRulesReplace(app, req, res);
    if (std.mem.eql(u8, path, "/api/dbcache/stats")) return apiDbCacheStats(app, res);
    if (std.mem.eql(u8, path, "/api/dbcache/sync")) return apiDbCacheSync(app, req, res);
    if (std.mem.eql(u8, path, "/api/dbpool/stats")) return apiDbPoolStats(app, res);
    if (std.mem.eql(u8, path, "/api/apikeys")) return apiApikeysList(app, res);
    if (std.mem.eql(u8, path, "/api/apikeys/create")) return apiApikeysCreate(app, req, res);
    if (std.mem.eql(u8, path, "/api/apikeys/revoke")) return apiApikeysRevoke(app, req, res);
    if (std.mem.eql(u8, path, "/api/webhooks")) return apiWebhooksList(app, res);
    if (std.mem.eql(u8, path, "/api/webhooks/create")) return apiWebhooksCreate(app, req, res);
    if (std.mem.eql(u8, path, "/api/webhooks/delete")) return apiWebhooksDelete(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects")) return apiProjectsList(app, res);
    if (std.mem.eql(u8, path, "/api/projects/create")) return apiProjectsCreate(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects/update")) return apiProjectsUpdate(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects/delete")) return apiProjectsDelete(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects/secrets/list")) return apiProjectSecretsList(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects/secrets/set")) return apiProjectSecretsSet(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects/secrets/delete")) return apiProjectSecretsDelete(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects/deploy")) return apiProjectsDeploy(app, req, res);
    if (std.mem.startsWith(u8, path, "/api/projects/logs")) return apiProjectsLogs(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects/start")) return apiProjectsStart(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects/stop")) return apiProjectsStop(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects/restart")) return apiProjectsRestart(app, req, res);
    if (std.mem.startsWith(u8, path, "/api/projects/runtime-logs")) return apiProjectsRuntimeLogs(app, req, res);
    if (std.mem.startsWith(u8, path, "/api/projects/status")) return apiProjectsStatus(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects/upload")) return apiProjectsUpload(app, req, res);
    if (std.mem.startsWith(u8, path, "/api/projects/releases")) return apiProjectsReleases(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects/rollback")) return apiProjectsRollback(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects/sql")) return apiProjectsSql(app, req, res);
    if (std.mem.startsWith(u8, path, "/api/projects/cron/list")) return apiCronList(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects/cron/create")) return apiCronCreate(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects/cron/delete")) return apiCronDelete(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects/cron/toggle")) return apiCronToggle(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects/cron/run")) return apiCronRun(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects/preview-repo")) return apiProjectsPreviewRepo(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects/analyze")) return apiProjectsAnalyze(app, req, res);
    if (std.mem.startsWith(u8, path, "/api/projects/users")) return apiProjectsUsers(app, req, res);
    if (std.mem.startsWith(u8, path, "/api/projects/tables")) return apiProjectsTables(app, req, res);
    if (std.mem.eql(u8, path, "/api/projects/log-stream")) return apiProjectsLogStream(app, req, res);
    if (std.mem.eql(u8, path, "/api/hosted/stats")) return apiHostedStats(app, res);
    if (std.mem.eql(u8, path, "/api/hosted/list")) return apiHostedList(app, res);
    if (std.mem.eql(u8, path, "/api/hosted/refresh")) return apiHostedRefresh(app, req, res);
    if (std.mem.eql(u8, path, "/api/ai/scrub")) return apiAiScrub(app, req, res);
    if (std.mem.eql(u8, path, "/api/audit")) return apiAudit(app, res);

    // Multi-tenancy: user + invite management (admin-only)
    if (std.mem.eql(u8, path, "/api/users")) return apiUsersList(app, req, res);
    if (std.mem.eql(u8, path, "/api/users/approve")) return apiUsersApprove(app, req, res);
    if (std.mem.eql(u8, path, "/api/users/reject")) return apiUsersReject(app, req, res);
    if (std.mem.eql(u8, path, "/api/users/suspend")) return apiUsersSuspend(app, req, res);
    if (std.mem.eql(u8, path, "/api/users/unsuspend")) return apiUsersUnsuspend(app, req, res);
    if (std.mem.eql(u8, path, "/api/invites")) return apiInvitesList(app, req, res);
    if (std.mem.eql(u8, path, "/api/invites/create")) return apiInvitesCreate(app, req, res);
    if (std.mem.eql(u8, path, "/api/invites/revoke")) return apiInvitesRevoke(app, req, res);
    if (std.mem.eql(u8, path, "/api/tunnel/health")) return apiTunnelHealth(app, res);
    if (std.mem.eql(u8, path, "/api/geoblock")) return apiGeoblockGet(app, res);
    if (std.mem.eql(u8, path, "/api/geoblock/update")) return apiGeoblockUpdate(app, req, res);

    // Built-in shell + system info (replaces SSH for the operator)
    if (std.mem.eql(u8, path, "/api/system/exec")) return apiSystemExec(app, req, res);
    if (std.mem.eql(u8, path, "/api/system/info")) return apiSystemInfo(app, req, res);
    if (std.mem.eql(u8, path, "/api/system/power")) return apiSystemPower(app, req, res);
    if (std.mem.eql(u8, path, "/api/system/backup")) return apiSystemBackup(app, req, res);
    if (std.mem.eql(u8, path, "/api/system/backups")) return apiSystemBackups(app, req, res);
    if (std.mem.eql(u8, path, "/api/system/version")) return apiSystemVersion(app, req, res);
    if (std.mem.eql(u8, path, "/api/system/update")) return apiSystemUpdate(app, req, res);
    if (std.mem.eql(u8, path, "/api/system/restore-test")) return apiSystemRestoreTest(app, req, res);

    // Status badges (private, auth-gated)
    if (std.mem.startsWith(u8, path, "/badge/") and std.mem.endsWith(u8, path, ".svg")) {
        const name = path[7 .. path.len - 4];
        return apiBadge(app, req, res, name);
    }
    if (std.mem.eql(u8, path, "/badge.svg")) return apiBadge(app, req, res, "*");

    // Settings POST
    if (std.mem.eql(u8, path, "/settings/change")) return handleChangeCreds(app, req, res);

    // Pages (all share sidebar). Mark HTML as no-store so browsers always
    // re-fetch on navigation; otherwise stale UI logic (button visibility
    // rules, etc) hangs around even after a deploy.
    if (std.mem.eql(u8, path, "/")) {
        res.content_type = .HTML;
        res.header("Cache-Control", "no-store, must-revalidate");
        res.body = @embedFile("templates/app-overview.html");
        return;
    }
    if (std.mem.eql(u8, path, "/status")) {
        res.content_type = .HTML;
        res.header("Cache-Control", "no-store, must-revalidate");
        res.body = @embedFile("templates/app-status.html");
        return;
    }
    if (std.mem.eql(u8, path, "/files")) {
        res.content_type = .HTML;
        res.header("Cache-Control", "no-store, must-revalidate");
        res.body = @embedFile("templates/app-files.html");
        return;
    }
    if (std.mem.eql(u8, path, "/api")) {
        res.content_type = .HTML;
        res.header("Cache-Control", "no-store, must-revalidate");
        res.body = @embedFile("templates/app-api.html");
        return;
    }
    if (std.mem.eql(u8, path, "/settings")) {
        res.content_type = .HTML;
        res.header("Cache-Control", "no-store, must-revalidate");
        res.body = @embedFile("templates/app-settings.html");
        return;
    }
    if (std.mem.eql(u8, path, "/security")) {
        res.content_type = .HTML;
        res.header("Cache-Control", "no-store, must-revalidate");
        res.body = @embedFile("templates/app-security.html");
        return;
    }
    if (std.mem.eql(u8, path, "/projects")) {
        res.content_type = .HTML;
        res.header("Cache-Control", "no-store, must-revalidate");
        res.body = @embedFile("templates/app-projects.html");
        return;
    }
    if (std.mem.eql(u8, path, "/shell")) {
        res.content_type = .HTML;
        res.header("Cache-Control", "no-store, must-revalidate");
        res.body = @embedFile("templates/app-shell.html");
        return;
    }
    if (std.mem.eql(u8, path, "/admin/users")) {
        res.content_type = .HTML;
        res.header("Cache-Control", "no-store, must-revalidate");
        res.body = @embedFile("templates/app-admin-users.html");
        return;
    }
    if (std.mem.eql(u8, path, "/admin/invites")) {
        res.content_type = .HTML;
        res.header("Cache-Control", "no-store, must-revalidate");
        res.body = @embedFile("templates/app-admin-invites.html");
        return;
    }
    return notFound(res);
}

// Authentication guard. Redirects unauthenticated users to /login?next=...
// Also accepts admin-scoped API keys for /api/system/* and /api/projects/*
// so the rh CLI and Kiro can hit these endpoints without a session cookie.
fn guard(app: *App, req: *httpz.Request, res: *httpz.Response, return_to: []const u8) !bool {
    if (auth.isAuthenticated(app.auth_cfg, app.allocator, req)) return true;

    // Allow admin API key to bypass cookie auth for system + project endpoints.
    // This lets the rh CLI and Kiro access /api/system/exec, /api/system/info,
    // /api/projects/*, etc without a browser session.
    const raw_key = req.header("x-api-key") orelse req.header("X-Api-Key") orelse "";
    if (raw_key.len > 0) {
        if (app.apikey.verify(raw_key)) |rec| {
            if (rec.hasScope(.admin)) {
                // Admin key: allow access to /api/system/* and /api/projects/*
                if (std.mem.startsWith(u8, return_to, "/api/system") or
                    std.mem.startsWith(u8, return_to, "/api/projects") or
                    std.mem.startsWith(u8, return_to, "/api/apikeys") or
                    std.mem.startsWith(u8, return_to, "/api/audit") or
                    std.mem.startsWith(u8, return_to, "/api/security") or
                    std.mem.startsWith(u8, return_to, "/api/me") or
                    std.mem.startsWith(u8, return_to, "/api/visits") or
                    std.mem.startsWith(u8, return_to, "/api/stats") or
                    std.mem.startsWith(u8, return_to, "/api/hosted") or
                    std.mem.startsWith(u8, return_to, "/api/webhooks") or
                    std.mem.startsWith(u8, return_to, "/api/rules") or
                    std.mem.startsWith(u8, return_to, "/api/dbcache") or
                    std.mem.startsWith(u8, return_to, "/api/dbpool") or
                    std.mem.startsWith(u8, return_to, "/api/geoblock") or
                    std.mem.startsWith(u8, return_to, "/api/honeypot") or
                    std.mem.startsWith(u8, return_to, "/api/uptime") or
                    std.mem.startsWith(u8, return_to, "/api/tunnel") or
                    std.mem.startsWith(u8, return_to, "/api/host") or
                    std.mem.startsWith(u8, return_to, "/api/files") or
                    std.mem.startsWith(u8, return_to, "/api/ai") or
                    std.mem.startsWith(u8, return_to, "/api/embeddings") or
                    std.mem.startsWith(u8, return_to, "/shell") or
                    std.mem.startsWith(u8, return_to, "/projects") or
                    std.mem.startsWith(u8, return_to, "/settings") or
                    std.mem.startsWith(u8, return_to, "/security"))
                {
                    return true;
                }
            }
        }
    }
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
    res.header("Cache-Control", "no-store, must-revalidate");
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

    // Try multi-user login first; fall back to legacy operator credentials.
    var ok: bool = false;
    var pending: bool = false;
    if (app.users.findByUsername(attempted_user)) |_| {
        if (try auth.loginUser(app.auth_cfg, app.users, req, res)) |user| {
            ok = true;
            pending = (user.status == .pending);
        }
    }
    if (!ok) {
        ok = try auth.login(app.auth_cfg, req, res);
    }

    // Track outcome (rate-limit failed attempts -> auto-ban after 5 fails / 15min)
    app.login_tracker.record(ip, ua, attempted_user, ok);

    // Rule engine: dispatch on_login_attempt
    app.rules.dispatch(.on_login_attempt, .{
        .ip = ip,
        .ua = ua,
        .username = attempted_user,
        .success = ok,
    });

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

    // Pending users go to a holding page instead of the dashboard.
    if (pending) {
        res.status = 302;
        res.header("Location", "https://rofihosted.space/signup/pending");
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
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const ok = auth.changeCredentials(app.auth_cfg, req, res) catch false;
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "change_credentials",
        .target = "self",
        .ok = ok,
    });
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
    // Buffered append: returns immediately, flushed every 5s by background loop.
    app.visit_buf.append(visit) catch |e| {
        std.log.warn("visit_buf append failed: {}", .{e});
    };

    // Realtime broadcast
    app.bus.publish(.visit, visit);
}

/// Flush the buffered visit writer and read fresh visit data.
/// Use this instead of calling store.readVisits directly when you want
/// to include the last 0-5s of buffered visits.
fn readVisitsFresh(app: *App, allocator: std.mem.Allocator, limit: usize) ![]store.Visit {
    app.visit_buf.flush() catch |e| {
        std.log.warn("readVisitsFresh: pre-flush failed: {}", .{e});
    };
    return store.readVisits(allocator, visits_path, limit);
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
    const visits = readVisitsFresh(app, res.arena, 1000) catch {
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

        if (std.mem.eql(u8, v.classification, "self")) totals.self += 1 else if (std.mem.eql(u8, v.classification, "unknown")) totals.unknown += 1 else if (std.mem.eql(u8, v.classification, "bot")) totals.bot += 1 else if (std.mem.eql(u8, v.classification, "scanner")) totals.scanner += 1 else if (std.mem.eql(u8, v.classification, "blocked")) totals.blocked += 1 else totals.legacy += 1;

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
        fn cmp(_: void, a: TopIp, b: TopIp) bool {
            return a.count > b.count;
        }
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
        fn cmp(_: void, a: StrCount, b: StrCount) bool {
            return a.count > b.count;
        }
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
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    app.blocklist.block(ip, reason, 0) catch {
        audit.append(.{
            .timestamp = std.time.timestamp(),
            .actor = actor,
            .action = "block_ip",
            .target = ip,
            .detail = reason,
            .ok = false,
        });
        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"error\":\"failed to write blocklist\"}";
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "block_ip",
        .target = ip,
        .detail = reason,
    });
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
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    app.blocklist.unblock(ip) catch {
        audit.append(.{
            .timestamp = std.time.timestamp(),
            .actor = actor,
            .action = "unblock_ip",
            .target = ip,
            .ok = false,
        });
        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"error\":\"failed to write blocklist\"}";
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "unblock_ip",
        .target = ip,
    });
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
    const visits = readVisitsFresh(app, res.arena, 50) catch {
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
                if (r.ok) {
                    message = "up";
                    style = .up;
                } else {
                    message = "down";
                    style = .down;
                }
                break;
            }
        }
    }

    const svg = try badge.render(res.arena, label, message, style);
    res.content_type = .SVG;
    res.header("Cache-Control", "max-age=60");
    res.body = svg;
}

// =================================================================
// AI: BAN ANNOTATION (async, fire-and-forget)
// =================================================================
const AnnotateArgs = struct {
    app: *App,
    ip: []u8,
    ua: []u8,
};

fn spawnAnnotateBan(app: *App, ip: []const u8, ua: []const u8) !void {
    if (!app.ai_cfg.enabled()) return;
    const args = try app.allocator.create(AnnotateArgs);
    args.* = .{
        .app = app,
        .ip = try app.allocator.dupe(u8, ip),
        .ua = try app.allocator.dupe(u8, ua),
    };
    const t = try std.Thread.spawn(.{}, annotateBanThread, .{args});
    t.detach();
}

fn annotateBanThread(args: *AnnotateArgs) void {
    defer {
        args.app.allocator.free(args.ip);
        args.app.allocator.free(args.ua);
        args.app.allocator.destroy(args);
    }

    var arena = std.heap.ArenaAllocator.init(args.app.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Cache hit? Reuse the previous annotation, no API call.
    if (args.app.annotation_cache.lookup(args.ip, a)) |cached| {
        const final = std.fmt.allocPrint(a, "auto: {s}", .{cached}) catch return;
        args.app.blocklist.updateReason(args.ip, final) catch {};
        args.app.bus.publish(.blocklist_change, .{
            .action = "annotate",
            .ip = args.ip,
            .reason = final,
            .timestamp = std.time.timestamp(),
        });
        return;
    }

    // Pull recent paths probed by this IP from visits.jsonl
    args.app.store_mutex.lock();
    const visits = readVisitsFresh(args.app, a, 500) catch {
        args.app.store_mutex.unlock();
        return;
    };
    args.app.store_mutex.unlock();

    var recent_paths = std.ArrayList([]const u8).init(a);
    var country: []const u8 = "-";
    for (visits) |v| {
        if (std.mem.eql(u8, v.ip, args.ip)) {
            if (v.country.len > 0) country = v.country;
            recent_paths.append(v.path) catch {};
            if (recent_paths.items.len >= 8) break;
        }
    }
    if (recent_paths.items.len == 0) return; // nothing to base annotation on

    const annotated_json = ai.annotateBan(args.app.ai_cfg, a, .{
        .ip = args.ip,
        .paths = recent_paths.items,
        .user_agent = args.ua,
        .country = country,
    }) orelse return;

    // Parse structured output -> compact summary string for the blocklist reason
    const Parsed = struct {
        actor_type: []const u8,
        risk_score: u8,
        summary: []const u8,
        indicators: []const []const u8 = &.{},
    };
    const parsed = std.json.parseFromSlice(Parsed, a, annotated_json, .{
        .ignore_unknown_fields = true,
    }) catch return;

    const compact = std.fmt.allocPrint(a, "{s} (risk={d}, {s})", .{
        parsed.value.summary,
        parsed.value.risk_score,
        parsed.value.actor_type,
    }) catch return;
    args.app.annotation_cache.put(args.ip, compact);

    // Prepend "auto: " so the source is still visible after enrichment.
    const final = std.fmt.allocPrint(a, "auto: {s}", .{compact}) catch return;
    args.app.blocklist.updateReason(args.ip, final) catch {};
    args.app.bus.publish(.blocklist_change, .{
        .action = "annotate",
        .ip = args.ip,
        .reason = final,
        .timestamp = std.time.timestamp(),
    });
}

// =================================================================
// AI: EXPLAIN AN IP (synchronous, on-demand)
// =================================================================
fn apiAiExplain(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (!app.ai_cfg.enabled()) {
        res.status = 503;
        try res.json(.{ .ok = false, .err = "ai_disabled" }, .{});
        return;
    }
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const ip = form.get("ip") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_ip" }, .{});
        return;
    };

    app.store_mutex.lock();
    const visits = readVisitsFresh(app, res.arena, 2000) catch {
        app.store_mutex.unlock();
        res.status = 500;
        try res.json(.{ .ok = false, .err = "read_failed" }, .{});
        return;
    };
    app.store_mutex.unlock();

    var paths = std.ArrayList([]const u8).init(res.arena);
    var ua_set = std.StringHashMap(void).init(res.arena);
    var classification_counts = std.StringHashMap(u32).init(res.arena);
    var country: []const u8 = "-";
    var visit_count: u32 = 0;
    for (visits) |v| {
        if (!std.mem.eql(u8, v.ip, ip)) continue;
        visit_count += 1;
        if (v.country.len > 0) country = v.country;
        if (paths.items.len < 20) paths.append(v.path) catch {};
        if (ua_set.count() < 6 and v.ua.len > 0) ua_set.put(v.ua, {}) catch {};
        if (v.classification.len > 0) {
            const gop = classification_counts.getOrPut(v.classification) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }
    if (visit_count == 0) {
        res.status = 404;
        try res.json(.{ .ok = false, .err = "no_visits_for_ip" }, .{});
        return;
    }

    var ua_list = std.ArrayList([]const u8).init(res.arena);
    var ua_it = ua_set.keyIterator();
    while (ua_it.next()) |k| ua_list.append(k.*) catch {};

    var cls_buf = std.ArrayList(u8).init(res.arena);
    var cls_it = classification_counts.iterator();
    var first = true;
    while (cls_it.next()) |e| {
        if (!first) cls_buf.appendSlice(", ") catch {};
        first = false;
        cls_buf.writer().print("{s}: {d}", .{ e.key_ptr.*, e.value_ptr.* }) catch {};
    }

    const profile_json = ai.explainIp(app.ai_cfg, res.arena, .{
        .ip = ip,
        .country = country,
        .visit_count = visit_count,
        .classifications = cls_buf.items,
        .paths = paths.items,
        .user_agents = ua_list.items,
    }) orelse {
        res.status = 502;
        try res.json(.{ .ok = false, .err = "ai_call_failed" }, .{});
        return;
    };

    // Parse the structured assessment so we return typed fields.
    const ParsedAssessment = struct {
        actor_type: []const u8,
        risk_score: u8,
        confidence: f32,
        recommended_action: []const u8,
        reasoning: []const u8,
        indicators: []const []const u8 = &.{},
    };
    const parsed = std.json.parseFromSlice(ParsedAssessment, res.arena, profile_json, .{
        .ignore_unknown_fields = true,
    }) catch {
        // Fall back to raw text if parsing fails for any reason
        try res.json(.{
            .ok = true,
            .ip = ip,
            .visit_count = visit_count,
            .country = country,
            .raw = profile_json,
        }, .{});
        return;
    };

    try res.json(.{
        .ok = true,
        .ip = ip,
        .visit_count = visit_count,
        .country = country,
        .assessment = parsed.value,
    }, .{});
}

// =================================================================
// AI: EXPLAIN IP (STREAMING via SSE)
// =================================================================
fn apiAiExplainStream(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (!app.ai_cfg.enabled()) {
        res.status = 503;
        res.content_type = .TEXT;
        res.body = "ai_disabled\n";
        return;
    }
    const form = req.formData() catch {
        res.status = 400;
        res.content_type = .TEXT;
        res.body = "bad_form\n";
        return;
    };
    const ip = form.get("ip") orelse {
        res.status = 400;
        res.content_type = .TEXT;
        res.body = "missing_ip\n";
        return;
    };

    // Gather visit data (same as non-streaming explain)
    app.store_mutex.lock();
    const visits = readVisitsFresh(app, res.arena, 2000) catch {
        app.store_mutex.unlock();
        res.status = 500;
        res.content_type = .TEXT;
        res.body = "read_failed\n";
        return;
    };
    app.store_mutex.unlock();

    var paths = std.ArrayList([]const u8).init(res.arena);
    var ua_set = std.StringHashMap(void).init(res.arena);
    var classification_counts = std.StringHashMap(u32).init(res.arena);
    var country: []const u8 = "-";
    var visit_count: u32 = 0;
    for (visits) |v| {
        if (!std.mem.eql(u8, v.ip, ip)) continue;
        visit_count += 1;
        if (v.country.len > 0) country = v.country;
        if (paths.items.len < 20) paths.append(v.path) catch {};
        if (ua_set.count() < 6 and v.ua.len > 0) ua_set.put(v.ua, {}) catch {};
        if (v.classification.len > 0) {
            const gop = classification_counts.getOrPut(v.classification) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }
    if (visit_count == 0) {
        res.status = 404;
        res.content_type = .TEXT;
        res.body = "no_visits_for_ip\n";
        return;
    }

    var ua_list = std.ArrayList([]const u8).init(res.arena);
    var ua_it = ua_set.keyIterator();
    while (ua_it.next()) |k| ua_list.append(k.*) catch {};

    var cls_buf = std.ArrayList(u8).init(res.arena);
    var cls_it = classification_counts.iterator();
    var first = true;
    while (cls_it.next()) |e| {
        if (!first) cls_buf.appendSlice(", ") catch {};
        first = false;
        cls_buf.writer().print("{s}: {d}", .{ e.key_ptr.*, e.value_ptr.* }) catch {};
    }

    // Start SSE stream
    const stream = try res.startEventStreamSync();

    // Send metadata event first
    var meta_buf: [256]u8 = undefined;
    const meta = std.fmt.bufPrint(&meta_buf, "event: meta\ndata: {{\"ip\":\"{s}\",\"visit_count\":{d},\"country\":\"{s}\"}}\n\n", .{
        ip, visit_count, country,
    }) catch "";
    _ = stream.writeAll(meta) catch {};

    // Stream tokens via callback
    const StreamCtx = struct {
        s: std.net.Stream,
        fn onChunk(ctx_ptr: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            // SSE format: event: token\ndata: <chunk>\n\n
            self.s.writeAll("event: token\ndata: ") catch return;
            self.s.writeAll(chunk) catch return;
            self.s.writeAll("\n\n") catch return;
        }
    };
    var ctx = StreamCtx{ .s = stream };

    _ = ai.explainIpStream(app.ai_cfg, res.arena, .{
        .ip = ip,
        .country = country,
        .visit_count = visit_count,
        .classifications = cls_buf.items,
        .paths = paths.items,
        .user_agents = ua_list.items,
    }, .{
        .ctx = @ptrCast(&ctx),
        .on_chunk = StreamCtx.onChunk,
    });

    // Send done event
    _ = stream.writeAll("event: done\ndata: {}\n\n") catch {};
}

// =================================================================
// AI: DAILY DIGEST
// =================================================================
const DigestRecord = struct {
    generated_at: i64,
    window_hours: u32,
    summary: []const u8,
    metrics: DigestMetrics,
};

const DigestMetrics = struct {
    total_visits: u64,
    self_visits: u64,
    bot_visits: u64,
    scanner_visits: u64,
    unknown_visits: u64,
    distinct_ips: u32,
    auto_bans: u32,
    failed_logins: u32,
    successful_logins: u32,
    uptime_failures: u32,
};

fn digestLoop(app: *App) void {
    // Wait 5 minutes after boot before the first digest, so we have data.
    std.Thread.sleep(5 * 60 * std.time.ns_per_s);
    while (true) {
        runDigest(app) catch {};
        // Sleep 24 hours
        std.Thread.sleep(24 * 60 * 60 * std.time.ns_per_s);
    }
}

fn runDigest(app: *App) !void {
    if (!app.ai_cfg.enabled()) return;
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    app.store_mutex.lock();
    const visits = readVisitsFresh(app, a, 50000) catch {
        app.store_mutex.unlock();
        return;
    };
    const uptime_records = store.readLatestUptime(a, uptime_path) catch &.{};
    app.store_mutex.unlock();

    const window_hours: u32 = 24;
    const since = std.time.timestamp() - @as(i64, @intCast(window_hours)) * 3600;

    var metrics = DigestMetrics{
        .total_visits = 0,
        .self_visits = 0,
        .bot_visits = 0,
        .scanner_visits = 0,
        .unknown_visits = 0,
        .distinct_ips = 0,
        .auto_bans = 0,
        .failed_logins = 0,
        .successful_logins = 0,
        .uptime_failures = 0,
    };

    var ips = std.StringHashMap(void).init(a);
    var path_counts = std.StringHashMap(u32).init(a);
    var country_counts = std.StringHashMap(u32).init(a);

    for (visits) |v| {
        if (v.visited_at < since) continue;
        metrics.total_visits += 1;
        if (v.ip.len > 0) ips.put(v.ip, {}) catch {};
        if (std.mem.eql(u8, v.classification, "self")) metrics.self_visits += 1;
        if (std.mem.eql(u8, v.classification, "bot")) metrics.bot_visits += 1;
        if (std.mem.eql(u8, v.classification, "scanner")) {
            metrics.scanner_visits += 1;
            const gop = path_counts.getOrPut(v.path) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
        if (std.mem.eql(u8, v.classification, "unknown")) metrics.unknown_visits += 1;
        if (v.country.len > 0) {
            const gop = country_counts.getOrPut(v.country) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }
    metrics.distinct_ips = @intCast(ips.count());

    for (uptime_records) |r| {
        if (r.checked_at >= since and !r.ok) metrics.uptime_failures += 1;
    }

    const logins = security.readLoginAttempts(a, 500) catch &.{};
    for (logins) |la| {
        if (la.timestamp < since) continue;
        if (la.success) metrics.successful_logins += 1 else metrics.failed_logins += 1;
    }

    const bl_snapshot = app.blocklist.snapshot(a) catch &.{};
    for (bl_snapshot) |b| {
        if (b.blocked_at >= since and std.mem.startsWith(u8, b.reason, "auto:")) {
            metrics.auto_bans += 1;
        }
    }

    const top_paths = topN(a, &path_counts, 5);
    const top_countries = topN(a, &country_counts, 5);

    const summary = ai.dailyDigest(app.ai_cfg, a, .{
        .window_hours = window_hours,
        .total_visits = metrics.total_visits,
        .self_visits = metrics.self_visits,
        .bot_visits = metrics.bot_visits,
        .scanner_visits = metrics.scanner_visits,
        .unknown_visits = metrics.unknown_visits,
        .distinct_ips = metrics.distinct_ips,
        .auto_bans_24h = metrics.auto_bans,
        .failed_logins_24h = metrics.failed_logins,
        .successful_logins_24h = metrics.successful_logins,
        .uptime_probe_count = @intCast(uptime_records.len),
        .uptime_failures = metrics.uptime_failures,
        .top_scanner_paths = top_paths,
        .top_countries = top_countries,
    }) orelse return;

    const rec = DigestRecord{
        .generated_at = std.time.timestamp(),
        .window_hours = window_hours,
        .summary = summary,
        .metrics = metrics,
    };
    store.appendJson(digests_path, rec) catch {};
    app.bus.publish(.digest_ready, .{ .timestamp = rec.generated_at, .summary = rec.summary });
}

fn topN(allocator: std.mem.Allocator, map: *std.StringHashMap(u32), n: usize) [][]const u8 {
    const Pair = struct { k: []const u8, c: u32 };
    var pairs = std.ArrayList(Pair).init(allocator);
    var it = map.iterator();
    while (it.next()) |e| pairs.append(.{ .k = e.key_ptr.*, .c = e.value_ptr.* }) catch {};
    std.mem.sort(Pair, pairs.items, {}, struct {
        fn less(_: void, a: Pair, b: Pair) bool {
            return a.c > b.c;
        }
    }.less);
    const take = @min(n, pairs.items.len);
    var out = allocator.alloc([]const u8, take) catch return &.{};
    for (pairs.items[0..take], 0..) |p, i| {
        out[i] = std.fmt.allocPrint(allocator, "{s} ({d})", .{ p.k, p.c }) catch p.k;
    }
    return out;
}

fn apiDigestLatest(_: *App, res: *httpz.Response) !void {
    const file = std.fs.cwd().openFile(digests_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try res.json(.{ .ok = true, .latest = null }, .{});
            return;
        },
        else => return err,
    };
    defer file.close();
    const data = try file.readToEndAlloc(res.arena, 4 * 1024 * 1024);

    // Find last newline-delimited record
    var last_start: usize = 0;
    var i: usize = data.len;
    while (i > 0) {
        i -= 1;
        if (data[i] == '\n' and i + 1 < data.len) {
            last_start = i + 1;
            break;
        }
    }
    const last_line = std.mem.trim(u8, data[last_start..], " \t\r\n");
    if (last_line.len == 0) {
        try res.json(.{ .ok = true, .latest = null }, .{});
        return;
    }
    const parsed = std.json.parseFromSlice(DigestRecord, res.arena, last_line, .{ .ignore_unknown_fields = true }) catch {
        try res.json(.{ .ok = true, .latest = null }, .{});
        return;
    };
    try res.json(.{ .ok = true, .latest = parsed.value }, .{});
}

fn apiDigestRun(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (!app.ai_cfg.enabled()) {
        res.status = 503;
        try res.json(.{ .ok = false, .err = "ai_disabled" }, .{});
        return;
    }
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const ok = blk: {
        runDigest(app) catch break :blk false;
        break :blk true;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "digest_run",
        .target = "manual",
        .ok = ok,
    });
    if (!ok) {
        res.status = 502;
        try res.json(.{ .ok = false, .err = "digest_failed" }, .{});
        return;
    }
    try res.json(.{ .ok = true }, .{});
}

// =================================================================
// AUDIT LOG
// =================================================================
fn apiAudit(_: *App, res: *httpz.Response) !void {
    const entries = audit.read(res.arena, 100) catch &[_]audit.Entry{};
    try res.json(.{ .ok = true, .entries = entries }, .{});
}

// =================================================================
// TUNNEL HEALTH
// =================================================================
fn apiTunnelHealth(app: *App, res: *httpz.Response) !void {
    app.tunnel_status.mutex.lock();
    const state = app.tunnel_status.state;
    const last_check = app.tunnel_status.last_check;
    const state_since = app.tunnel_status.state_since;
    const conns = app.tunnel_status.connections;
    const restart_attempted = app.tunnel_status.restart_attempted;
    app.tunnel_status.mutex.unlock();
    try res.json(.{
        .ok = true,
        .state = tunnel_health.stateLabel(state),
        .last_check = last_check,
        .state_since = state_since,
        .connections = conns,
        .restart_attempted = restart_attempted,
    }, .{});
}

// =================================================================
// GEOBLOCK
// =================================================================
fn apiGeoblockGet(app: *App, res: *httpz.Response) !void {
    const snap = app.geoblock.snapshot(res.arena) catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "snapshot_failed" }, .{});
        return;
    };
    try res.json(.{
        .ok = true,
        .enabled = snap.enabled,
        .allow = snap.allow,
    }, .{});
}

fn apiGeoblockUpdate(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const enabled_str = form.get("enabled") orelse "off";
    const allow_csv = form.get("allow") orelse "";
    const enabled = std.mem.eql(u8, enabled_str, "on") or std.mem.eql(u8, enabled_str, "true") or std.mem.eql(u8, enabled_str, "1");

    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    app.geoblock.update(enabled, allow_csv) catch {
        audit.append(.{
            .timestamp = std.time.timestamp(),
            .actor = actor,
            .action = "geoblock_update",
            .target = if (enabled) "on" else "off",
            .detail = allow_csv,
            .ok = false,
        });
        res.status = 500;
        try res.json(.{ .ok = false, .err = "update_failed" }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "geoblock_update",
        .target = if (enabled) "on" else "off",
        .detail = allow_csv,
    });
    try res.json(.{ .ok = true }, .{});
}

// =================================================================
// AI: EMBEDDINGS (async, fire-and-forget, dedup by key)
// =================================================================
const EmbedArgs = struct {
    app: *App,
    key: []u8,
};

fn spawnEmbedRequest(app: *App, ua: []const u8, path: []const u8) !void {
    if (!app.ai_cfg.enabled()) return;
    // Cheap: skip if path looks like a static asset (we already filter most of these out
    // by classification, this is just belt-and-suspenders).
    if (std.mem.endsWith(u8, path, ".css") or std.mem.endsWith(u8, path, ".js") or
        std.mem.endsWith(u8, path, ".woff2") or std.mem.endsWith(u8, path, ".ico")) return;

    const key = embeddings.keyForRequest(app.allocator, ua, path) catch return;
    // Skip if we already have it (cheap lookup, no API call)
    {
        app.embeddings.mutex.lock();
        const known = app.embeddings.index.contains(key);
        app.embeddings.mutex.unlock();
        if (known) {
            // Just bump hit counter, no API call needed
            _ = app.embeddings.upsert(key, &[_]f32{}) catch {};
            app.allocator.free(key);
            return;
        }
    }

    const args = try app.allocator.create(EmbedArgs);
    args.* = .{ .app = app, .key = key };
    const t = try std.Thread.spawn(.{}, embedRequestThread, .{args});
    t.detach();
}

fn embedRequestThread(args: *EmbedArgs) void {
    defer {
        args.app.allocator.free(args.key);
        args.app.allocator.destroy(args);
    }
    var arena = std.heap.ArenaAllocator.init(args.app.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const vec = ai.embed(args.app.ai_cfg, a, args.key) orelse return;
    const is_new = args.app.embeddings.upsert(args.key, vec) catch return;

    // Anomaly detection: if this is a genuinely new pattern, check how far it is
    // from existing clusters. If distant, ask AI to classify it.
    if (is_new and args.app.embeddings.count() > 5) {
        const neighbors = args.app.embeddings.topK(a, vec, 1) catch return;
        const nearest_sim: f32 = if (neighbors.len > 0) neighbors[0].similarity else 0;
        const nearest_key: ?[]const u8 = if (neighbors.len > 0) neighbors[0].key else null;

        // Only flag if the pattern is far from everything known (< 0.7 cosine)
        if (nearest_sim < 0.7) {
            const explanation = ai.explainAnomaly(args.app.ai_cfg, a, .{
                .pattern_key = args.key,
                .nearest_cluster_rep = nearest_key,
                .nearest_similarity = nearest_sim,
                .sample_paths = &.{args.key}, // key IS the ua|path pattern
            }) orelse return;

            // Parse and publish as SSE event
            const Parsed = struct {
                novelty: []const u8,
                summary: []const u8,
                recommended_attention: []const u8,
            };
            const parsed = std.json.parseFromSlice(Parsed, a, explanation, .{
                .ignore_unknown_fields = true,
            }) catch return;

            args.app.bus.publish(.anomaly_detected, .{
                .pattern = args.key,
                .novelty = parsed.value.novelty,
                .summary = parsed.value.summary,
                .attention = parsed.value.recommended_attention,
                .nearest_similarity = nearest_sim,
                .timestamp = std.time.timestamp(),
            });

            // Persist to anomaly log
            const log_path = "/data/data/com.termux/files/home/data/anomalies.jsonl";
            store.appendJson(log_path, .{
                .timestamp = std.time.timestamp(),
                .pattern = args.key,
                .novelty = parsed.value.novelty,
                .summary = parsed.value.summary,
                .attention = parsed.value.recommended_attention,
                .nearest_similarity = nearest_sim,
            }) catch {};
        }
    }
}

// =================================================================
// API: embeddings cluster summary
// =================================================================
fn apiEmbeddingsStats(app: *App, res: *httpz.Response) !void {
    try res.json(.{
        .ok = true,
        .count = app.embeddings.count(),
        .max_entries = 4096,
    }, .{});
}

fn apiEmbeddingsClusters(app: *App, res: *httpz.Response) !void {
    const groups = app.embeddings.cluster(res.arena, 0.85) catch {
        try res.json(.{ .ok = false, .err = "cluster_failed" }, .{});
        return;
    };
    try res.json(.{
        .ok = true,
        .threshold = 0.85,
        .total_entries = app.embeddings.count(),
        .clusters = groups,
    }, .{});
}

// =================================================================
// AI: NATURAL LANGUAGE QUERY
// =================================================================
fn apiAiQuery(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (!app.ai_cfg.enabled()) {
        res.status = 503;
        try res.json(.{ .ok = false, .err = "ai_disabled" }, .{});
        return;
    }
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const question = form.get("q") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_q" }, .{});
        return;
    };

    // Semantic cache: embed the question and check if we've answered something similar recently.
    const q_embedding = ai.embed(app.ai_cfg, res.arena, question);
    if (q_embedding) |emb| {
        if (app.semantic_cache.lookup(emb, res.arena)) |cached_response| {
            // Cache hit! Return the cached result directly.
            ai.SemanticCache.recordHit(app.ai_cfg);
            res.content_type = .JSON;
            res.body = cached_response;
            return;
        }
    }

    const plan_json = ai.planQuery(app.ai_cfg, res.arena, question) orelse {
        res.status = 502;
        try res.json(.{ .ok = false, .err = "plan_failed" }, .{});
        return;
    };

    var out = std.ArrayList(u8).init(res.arena);
    query.execute(res.arena, plan_json, .{
        .blocklist = app.blocklist,
        .store_mutex = app.store_mutex,
        .dbcache = app.dbcache,
    }, &out) catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "execute_failed" }, .{});
        return;
    };

    // Store in semantic cache for future similar queries
    if (q_embedding) |emb| {
        app.semantic_cache.put(question, emb, out.items);
    }
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, out.items);
}

// =================================================================
// AI: WEEKLY POLICY REVIEW
// =================================================================
const PolicyRecord = struct {
    generated_at: i64,
    window_days: u32,
    overall_summary: []const u8,
    suggestions: []const Suggestion,

    const Suggestion = struct {
        ip: []const u8,
        suggested_action: []const u8,
        risk_score: u8,
        rationale: []const u8,
    };
};

fn policyLoop(app: *App) void {
    // First run: 30 minutes after boot (so we have data + the digest finished too)
    std.Thread.sleep(30 * 60 * std.time.ns_per_s);
    while (true) {
        runPolicyReview(app) catch {};
        // Sleep 7 days
        std.Thread.sleep(7 * 24 * 60 * 60 * std.time.ns_per_s);
    }
}

fn runPolicyReview(app: *App) !void {
    if (!app.ai_cfg.enabled()) return;
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    app.store_mutex.lock();
    const visits = readVisitsFresh(app, a, 100000) catch {
        app.store_mutex.unlock();
        return;
    };
    app.store_mutex.unlock();

    const window_days: u32 = 7;
    const since = std.time.timestamp() - @as(i64, @intCast(window_days)) * 24 * 3600;

    // Per-IP aggregation
    const PerIp = struct {
        country: []const u8 = "",
        total: u32 = 0,
        scanner: u32 = 0,
        bot: u32 = 0,
        unknown: u32 = 0,
        self: u32 = 0,
        recent_paths: std.ArrayList([]const u8),
    };
    var ips = std.StringHashMap(PerIp).init(a);

    for (visits) |v| {
        if (v.visited_at < since) continue;
        if (v.ip.len == 0) continue;
        const gop = ips.getOrPut(v.ip) catch continue;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .recent_paths = std.ArrayList([]const u8).init(a),
            };
        }
        gop.value_ptr.total += 1;
        if (v.country.len > 0) gop.value_ptr.country = v.country;
        if (std.mem.eql(u8, v.classification, "scanner")) gop.value_ptr.scanner += 1;
        if (std.mem.eql(u8, v.classification, "bot")) gop.value_ptr.bot += 1;
        if (std.mem.eql(u8, v.classification, "unknown")) gop.value_ptr.unknown += 1;
        if (std.mem.eql(u8, v.classification, "self")) gop.value_ptr.self += 1;
        if (gop.value_ptr.recent_paths.items.len < 4) {
            gop.value_ptr.recent_paths.append(v.path) catch {};
        }
    }

    // Format up to 30 most-active non-self IPs
    var summaries = std.ArrayList([]const u8).init(a);
    var it = ips.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.self > e.value_ptr.scanner + e.value_ptr.bot + e.value_ptr.unknown) continue;
        if (e.value_ptr.total < 2) continue;
        var line = std.ArrayList(u8).init(a);
        try line.writer().print("ip={s} country={s} total={d} scanner={d} bot={d} unknown={d} paths=[", .{
            e.key_ptr.*,
            if (e.value_ptr.country.len > 0) e.value_ptr.country else "?",
            e.value_ptr.total,
            e.value_ptr.scanner,
            e.value_ptr.bot,
            e.value_ptr.unknown,
        });
        for (e.value_ptr.recent_paths.items, 0..) |p, i| {
            if (i > 0) try line.appendSlice(",");
            try line.appendSlice(p);
        }
        try line.appendSlice("]");
        try summaries.append(try line.toOwnedSlice());
        if (summaries.items.len >= 30) break;
    }
    if (summaries.items.len == 0) return;

    const result_json = ai.weeklyPolicyReview(app.ai_cfg, a, .{
        .window_days = window_days,
        .ip_summaries = summaries.items,
    }) orelse return;

    // Parse for storage
    const Parsed = struct {
        overall_summary: []const u8,
        suggestions: []const PolicyRecord.Suggestion,
    };
    const parsed = std.json.parseFromSlice(Parsed, a, result_json, .{
        .ignore_unknown_fields = true,
    }) catch return;

    const rec = PolicyRecord{
        .generated_at = std.time.timestamp(),
        .window_days = window_days,
        .overall_summary = parsed.value.overall_summary,
        .suggestions = parsed.value.suggestions,
    };
    store.appendJson(policy_path, rec) catch {};
}

fn apiPolicyLatest(_: *App, res: *httpz.Response) !void {
    const file = std.fs.cwd().openFile(policy_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try res.json(.{ .ok = true, .latest = null }, .{});
            return;
        },
        else => return err,
    };
    defer file.close();
    const data = try file.readToEndAlloc(res.arena, 8 * 1024 * 1024);

    var last_start: usize = 0;
    var i: usize = data.len;
    while (i > 0) {
        i -= 1;
        if (data[i] == '\n' and i + 1 < data.len) {
            last_start = i + 1;
            break;
        }
    }
    const last_line = std.mem.trim(u8, data[last_start..], " \t\r\n");
    if (last_line.len == 0) {
        try res.json(.{ .ok = true, .latest = null }, .{});
        return;
    }
    const parsed = std.json.parseFromSlice(PolicyRecord, res.arena, last_line, .{
        .ignore_unknown_fields = true,
    }) catch {
        try res.json(.{ .ok = true, .latest = null }, .{});
        return;
    };
    try res.json(.{ .ok = true, .latest = parsed.value }, .{});
}

fn apiPolicyRun(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (!app.ai_cfg.enabled()) {
        res.status = 503;
        try res.json(.{ .ok = false, .err = "ai_disabled" }, .{});
        return;
    }
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const ok = blk: {
        runPolicyReview(app) catch break :blk false;
        break :blk true;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "policy_run",
        .target = "manual",
        .ok = ok,
    });
    if (!ok) {
        res.status = 502;
        try res.json(.{ .ok = false, .err = "policy_failed" }, .{});
        return;
    }
    try res.json(.{ .ok = true }, .{});
}

// =================================================================
// HONEYPOT (toggle + status)
// =================================================================
fn apiHoneypotGet(app: *App, res: *httpz.Response) !void {
    try res.json(.{
        .ok = true,
        .enabled = app.honeypot.isEnabled(),
        .cached_responses = app.honeypot.cache.count(),
    }, .{});
}

fn apiHoneypotUpdate(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const enabled_str = form.get("enabled") orelse "off";
    const enabled = std.mem.eql(u8, enabled_str, "on") or std.mem.eql(u8, enabled_str, "true") or std.mem.eql(u8, enabled_str, "1");

    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    app.honeypot.setEnabled(enabled) catch {
        audit.append(.{
            .timestamp = std.time.timestamp(),
            .actor = actor,
            .action = "honeypot_update",
            .target = if (enabled) "on" else "off",
            .ok = false,
        });
        res.status = 500;
        try res.json(.{ .ok = false, .err = "update_failed" }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "honeypot_update",
        .target = if (enabled) "on" else "off",
    });
    try res.json(.{ .ok = true }, .{});
}

// =================================================================
// AI USAGE / OBSERVABILITY
// =================================================================
fn apiAiUsage(app: *App, res: *httpz.Response) !void {
    app.ai_cfg.stats_mutex.lock();
    const total_calls = app.ai_cfg.total_calls;
    const prompt_tokens = app.ai_cfg.total_prompt_tokens;
    const completion_tokens = app.ai_cfg.total_completion_tokens;
    const cache_hits = app.ai_cfg.total_cache_hits;
    const failures = app.ai_cfg.total_failures;
    app.ai_cfg.stats_mutex.unlock();

    const total_tokens = prompt_tokens + completion_tokens;
    // Approximate cost: small model $0.15/M input + $0.60/M output
    const cost_usd = @as(f64, @floatFromInt(prompt_tokens)) * 0.15 / 1_000_000.0 +
        @as(f64, @floatFromInt(completion_tokens)) * 0.60 / 1_000_000.0;

    const buf = app.visit_buf.snapshot();

    try res.json(.{
        .ok = true,
        .total_calls = total_calls,
        .total_tokens = total_tokens,
        .prompt_tokens = prompt_tokens,
        .completion_tokens = completion_tokens,
        .cache_hits = cache_hits,
        .failures = failures,
        .semantic_cache_entries = app.semantic_cache.count(),
        .estimated_cost_usd = cost_usd,
        .uptime_seconds = std.time.timestamp() - app.started_at,
        .write_buffer = .{
            .pending_bytes = buf.pending_bytes,
            .last_flush = buf.last_flush,
            .total_appends = buf.total_appends,
            .total_flushes = buf.total_flushes,
            .total_bytes_written = buf.total_bytes_written,
        },
    }, .{});
}

// =================================================================
// RULES (operator-defined event handlers)
// =================================================================
fn apiRulesGet(app: *App, res: *httpz.Response) !void {
    const snap = app.rules.snapshot(res.arena) catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "snapshot_failed" }, .{});
        return;
    };
    const counters = app.rules.snapshotCounters(res.arena) catch &.{};
    try res.json(.{
        .ok = true,
        .rules = snap,
        .counters = counters,
    }, .{});
}

fn apiRulesReplace(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const body = req.body() orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_body" }, .{});
        return;
    };
    app.rules.replaceFromJson(body) catch |err| {
        const code: []const u8 = switch (err) {
            error.InvalidJson => "invalid_json",
            error.UnknownTrigger => "unknown_trigger",
            else => "replace_failed",
        };
        audit.append(.{
            .timestamp = std.time.timestamp(),
            .actor = actor,
            .action = "rules_replace",
            .target = "all",
            .detail = code,
            .ok = false,
        });
        res.status = 400;
        try res.json(.{ .ok = false, .err = code }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "rules_replace",
        .target = "all",
    });
    try res.json(.{ .ok = true }, .{});
}

// =================================================================
// DB CACHE (SQLite read-side cache for visits)
// =================================================================
fn apiDbCacheStats(app: *App, res: *httpz.Response) !void {
    const stats = app.dbcache.snapshot();
    try res.json(.{
        .ok = true,
        .row_count = stats.row_count,
        .sync_count = stats.sync_count,
        .rows_synced_total = stats.rows_synced_total,
        .last_sync_at = stats.last_sync_at,
        .last_sync_duration_ms = stats.last_sync_duration_ms,
    }, .{});
}

fn apiDbCacheSync(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    // Operator-triggered manual sync. Useful right after a backup restore or
    // manual JSONL edit. Audited.
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    // Flush write buffer first so any pending visits land in JSONL
    app.visit_buf.flush() catch |e| {
        std.log.warn("dbcache/sync: pre-flush failed: {}", .{e});
    };
    const rows = app.dbcache.sync() catch {
        audit.append(.{
            .timestamp = std.time.timestamp(),
            .actor = actor,
            .action = "dbcache_sync",
            .target = "manual",
            .ok = false,
        });
        res.status = 500;
        try res.json(.{ .ok = false, .err = "sync_failed" }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "dbcache_sync",
        .target = "manual",
    });
    try res.json(.{ .ok = true, .rows_synced = rows }, .{});
}

// =================================================================
// AI: LOG SCRUBBING (zero-day / unusual pattern detection)
// =================================================================
fn apiAiScrub(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (!app.ai_cfg.enabled()) {
        res.status = 503;
        try res.json(.{ .ok = false, .err = "ai_disabled" }, .{});
        return;
    }
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";

    // Pull top scanner paths from the dbcache (last 7 days)
    const top_paths = app.dbcache.topField(
        res.arena,
        "path",
        7 * 24 * 3600, // 7 days
        "scanner",
        50,
    ) catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "cache_query_failed" }, .{});
        return;
    };
    if (top_paths.len == 0) {
        try res.json(.{ .ok = true, .empty = true, .message = "no scanner traffic in last 7 days" }, .{});
        return;
    }

    // Pull top scanner UAs too
    const top_uas = app.dbcache.topField(
        res.arena,
        "ua",
        7 * 24 * 3600,
        "scanner",
        10,
    ) catch &.{};

    // Build the AI context
    var path_hits = std.ArrayList(ai.ScrubContext.PathHits).init(res.arena);
    for (top_paths) |row| {
        try path_hits.append(.{ .path = row.value, .hits = row.count });
    }
    var ua_list = std.ArrayList([]const u8).init(res.arena);
    for (top_uas) |row| try ua_list.append(row.value);

    const result_json = ai.scrubLogs(app.ai_cfg, res.arena, .{
        .scanner_paths = path_hits.items,
        .user_agents = ua_list.items,
    }) orelse {
        audit.append(.{
            .timestamp = std.time.timestamp(),
            .actor = actor,
            .action = "ai_scrub",
            .target = "manual",
            .ok = false,
        });
        res.status = 502;
        try res.json(.{ .ok = false, .err = "scrub_failed" }, .{});
        return;
    };

    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "ai_scrub",
        .target = "manual",
    });

    // Persist to ~/data/scrub.jsonl for history
    const scrub_path = "/data/data/com.termux/files/home/data/scrub.jsonl";
    store.appendJson(scrub_path, .{
        .timestamp = std.time.timestamp(),
        .scanner_paths_analysed = path_hits.items.len,
        .raw_response = result_json,
    }) catch {};

    res.content_type = .JSON;
    // result_json is already a complete JSON object from Mistral, wrap it
    var envelope = std.ArrayList(u8).init(res.arena);
    try envelope.appendSlice("{\"ok\":true,\"report\":");
    try envelope.appendSlice(result_json);
    try envelope.writer().print(",\"scanner_paths_analysed\":{d}}}", .{path_hits.items.len});
    res.body = try res.arena.dupe(u8, envelope.items);
}

// =================================================================
// HOSTED SITES (static site hosting at *.rofihosted.space)
// =================================================================
fn apiHostedStats(app: *App, res: *httpz.Response) !void {
    const json_body = app.hosted.statsJson(res.arena) catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "stats_failed" }, .{});
        return;
    };
    res.content_type = .JSON;
    res.body = json_body;
}

fn apiHostedList(app: *App, res: *httpz.Response) !void {
    _ = app;
    // Walk ~/hosted/sites/ and list every subdomain that has a current/ symlink.
    var dir = std.fs.openDirAbsolute(hosted.HOSTED_ROOT, .{ .iterate = true }) catch {
        try res.json(.{ .ok = true, .sites = &[_]u8{} }, .{});
        return;
    };
    defer dir.close();

    var out = std.ArrayList(u8).init(res.arena);
    const w = out.writer();
    try w.writeAll("{\"ok\":true,\"sites\":[");

    var it = dir.iterate();
    var first = true;
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        // Check if current symlink resolves
        const current = try std.fmt.allocPrint(res.arena, "{s}/{s}/current", .{ hosted.HOSTED_ROOT, entry.name });
        var rbuf: [std.fs.max_path_bytes]u8 = undefined;
        const target = std.fs.realpath(current, &rbuf) catch "";

        if (!first) try w.writeByte(',');
        first = false;
        try w.print(
            "{{\"subdomain\":\"{s}\",\"deployed\":{s},\"target\":\"{s}\"}}",
            .{ entry.name, if (target.len > 0) "true" else "false", target },
        );
    }
    try w.writeAll("]}");
    res.content_type = .JSON;
    res.body = try out.toOwnedSlice();
}

fn apiHostedRefresh(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    // Force-invalidate caches for a site (or all sites). Useful right after
    // an scp deploy + symlink swap done outside the server.
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const form = req.formData() catch null;
    const sub_opt = if (form) |f| f.get("subdomain") else null;
    if (sub_opt) |sub| {
        // Validate subdomain shape before operating on it
        pathsafe.validateSubdomain(sub) catch {
            res.status = 400;
            try res.json(.{ .ok = false, .err = "invalid_subdomain" }, .{});
            return;
        };
        app.hosted.bumpSite(sub);
        audit.append(.{
            .timestamp = std.time.timestamp(),
            .actor = actor,
            .action = "hosted_refresh",
            .target = sub,
        });
        try res.json(.{ .ok = true, .refreshed = sub }, .{});
        return;
    }
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "hosted_refresh",
        .target = "all",
    });
    // No subdomain provided - just succeed; sites lazy-init on next request.
    try res.json(.{ .ok = true, .refreshed = "lazy" }, .{});
}

// =================================================================
// SYSTEM SHELL (replaces SSH for the operator from anywhere)
// =================================================================

const SHELL_TIMEOUT_MS: u64 = 60_000;
const SHELL_MAX_OUTPUT: usize = 256 * 1024; // 256KB

fn apiSystemExec(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";

    // Body can be JSON {"cmd":"..."} or form-encoded cmd=...
    var cmd: []const u8 = "";
    var cwd_opt: ?[]const u8 = null;
    var timeout_ms: u64 = SHELL_TIMEOUT_MS;
    if (req.body()) |body| {
        if (body.len > 0 and body[0] == '{') {
            const Body = struct { cmd: []const u8 = "", cwd: []const u8 = "", timeout_ms: ?u64 = null };
            const parsed = std.json.parseFromSlice(Body, res.arena, body, .{ .ignore_unknown_fields = true }) catch {
                res.status = 400;
                try res.json(.{ .ok = false, .err = "bad_json" }, .{});
                return;
            };
            cmd = parsed.value.cmd;
            if (parsed.value.cwd.len > 0) cwd_opt = parsed.value.cwd;
            if (parsed.value.timeout_ms) |t| timeout_ms = @min(t, 300_000);
        }
    }
    if (cmd.len == 0) {
        const form = req.formData() catch {
            res.status = 400;
            try res.json(.{ .ok = false, .err = "bad_form" }, .{});
            return;
        };
        cmd = form.get("cmd") orelse "";
        if (form.get("cwd")) |c| if (c.len > 0) {
            cwd_opt = c;
        };
    }
    if (cmd.len == 0) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_cmd" }, .{});
        return;
    }
    if (cmd.len > 8192) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "cmd_too_long" }, .{});
        return;
    }

    // Resolve cwd. Default to operator $HOME so commands like 'ls' show
    // the home dir. Caller can pass a cwd hint for project work.
    const home = std.posix.getenv("HOME") orelse "/data/data/com.termux/files/home";
    const cwd: []const u8 = cwd_opt orelse home;

    var argv = [_][]const u8{ "sh", "-c", cmd };
    var child = std.process.Child.init(&argv, res.arena);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = cwd;

    const t0 = std.time.milliTimestamp();
    child.spawn() catch |err| {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "spawn_failed", .detail = @errorName(err) }, .{});
        return;
    };

    // Read stdout + stderr concurrently with cap. Block on wait, but enforce
    // wall-clock timeout via a watcher thread that sends SIGTERM.
    const KillerCtx = struct {
        pid: std.posix.pid_t,
        ms: u64,
        done: std.atomic.Value(bool),
    };
    var killer_ctx = KillerCtx{
        .pid = child.id,
        .ms = timeout_ms,
        .done = std.atomic.Value(bool).init(false),
    };
    const Killer = struct {
        fn run(ctx: *KillerCtx) void {
            const step_ms: u64 = 100;
            var elapsed: u64 = 0;
            while (elapsed < ctx.ms) {
                if (ctx.done.load(.acquire)) return;
                std.Thread.sleep(step_ms * std.time.ns_per_ms);
                elapsed += step_ms;
            }
            if (!ctx.done.load(.acquire)) {
                std.posix.kill(ctx.pid, std.posix.SIG.TERM) catch {};
                std.Thread.sleep(2 * std.time.ns_per_s);
                if (!ctx.done.load(.acquire)) {
                    std.posix.kill(ctx.pid, std.posix.SIG.KILL) catch {};
                }
            }
        }
    };
    const killer_thread = std.Thread.spawn(.{}, Killer.run, .{&killer_ctx}) catch null;

    var stdout_buf = std.ArrayList(u8).init(res.arena);
    var stderr_buf = std.ArrayList(u8).init(res.arena);
    var stdout_truncated = false;
    var stderr_truncated = false;

    if (child.stdout) |stdout| {
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = stdout.read(&tmp) catch break;
            if (n == 0) break;
            const remaining = SHELL_MAX_OUTPUT -| stdout_buf.items.len;
            const take = @min(n, remaining);
            try stdout_buf.appendSlice(tmp[0..take]);
            if (take < n) {
                stdout_truncated = true;
                break;
            }
        }
    }
    if (child.stderr) |stderr| {
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = stderr.read(&tmp) catch break;
            if (n == 0) break;
            const remaining = SHELL_MAX_OUTPUT -| stderr_buf.items.len;
            const take = @min(n, remaining);
            try stderr_buf.appendSlice(tmp[0..take]);
            if (take < n) {
                stderr_truncated = true;
                break;
            }
        }
    }

    const term = child.wait() catch |err| blk: {
        std.log.warn("apiSystemExec wait: {s}", .{@errorName(err)});
        break :blk std.process.Child.Term{ .Unknown = 0 };
    };
    killer_ctx.done.store(true, .release);
    if (killer_thread) |th| th.join();

    const exit_code: i32 = switch (term) {
        .Exited => |c| @intCast(c),
        .Signal => |s| -@as(i32, @intCast(s)),
        .Stopped => |s| -@as(i32, @intCast(s)),
        .Unknown => -1,
    };
    const elapsed_ms = std.time.milliTimestamp() - t0;
    const timed_out = elapsed_ms >= @as(i64, @intCast(timeout_ms));

    // Truncate cmd for audit log so we don't bloat the file
    const audit_cmd = if (cmd.len > 200) cmd[0..200] else cmd;
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "system_exec",
        .target = audit_cmd,
        .ok = exit_code == 0,
    });

    try res.json(.{
        .ok = true,
        .exit_code = exit_code,
        .timed_out = timed_out,
        .elapsed_ms = elapsed_ms,
        .stdout = stdout_buf.items,
        .stderr = stderr_buf.items,
        .stdout_truncated = stdout_truncated,
        .stderr_truncated = stderr_truncated,
        .cwd = cwd,
    }, .{});
}

fn apiSystemInfo(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = app;
    _ = req;

    const home = std.posix.getenv("HOME") orelse "/data/data/com.termux/files/home";

    // Battery via Termux:API if available; else null
    var battery_pct: ?i32 = null;
    var battery_status: []const u8 = "";
    var battery_buf: [4096]u8 = undefined;
    blk: {
        var argv = [_][]const u8{ "sh", "-c", "command -v termux-battery-status >/dev/null && termux-battery-status 2>/dev/null" };
        var child = std.process.Child.init(&argv, res.arena);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch break :blk;
        var n: usize = 0;
        if (child.stdout) |so| {
            n = so.readAll(&battery_buf) catch 0;
        }
        _ = child.wait() catch {};
        if (n == 0) break :blk;
        const body = battery_buf[0..n];
        // Tiny JSON peek: find "percentage" and "status"
        if (std.mem.indexOf(u8, body, "\"percentage\"")) |i| {
            var j = i + "\"percentage\"".len;
            while (j < body.len and (body[j] == ':' or body[j] == ' ')) : (j += 1) {}
            var end = j;
            while (end < body.len and (body[end] >= '0' and body[end] <= '9')) : (end += 1) {}
            battery_pct = std.fmt.parseInt(i32, body[j..end], 10) catch null;
        }
        if (std.mem.indexOf(u8, body, "\"status\"")) |i| {
            var j = i + "\"status\"".len;
            while (j < body.len and (body[j] == ':' or body[j] == ' ')) : (j += 1) {}
            if (j < body.len and body[j] == '"') {
                j += 1;
                const end = std.mem.indexOfScalarPos(u8, body, j, '"') orelse j;
                battery_status = try res.arena.dupe(u8, body[j..end]);
            }
        }
    }

    // Mem from /proc/meminfo
    var mem_total_kb: u64 = 0;
    var mem_avail_kb: u64 = 0;
    if (std.fs.openFileAbsolute("/proc/meminfo", .{})) |f| {
        defer f.close();
        var meminfo: [4096]u8 = undefined;
        const n = f.readAll(&meminfo) catch 0;
        const body = meminfo[0..n];
        if (std.mem.indexOf(u8, body, "MemTotal:")) |i| {
            mem_total_kb = parseFirstU64(body[i..]) orelse 0;
        }
        if (std.mem.indexOf(u8, body, "MemAvailable:")) |i| {
            mem_avail_kb = parseFirstU64(body[i..]) orelse 0;
        }
    } else |_| {}

    // Disk usage on $HOME via 'df' (1K-blocks) - Termux's busybox df does
    // not support -B, so we parse 1K columns and multiply.
    var disk_total_mb: u64 = 0;
    var disk_free_mb: u64 = 0;
    {
        const cmd = try std.fmt.allocPrint(res.arena, "df \"{s}\" 2>/dev/null | tail -1", .{home});
        var argv = [_][]const u8{ "sh", "-c", cmd };
        var child = std.process.Child.init(&argv, res.arena);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch {};
        var df_buf: [512]u8 = undefined;
        var n: usize = 0;
        if (child.stdout) |so| {
            n = so.readAll(&df_buf) catch 0;
        }
        _ = child.wait() catch {};
        // Format: filesystem 1K-blocks used available use% mountpoint
        if (n > 0) {
            var it = std.mem.tokenizeAny(u8, df_buf[0..n], " \t\n");
            _ = it.next(); // filesystem
            const total_s = it.next() orelse "0";
            _ = it.next(); // used
            const avail_s = it.next() orelse "0";
            const total_kb = std.fmt.parseInt(u64, total_s, 10) catch 0;
            const avail_kb = std.fmt.parseInt(u64, avail_s, 10) catch 0;
            disk_total_mb = total_kb / 1024;
            disk_free_mb = avail_kb / 1024;
        }
    }

    // System uptime via 'cat /proc/uptime' (often readable on Android) with
    // fallback to parsing 'uptime' command output. /proc/uptime can be EACCES
    // on hardened Android builds.
    var hp_uptime_s: u64 = 0;
    if (std.fs.openFileAbsolute("/proc/uptime", .{})) |f| {
        defer f.close();
        var buf: [128]u8 = undefined;
        const n = f.readAll(&buf) catch 0;
        const body = std.mem.trim(u8, buf[0..n], &std.ascii.whitespace);
        if (std.mem.indexOfScalar(u8, body, ' ')) |sp| {
            const total = std.fmt.parseFloat(f64, body[0..sp]) catch 0.0;
            hp_uptime_s = @intFromFloat(total);
        }
    } else |_| {}
    if (hp_uptime_s == 0) {
        // Fallback: 'uptime' prints "HH:MM:SS up X days, HH:MM, ..."
        var argv = [_][]const u8{ "sh", "-c", "uptime 2>/dev/null" };
        var child = std.process.Child.init(&argv, res.arena);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch {};
        var buf: [256]u8 = undefined;
        var n: usize = 0;
        if (child.stdout) |so| n = so.readAll(&buf) catch 0;
        _ = child.wait() catch {};
        if (n > 0) {
            const body = buf[0..n];
            if (std.mem.indexOf(u8, body, " up ")) |i| {
                const rest = body[i + 4 ..];
                // Find ', load' or end of segment
                const end = std.mem.indexOf(u8, rest, ",  load") orelse std.mem.indexOf(u8, rest, ", load") orelse rest.len;
                const seg = std.mem.trim(u8, rest[0..end], &std.ascii.whitespace);
                hp_uptime_s = parseUptimeSeg(seg);
            }
        }
    }

    try res.json(.{
        .ok = true,
        .battery_pct = battery_pct,
        .battery_status = battery_status,
        .mem_total_kb = mem_total_kb,
        .mem_avail_kb = mem_avail_kb,
        .disk_total_mb = disk_total_mb,
        .disk_free_mb = disk_free_mb,
        .system_uptime_s = hp_uptime_s,
        .home = home,
    }, .{});
}

fn apiSystemPower(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    const r = app.powermon.snapshot();
    const c = app.powermon.snapshotCounters();
    // raw status string is null-padded; trim before sending.
    var raw_end: usize = 0;
    while (raw_end < r.raw.len and r.raw[raw_end] != 0) : (raw_end += 1) {}
    try res.json(.{
        .ok = true,
        .available = r.available,
        .percentage = r.percentage,
        .status = r.status.label(),
        .status_raw = r.raw[0..raw_end],
        .last_check_unix = r.last_check_unix,
        .is_plugged = r.status.isPlugged(),
        .transitions_unplug = c.unplug,
        .transitions_replug = c.replug,
    }, .{});
}

fn apiSystemBackup(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    // Optional: ?target=local|r2 (default both: local always, r2 if rclone configured)
    const q = req.query() catch null;
    var target: []const u8 = "auto";
    if (q) |qq| if (qq.get("target")) |t| {
        target = t;
    };

    const home = std.posix.getenv("HOME") orelse "/data/data/com.termux/files/home";
    const script = if (std.mem.eql(u8, target, "local"))
        try std.fmt.allocPrint(res.arena, "{s}/backup-quick.sh", .{home})
    else
        try std.fmt.allocPrint(res.arena, "{s}/backup-r2.sh", .{home});

    var argv = [_][]const u8{ "sh", "-c", script };
    var child = std.process.Child.init(&argv, res.arena);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    const t0 = std.time.milliTimestamp();
    child.spawn() catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "spawn_failed" }, .{});
        return;
    };

    var out_buf = std.ArrayList(u8).init(res.arena);
    var err_buf = std.ArrayList(u8).init(res.arena);
    if (child.stdout) |so| {
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = so.read(&tmp) catch break;
            if (n == 0) break;
            try out_buf.appendSlice(tmp[0..n]);
            if (out_buf.items.len > 64 * 1024) break;
        }
    }
    if (child.stderr) |se| {
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = se.read(&tmp) catch break;
            if (n == 0) break;
            try err_buf.appendSlice(tmp[0..n]);
            if (err_buf.items.len > 64 * 1024) break;
        }
    }
    const term = child.wait() catch std.process.Child.Term{ .Unknown = 0 };
    const exit_code: i32 = switch (term) {
        .Exited => |c| @intCast(c),
        .Signal => |s| -@as(i32, @intCast(s)),
        else => -1,
    };
    const elapsed_ms = std.time.milliTimestamp() - t0;

    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "system_backup",
        .target = target,
        .ok = exit_code == 0,
    });

    // The scripts emit JSON-ish summary on the last stdout line; pass it
    // through but also wrap with the script's exit_code for the dashboard.
    try res.json(.{
        .ok = exit_code == 0,
        .target = target,
        .exit_code = exit_code,
        .elapsed_ms = elapsed_ms,
        .stdout = out_buf.items,
        .stderr = err_buf.items,
    }, .{});
}

fn apiSystemBackups(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    _ = app;
    const home = std.posix.getenv("HOME") orelse "/data/data/com.termux/files/home";

    // List local backups: ~/backups/rofihosted-*.tar.gz
    var local = std.ArrayList(struct { name: []const u8, size: u64, mtime: i64 }).init(res.arena);
    {
        const backups_dir = try std.fmt.allocPrint(res.arena, "{s}/backups", .{home});
        var dir = std.fs.openDirAbsolute(backups_dir, .{ .iterate = true }) catch null;
        if (dir) |*d| {
            defer d.close();
            var it = d.iterate();
            while (it.next() catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.startsWith(u8, entry.name, "rofihosted-")) continue;
                if (!std.mem.endsWith(u8, entry.name, ".tar.gz")) continue;
                const full = try std.fmt.allocPrint(res.arena, "{s}/{s}", .{ backups_dir, entry.name });
                const stat = std.fs.cwd().statFile(full) catch continue;
                try local.append(.{
                    .name = try res.arena.dupe(u8, entry.name),
                    .size = stat.size,
                    .mtime = @as(i64, @intCast(@divTrunc(stat.mtime, std.time.ns_per_s))),
                });
            }
        }
    }

    // List remote backups via rclone (best effort, may fail if R2 not configured)
    var remote_list = std.ArrayList(struct { name: []const u8, size: u64 }).init(res.arena);
    var r2_configured = false;
    {
        // Use 'sh -c' so we can source ~/.hp-server.env and get R2_BUCKET
        const cmd = "if [ -f ~/.hp-server.env ]; then . ~/.hp-server.env; fi; " ++
            "if [ -n \"${R2_BUCKET:-}\" ] && command -v rclone >/dev/null; then " ++
            "rclone lsl \"r2:${R2_BUCKET}/rofihosted/\" 2>/dev/null | head -50; fi";
        var argv = [_][]const u8{ "sh", "-c", cmd };
        var child = std.process.Child.init(&argv, res.arena);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch {};
        var buf = std.ArrayList(u8).init(res.arena);
        if (child.stdout) |so| {
            var tmp: [4096]u8 = undefined;
            while (true) {
                const n = so.read(&tmp) catch break;
                if (n == 0) break;
                try buf.appendSlice(tmp[0..n]);
                if (buf.items.len > 32 * 1024) break;
            }
        }
        _ = child.wait() catch {};
        // rclone lsl format: "  size YYYY-MM-DD HH:MM:SS.fff name"
        var lines = std.mem.tokenizeScalar(u8, buf.items, '\n');
        while (lines.next()) |line| {
            r2_configured = true;
            const trimmed = std.mem.trimLeft(u8, line, &std.ascii.whitespace);
            var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
            const size_s = it.next() orelse continue;
            _ = it.next() orelse continue; // date
            _ = it.next() orelse continue; // time
            const name = it.rest();
            const size = std.fmt.parseInt(u64, size_s, 10) catch continue;
            try remote_list.append(.{
                .name = try res.arena.dupe(u8, std.mem.trim(u8, name, &std.ascii.whitespace)),
                .size = size,
            });
        }
    }

    try res.json(.{
        .ok = true,
        .local = local.items,
        .remote = remote_list.items,
        .r2_configured = r2_configured,
    }, .{});
}

/// Read short git SHA + commit message from ~/rofihosted-src and
/// ~/zig/hp-server (binary). The dashboard uses this to show
/// "current vs latest" before triggering /api/system/update.
fn apiSystemVersion(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = app;
    _ = req;
    const home = std.posix.getenv("HOME") orelse "/data/data/com.termux/files/home";

    // Local commit (what's been built into the running binary): we can read
    // ~/rofihosted-src/.git/HEAD as the closest proxy.
    var local_sha: []const u8 = "";
    var local_subject: []const u8 = "";
    {
        const cmd = try std.fmt.allocPrint(
            res.arena,
            "cd {s}/rofihosted-src 2>/dev/null && git rev-parse --short HEAD 2>/dev/null && git log -1 --format=%s 2>/dev/null",
            .{home},
        );
        var argv = [_][]const u8{ "sh", "-c", cmd };
        var child = std.process.Child.init(&argv, res.arena);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch {};
        var buf = std.ArrayList(u8).init(res.arena);
        if (child.stdout) |so| {
            var tmp: [1024]u8 = undefined;
            while (true) {
                const n = so.read(&tmp) catch break;
                if (n == 0) break;
                try buf.appendSlice(tmp[0..n]);
            }
        }
        _ = child.wait() catch {};
        var lines = std.mem.tokenizeScalar(u8, buf.items, '\n');
        if (lines.next()) |s| local_sha = try res.arena.dupe(u8, std.mem.trim(u8, s, &std.ascii.whitespace));
        if (lines.next()) |s| local_subject = try res.arena.dupe(u8, std.mem.trim(u8, s, &std.ascii.whitespace));
    }

    // Remote commit (latest on origin/main). We do NOT fetch here to avoid
    // taking a network hit on every page load; instead we surface the
    // last-fetched ref. Operator hits /api/system/update to refresh.
    var remote_sha: []const u8 = "";
    var remote_subject: []const u8 = "";
    var fetched_at: i64 = 0;
    {
        const cmd = try std.fmt.allocPrint(
            res.arena,
            "cd {s}/rofihosted-src 2>/dev/null && git rev-parse --short origin/main 2>/dev/null && git log -1 origin/main --format=%s 2>/dev/null",
            .{home},
        );
        var argv = [_][]const u8{ "sh", "-c", cmd };
        var child = std.process.Child.init(&argv, res.arena);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch {};
        var buf = std.ArrayList(u8).init(res.arena);
        if (child.stdout) |so| {
            var tmp: [1024]u8 = undefined;
            while (true) {
                const n = so.read(&tmp) catch break;
                if (n == 0) break;
                try buf.appendSlice(tmp[0..n]);
            }
        }
        _ = child.wait() catch {};
        var lines = std.mem.tokenizeScalar(u8, buf.items, '\n');
        if (lines.next()) |s| remote_sha = try res.arena.dupe(u8, std.mem.trim(u8, s, &std.ascii.whitespace));
        if (lines.next()) |s| remote_subject = try res.arena.dupe(u8, std.mem.trim(u8, s, &std.ascii.whitespace));
        // mtime of FETCH_HEAD = when we last fetched
        const fetch_head = try std.fmt.allocPrint(res.arena, "{s}/rofihosted-src/.git/FETCH_HEAD", .{home});
        if (std.fs.cwd().statFile(fetch_head)) |st| {
            fetched_at = @as(i64, @intCast(@divTrunc(st.mtime, std.time.ns_per_s)));
        } else |_| {}
    }

    // Binary mtime for context
    var binary_built_at: i64 = 0;
    {
        const bin = try std.fmt.allocPrint(res.arena, "{s}/zig/hp-server/zig-out/bin/hp-server", .{home});
        if (std.fs.cwd().statFile(bin)) |st| {
            binary_built_at = @as(i64, @intCast(@divTrunc(st.mtime, std.time.ns_per_s)));
        } else |_| {}
    }

    try res.json(.{
        .ok = true,
        .local_sha = local_sha,
        .local_subject = local_subject,
        .remote_sha = remote_sha,
        .remote_subject = remote_subject,
        .last_fetch_unix = fetched_at,
        .binary_built_unix = binary_built_at,
        .up_to_date = std.mem.eql(u8, local_sha, remote_sha) and local_sha.len > 0,
    }, .{});
}

/// Run scripts/self-update.sh: git fetch, reset, rsync, rebuild, SIGTERM the
/// running hp-server. Watchdog respawns. Streaming a real-time progress feed
/// requires a separate SSE channel; for now we just wait for the script to
/// finish (rebuild can take 30-90s) and return its JSON summary.
fn apiSystemUpdate(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";

    const home = std.posix.getenv("HOME") orelse "/data/data/com.termux/files/home";
    const script = try std.fmt.allocPrint(res.arena, "{s}/self-update.sh", .{home});

    var argv = [_][]const u8{ "sh", "-c", script };
    var child = std.process.Child.init(&argv, res.arena);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    const t0 = std.time.milliTimestamp();
    child.spawn() catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "spawn_failed" }, .{});
        return;
    };

    // Drain output. Self-update.sh prints exactly one JSON line on stdout
    // and verbose stuff in ~/logs/self-update.log; we capture both for
    // visibility.
    var out_buf = std.ArrayList(u8).init(res.arena);
    var err_buf = std.ArrayList(u8).init(res.arena);
    if (child.stdout) |so| {
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = so.read(&tmp) catch break;
            if (n == 0) break;
            try out_buf.appendSlice(tmp[0..n]);
            if (out_buf.items.len > 32 * 1024) break;
        }
    }
    if (child.stderr) |se| {
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = se.read(&tmp) catch break;
            if (n == 0) break;
            try err_buf.appendSlice(tmp[0..n]);
            if (err_buf.items.len > 32 * 1024) break;
        }
    }
    const term = child.wait() catch std.process.Child.Term{ .Unknown = 0 };
    const exit_code: i32 = switch (term) {
        .Exited => |c| @intCast(c),
        .Signal => |s| -@as(i32, @intCast(s)),
        else => -1,
    };
    const elapsed_ms = std.time.milliTimestamp() - t0;

    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "system_update",
        .target = "hp-server",
        .ok = exit_code == 0,
    });

    // Pass the script's JSON line through unchanged (last non-empty line of
    // stdout). If we can't parse, fall back to wrapping with status info.
    const trimmed = std.mem.trim(u8, out_buf.items, &std.ascii.whitespace);
    if (trimmed.len > 0 and trimmed[0] == '{') {
        // Best effort: send the script's JSON directly so the dashboard can
        // read fields like before/after sha.
        res.content_type = .JSON;
        res.body = trimmed;
        return;
    }

    try res.json(.{
        .ok = exit_code == 0,
        .exit_code = exit_code,
        .elapsed_ms = elapsed_ms,
        .stdout = out_buf.items,
        .stderr = err_buf.items,
    }, .{});
}

/// Validate a backup tarball is restorable: download from R2 (if remote=true)
/// or use the latest local one, extract to a temp dir, sanity-check that
/// the project registry parses and at least one DB is non-empty. Reports a
/// pass/fail with details. Cleans up the temp dir at the end.
fn apiSystemRestoreTest(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const q = req.query() catch null;
    const source: []const u8 = if (q) |qq| (qq.get("source") orelse "local") else "local";

    const home = std.posix.getenv("HOME") orelse "/data/data/com.termux/files/home";

    // Build the shell script inline. Returns single JSON line on stdout.
    const cmd = try std.fmt.allocPrint(res.arena,
        \\set -e
        \\cd {s}
        \\source="{s}"
        \\tmp=$(mktemp -d)
        \\trap 'rm -rf "$tmp"' EXIT
        \\
        \\if [ "$source" = "r2" ]; then
        \\    if [ -f ~/.hp-server.env ]; then . ~/.hp-server.env; fi
        \\    if [ -z "${{R2_BUCKET:-}}" ]; then
        \\        echo '{{"ok":false,"err":"r2_not_configured"}}'
        \\        exit 0
        \\    fi
        \\    latest=$(rclone lsf "r2:${{R2_BUCKET}}/rofihosted/" 2>/dev/null | grep '^rofihosted-' | sort | tail -1)
        \\    if [ -z "$latest" ]; then
        \\        echo '{{"ok":false,"err":"no_remote_backups"}}'
        \\        exit 0
        \\    fi
        \\    rclone copy "r2:${{R2_BUCKET}}/rofihosted/$latest" "$tmp/" --no-traverse 2>/dev/null
        \\    tarball="$tmp/$latest"
        \\else
        \\    tarball=$(ls -1t ~/backups/rofihosted-*.tar.gz 2>/dev/null | head -1)
        \\    if [ -z "$tarball" ]; then
        \\        echo '{{"ok":false,"err":"no_local_backups"}}'
        \\        exit 0
        \\    fi
        \\    cp "$tarball" "$tmp/"
        \\    tarball="$tmp/$(basename "$tarball")"
        \\fi
        \\
        \\extract="$tmp/extract"
        \\mkdir -p "$extract"
        \\if ! tar xzf "$tarball" -C "$extract" 2>/dev/null; then
        \\    echo "{{\"ok\":false,\"err\":\"extract_failed\",\"tarball\":\"$(basename "$tarball")\"}}"
        \\    exit 0
        \\fi
        \\
        \\registry_path=$(find "$extract" -name '.hp-server-projects.jsonl' 2>/dev/null | head -1)
        \\dbs_dir=$(find "$extract" -type d -name 'dbs' 2>/dev/null | head -1)
        \\
        \\registry_lines=0
        \\if [ -n "$registry_path" ] && [ -f "$registry_path" ]; then
        \\    registry_lines=$(wc -l < "$registry_path" 2>/dev/null || echo 0)
        \\fi
        \\
        \\db_count=0
        \\db_total_bytes=0
        \\if [ -n "$dbs_dir" ]; then
        \\    db_count=$(find "$dbs_dir" -name '*.db' 2>/dev/null | wc -l)
        \\    db_total_bytes=$(find "$dbs_dir" -name '*.db' -exec stat -c %s {{}} \; 2>/dev/null | awk '{{sum+=$1}} END {{print sum+0}}')
        \\fi
        \\
        \\size=$(stat -c %s "$tarball" 2>/dev/null || echo 0)
        \\
        \\echo "{{\"ok\":true,\"tarball\":\"$(basename "$tarball")\",\"size_bytes\":$size,\"registry_lines\":$registry_lines,\"db_count\":$db_count,\"db_total_bytes\":$db_total_bytes,\"source\":\"$source\"}}"
    , .{ home, source });

    var argv = [_][]const u8{ "sh", "-c", cmd };
    var child = std.process.Child.init(&argv, res.arena);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "spawn_failed" }, .{});
        return;
    };
    var out_buf = std.ArrayList(u8).init(res.arena);
    var err_buf = std.ArrayList(u8).init(res.arena);
    if (child.stdout) |so| {
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = so.read(&tmp) catch break;
            if (n == 0) break;
            try out_buf.appendSlice(tmp[0..n]);
            if (out_buf.items.len > 16 * 1024) break;
        }
    }
    if (child.stderr) |se| {
        var tmp: [2048]u8 = undefined;
        while (true) {
            const n = se.read(&tmp) catch break;
            if (n == 0) break;
            try err_buf.appendSlice(tmp[0..n]);
            if (err_buf.items.len > 8 * 1024) break;
        }
    }
    _ = child.wait() catch {};

    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "system_restore_test",
        .target = source,
    });

    const trimmed = std.mem.trim(u8, out_buf.items, &std.ascii.whitespace);
    if (trimmed.len > 0 and trimmed[0] == '{') {
        res.content_type = .JSON;
        res.body = trimmed;
        return;
    }
    try res.json(.{
        .ok = false,
        .err = "no_json_output",
        .stdout = out_buf.items,
        .stderr = err_buf.items,
    }, .{});
}

fn parseFirstU64(s: []const u8) ?u64 {
    var i: usize = 0;
    // skip non-digits
    while (i < s.len and (s[i] < '0' or s[i] > '9')) : (i += 1) {}
    var end = i;
    while (end < s.len and s[end] >= '0' and s[end] <= '9') : (end += 1) {}
    if (end == i) return null;
    return std.fmt.parseInt(u64, s[i..end], 10) catch null;
}

/// Parse uptime segments like "2 days,  5:49" or "3 min" or "1:23".
fn parseUptimeSeg(s: []const u8) u64 {
    var total_s: u64 = 0;
    // Optional days
    if (std.mem.indexOf(u8, s, "day")) |di| {
        var j: usize = 0;
        while (j < di and (s[j] < '0' or s[j] > '9')) : (j += 1) {}
        var end = j;
        while (end < di and s[end] >= '0' and s[end] <= '9') : (end += 1) {}
        if (end > j) {
            const d = std.fmt.parseInt(u64, s[j..end], 10) catch 0;
            total_s += d * 86400;
        }
    }
    // Find HH:MM after "days," or at start
    if (std.mem.indexOf(u8, s, ":")) |c| {
        // back up to start of digits
        var j = c;
        while (j > 0 and s[j - 1] >= '0' and s[j - 1] <= '9') : (j -= 1) {}
        const h = std.fmt.parseInt(u64, s[j..c], 10) catch 0;
        // forward to end of next digits
        var end = c + 1;
        while (end < s.len and s[end] >= '0' and s[end] <= '9') : (end += 1) {}
        const m = std.fmt.parseInt(u64, s[c + 1 .. end], 10) catch 0;
        total_s += h * 3600 + m * 60;
    } else if (std.mem.indexOf(u8, s, "min")) |mi| {
        var j: usize = 0;
        while (j < mi and (s[j] < '0' or s[j] > '9')) : (j += 1) {}
        var end = j;
        while (end < mi and s[end] >= '0' and s[end] <= '9') : (end += 1) {}
        if (end > j) {
            const m = std.fmt.parseInt(u64, s[j..end], 10) catch 0;
            total_s += m * 60;
        }
    }
    return total_s;
}

fn apiDbPoolStats(app: *App, res: *httpz.Response) !void {
    const s = app.dbpool.snapshot();
    try res.json(.{
        .ok = true,
        .workers = s.workers,
        .free = s.free,
        .total_queries = s.total_queries,
        .total_errors = s.total_errors,
        .total_respawns = s.total_respawns,
        .avg_latency_ms = s.avg_latency_ms,
    }, .{});
}

// =================================================================
// V1 PUBLIC API (X-API-Key auth, used by external scripts)
// =================================================================
const SQL_DB_ROOT = "/data/data/com.termux/files/home/data/dbs";

fn handleV1(app: *App, req: *httpz.Request, res: *httpz.Response, path: []const u8) !void {
    // GitHub webhook is unauthenticated at the X-API-Key layer - it's HMAC-verified per project.
    if (std.mem.startsWith(u8, path, "/v1/github/")) {
        const project_id = path["/v1/github/".len..];
        return handleGithubWebhook(app, req, res, project_id);
    }

    // Public stats endpoint for the marketing landing page. No auth, just
    // aggregate counters. CORS-enabled so rofihosted.space can fetch from
    // app.rofihosted.space.
    if (std.mem.eql(u8, path, "/v1/public/stats")) {
        return v1PublicStats(app, res);
    }

    // Extract API key
    const raw_key = req.header("x-api-key") orelse req.header("X-Api-Key") orelse "";
    if (raw_key.len == 0) {
        res.status = 401;
        try res.json(.{ .ok = false, .err = "missing_api_key", .hint = "send X-API-Key header" }, .{});
        return;
    }
    const rec_opt = app.apikey.verify(raw_key);
    const rec = rec_opt orelse {
        res.status = 401;
        try res.json(.{ .ok = false, .err = "invalid_api_key" }, .{});
        return;
    };

    if (std.mem.eql(u8, path, "/v1/whoami")) {
        try res.json(.{ .ok = true, .name = rec.name, .id = rec.id }, .{});
        return;
    }
    if (std.mem.eql(u8, path, "/v1/execute")) {
        if (!rec.hasScope(.sql)) {
            res.status = 403;
            try res.json(.{ .ok = false, .err = "scope_required", .scope = "sql" }, .{});
            return;
        }
        return v1Execute(app, req, res, rec);
    }

    // System admin endpoints (CI auto-deploy, monitoring, etc).
    // Require admin scope. These are mirrors of /api/system/* but with API
    // key auth instead of session cookie, so they're usable from CI pipelines.
    if (std.mem.eql(u8, path, "/v1/system/version")) {
        if (!rec.hasScope(.admin)) {
            res.status = 403;
            try res.json(.{ .ok = false, .err = "scope_required", .scope = "admin" }, .{});
            return;
        }
        return apiSystemVersion(app, req, res);
    }
    if (std.mem.eql(u8, path, "/v1/system/update")) {
        if (!rec.hasScope(.admin)) {
            res.status = 403;
            try res.json(.{ .ok = false, .err = "scope_required", .scope = "admin" }, .{});
            return;
        }
        return apiSystemUpdate(app, req, res);
    }
    if (std.mem.eql(u8, path, "/v1/system/info")) {
        if (!rec.hasScope(.admin)) {
            res.status = 403;
            try res.json(.{ .ok = false, .err = "scope_required", .scope = "admin" }, .{});
            return;
        }
        return apiSystemInfo(app, req, res);
    }
    if (std.mem.eql(u8, path, "/v1/system/power")) {
        if (!rec.hasScope(.admin)) {
            res.status = 403;
            try res.json(.{ .ok = false, .err = "scope_required", .scope = "admin" }, .{});
            return;
        }
        return apiSystemPower(app, req, res);
    }
    if (std.mem.eql(u8, path, "/v1/system/backup")) {
        if (!rec.hasScope(.admin)) {
            res.status = 403;
            try res.json(.{ .ok = false, .err = "scope_required", .scope = "admin" }, .{});
            return;
        }
        return apiSystemBackup(app, req, res);
    }

    // Project management endpoints (admin scope). These mirror /api/projects/*
    // so the rh CLI / GitHub Actions can deploy without session cookies.
    if (std.mem.eql(u8, path, "/v1/projects")) {
        if (!rec.hasScope(.admin)) {
            res.status = 403;
            try res.json(.{ .ok = false, .err = "scope_required", .scope = "admin" }, .{});
            return;
        }
        return apiProjectsList(app, res);
    }
    if (std.mem.eql(u8, path, "/v1/projects/deploy")) {
        if (!rec.hasScope(.admin)) {
            res.status = 403;
            try res.json(.{ .ok = false, .err = "scope_required", .scope = "admin" }, .{});
            return;
        }
        return apiProjectsDeploy(app, req, res);
    }
    if (std.mem.eql(u8, path, "/v1/projects/upload")) {
        if (!rec.hasScope(.admin)) {
            res.status = 403;
            try res.json(.{ .ok = false, .err = "scope_required", .scope = "admin" }, .{});
            return;
        }
        return apiProjectsUpload(app, req, res);
    }
    if (std.mem.startsWith(u8, path, "/v1/projects/logs")) {
        if (!rec.hasScope(.admin)) {
            res.status = 403;
            try res.json(.{ .ok = false, .err = "scope_required", .scope = "admin" }, .{});
            return;
        }
        return apiProjectsLogs(app, req, res);
    }
    if (std.mem.startsWith(u8, path, "/v1/projects/runtime-logs")) {
        if (!rec.hasScope(.admin)) {
            res.status = 403;
            try res.json(.{ .ok = false, .err = "scope_required", .scope = "admin" }, .{});
            return;
        }
        return apiProjectsRuntimeLogs(app, req, res);
    }
    if (std.mem.startsWith(u8, path, "/v1/projects/status")) {
        if (!rec.hasScope(.admin)) {
            res.status = 403;
            try res.json(.{ .ok = false, .err = "scope_required", .scope = "admin" }, .{});
            return;
        }
        return apiProjectsStatus(app, req, res);
    }
    if (std.mem.eql(u8, path, "/v1/projects/create")) {
        if (!rec.hasScope(.admin)) {
            res.status = 403;
            try res.json(.{ .ok = false, .err = "scope_required", .scope = "admin" }, .{});
            return;
        }
        return apiProjectsCreate(app, req, res);
    }

    res.status = 404;
    try res.json(.{ .ok = false, .err = "unknown_endpoint" }, .{});
}

// =================================================================
// MCP (Model Context Protocol) - JSON-RPC 2.0 over POST /mcp
// =================================================================

fn handleMcpDiscovery(_: *App, res: *httpz.Response) !void {
    // Public discovery doc so Claude Desktop / Kiro / cursor can auto-config.
    res.header("Access-Control-Allow-Origin", "*");
    res.header("Cache-Control", "public, max-age=3600");
    try res.json(.{
        .name = "rofihosted-mcp",
        .version = mcp.SERVER_VERSION,
        .protocolVersion = mcp.PROTOCOL_VERSION,
        .description = "Manage a self-hosted PaaS running on a phone. Tools for projects, deploys, secrets, databases, security, backups.",
        .transport = "streamable-http",
        .endpoint = "https://app.rofihosted.space/mcp",
        .auth = .{
            .type = "bearer",
            .scope = "admin",
            .docs = "Create an admin API key at /settings, then send Authorization: Bearer <key> on every POST /mcp request.",
        },
    }, .{});
}

fn handleMcp(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    // Permissive CORS so browser-based MCP clients can connect.
    res.header("Access-Control-Allow-Origin", "*");
    res.header("Access-Control-Allow-Methods", "POST, OPTIONS, DELETE");
    res.header("Access-Control-Allow-Headers", "Content-Type, Authorization, Mcp-Session-Id");

    if (req.method == .OPTIONS) {
        res.status = 204;
        return;
    }
    if (req.method == .DELETE) {
        // Stateless server, but reply 200 for politeness so clients with
        // session-cleanup logic don't error out.
        res.status = 200;
        try res.json(.{ .ok = true }, .{});
        return;
    }
    if (req.method != .POST) {
        res.status = 405;
        try res.json(.{ .ok = false, .err = "method_not_allowed" }, .{});
        return;
    }

    // Auth: Authorization: Bearer <key>, admin scope.
    const auth_hdr = req.header("authorization") orelse req.header("Authorization") orelse "";
    var key: []const u8 = "";
    if (std.mem.startsWith(u8, auth_hdr, "Bearer ")) {
        key = auth_hdr["Bearer ".len..];
    } else if (auth_hdr.len > 0) {
        // Tolerate raw key without the Bearer prefix.
        key = auth_hdr;
    } else {
        // Fallback to X-API-Key for clients that prefer that header.
        key = req.header("x-api-key") orelse req.header("X-Api-Key") orelse "";
    }

    if (key.len == 0) {
        res.status = 401;
        try mcpJsonError(res, "null", -32001, "missing authorization (send Bearer <key>)");
        return;
    }
    const rec = app.apikey.verify(key) orelse {
        res.status = 401;
        try mcpJsonError(res, "null", -32002, "invalid api key");
        return;
    };
    if (!rec.hasScope(.admin)) {
        res.status = 403;
        try mcpJsonError(res, "null", -32003, "admin scope required");
        return;
    }

    const body_raw = req.body() orelse {
        res.status = 400;
        try mcpJsonError(res, "null", -32700, "missing body");
        return;
    };

    // Stash request id so we can echo it in errors. Default to "null".
    const id_json = extractRpcId(res.arena, body_raw) catch "null";

    // Minimal JSON parse: just pluck "method".
    const Req = struct {
        jsonrpc: ?[]const u8 = null,
        method: ?[]const u8 = null,
        params: ?std.json.Value = null,
        id: ?std.json.Value = null,
    };
    const parsed = std.json.parseFromSlice(Req, res.arena, body_raw, .{ .ignore_unknown_fields = true }) catch {
        res.status = 200; // JSON-RPC errors are 200 with error envelope
        try mcpJsonError(res, id_json, -32700, "parse error");
        return;
    };
    const method = parsed.value.method orelse {
        res.status = 200;
        try mcpJsonError(res, id_json, -32600, "missing method");
        return;
    };

    // ---- dispatch ----
    if (std.mem.eql(u8, method, "initialize")) {
        var buf = std.ArrayList(u8).init(res.arena);
        try mcp.writeInitializeResult(buf.writer());
        try mcpJsonResult(res, id_json, buf.items);
        return;
    }
    if (std.mem.eql(u8, method, "notifications/initialized")) {
        // Per spec: notifications get 202 with no body.
        res.status = 202;
        return;
    }
    if (std.mem.eql(u8, method, "ping")) {
        try mcpJsonResult(res, id_json, "{}");
        return;
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        var buf = std.ArrayList(u8).init(res.arena);
        try mcp.writeToolsList(buf.writer());
        try mcpJsonResult(res, id_json, buf.items);
        return;
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        return handleMcpToolCall(app, req, res, id_json, parsed.value.params);
    }

    // Unknown method
    try mcpJsonError(res, id_json, -32601, "method not found");
}

fn extractRpcId(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    // Find "id":<value>, return the raw value string. Handles numbers,
    // strings (returned with quotes), and null. Falls back to "null".
    const idx = std.mem.indexOf(u8, body, "\"id\"") orelse return "null";
    var i: usize = idx + 4;
    while (i < body.len and (body[i] == ' ' or body[i] == ':' or body[i] == '\t')) i += 1;
    if (i >= body.len) return "null";
    const start = i;
    if (body[i] == '"') {
        // String id - find closing quote, accounting for escaped quotes.
        i += 1;
        while (i < body.len and body[i] != '"') {
            if (body[i] == '\\' and i + 1 < body.len) i += 2 else i += 1;
        }
        if (i >= body.len) return "null";
        return arena.dupe(u8, body[start .. i + 1]);
    }
    // Number or null - find next non-digit/letter.
    while (i < body.len and body[i] != ',' and body[i] != '}' and body[i] != ' ' and body[i] != '\n' and body[i] != '\r' and body[i] != '\t') i += 1;
    return arena.dupe(u8, body[start..i]);
}

fn mcpJsonError(res: *httpz.Response, id_json: []const u8, code: i32, message: []const u8) !void {
    res.content_type = .JSON;
    var buf = std.ArrayList(u8).init(res.arena);
    try mcp.writeError(buf.writer(), id_json, code, message);
    res.body = try buf.toOwnedSlice();
}

fn mcpJsonResult(res: *httpz.Response, id_json: []const u8, result_json: []const u8) !void {
    res.content_type = .JSON;
    var buf = std.ArrayList(u8).init(res.arena);
    try mcp.writeResult(buf.writer(), id_json, result_json);
    res.body = try buf.toOwnedSlice();
}

fn mcpJsonToolText(res: *httpz.Response, id_json: []const u8, text: []const u8, is_error: bool) !void {
    res.content_type = .JSON;
    var buf = std.ArrayList(u8).init(res.arena);
    try mcp.writeToolResultText(buf.writer(), id_json, text, is_error);
    res.body = try buf.toOwnedSlice();
}

fn handleMcpToolCall(app: *App, req: *httpz.Request, res: *httpz.Response, id_json: []const u8, params_v: ?std.json.Value) !void {
    _ = req;
    const params = params_v orelse {
        try mcpJsonError(res, id_json, -32602, "missing params");
        return;
    };
    if (params != .object) {
        try mcpJsonError(res, id_json, -32602, "params must be an object");
        return;
    }
    const name_v = params.object.get("name") orelse {
        try mcpJsonError(res, id_json, -32602, "params.name required");
        return;
    };
    if (name_v != .string) {
        try mcpJsonError(res, id_json, -32602, "params.name must be a string");
        return;
    }
    const tool_name = name_v.string;
    const args_v = params.object.get("arguments");
    const args = if (args_v) |a| (if (a == .object) a.object else std.json.ObjectMap.init(res.arena)) else std.json.ObjectMap.init(res.arena);

    // Dispatch
    if (std.mem.eql(u8, tool_name, "get_system_info")) return mcpToolGetSystemInfo(app, res, id_json);
    if (std.mem.eql(u8, tool_name, "get_version")) return mcpToolGetVersion(app, res, id_json);
    if (std.mem.eql(u8, tool_name, "trigger_update")) return mcpToolTriggerUpdate(app, res, id_json);
    if (std.mem.eql(u8, tool_name, "exec_shell")) return mcpToolExecShell(app, res, id_json, args);

    if (std.mem.eql(u8, tool_name, "list_projects")) return mcpToolListProjects(app, res, id_json);
    if (std.mem.eql(u8, tool_name, "get_project_status")) return mcpToolProjectStatus(app, res, id_json, args);
    if (std.mem.eql(u8, tool_name, "start_project")) return mcpToolProjectAction(app, res, id_json, args, .start);
    if (std.mem.eql(u8, tool_name, "stop_project")) return mcpToolProjectAction(app, res, id_json, args, .stop);
    if (std.mem.eql(u8, tool_name, "restart_project")) return mcpToolProjectAction(app, res, id_json, args, .restart);
    if (std.mem.eql(u8, tool_name, "deploy_project")) return mcpToolProjectAction(app, res, id_json, args, .deploy);
    if (std.mem.eql(u8, tool_name, "read_build_log")) return mcpToolReadProjectLog(app, res, id_json, args, "build.log");
    if (std.mem.eql(u8, tool_name, "read_runtime_log")) return mcpToolReadProjectLog(app, res, id_json, args, "runtime.log");

    if (std.mem.eql(u8, tool_name, "list_secrets")) return mcpToolListSecrets(app, res, id_json, args);
    if (std.mem.eql(u8, tool_name, "set_secret")) return mcpToolSetSecret(app, res, id_json, args);
    if (std.mem.eql(u8, tool_name, "delete_secret")) return mcpToolDeleteSecret(app, res, id_json, args);

    if (std.mem.eql(u8, tool_name, "query_db")) return mcpToolDbQuery(app, res, id_json, args, true);
    if (std.mem.eql(u8, tool_name, "exec_db")) return mcpToolDbQuery(app, res, id_json, args, false);
    if (std.mem.eql(u8, tool_name, "list_tables")) return mcpToolDbListTables(app, res, id_json, args);

    if (std.mem.eql(u8, tool_name, "list_blocked_ips")) return mcpToolListBlockedIps(app, res, id_json);
    if (std.mem.eql(u8, tool_name, "block_ip")) return mcpToolBlockIp(app, res, id_json, args);
    if (std.mem.eql(u8, tool_name, "unblock_ip")) return mcpToolUnblockIp(app, res, id_json, args);
    if (std.mem.eql(u8, tool_name, "search_audit")) return mcpToolSearchAudit(app, res, id_json, args);
    if (std.mem.eql(u8, tool_name, "list_recent_visits")) return mcpToolRecentVisits(app, res, id_json, args);

    if (std.mem.eql(u8, tool_name, "list_backups")) return mcpToolListBackups(app, res, id_json);
    if (std.mem.eql(u8, tool_name, "trigger_backup")) return mcpToolTriggerBackup(app, res, id_json, args);

    try mcpJsonError(res, id_json, -32602, "unknown tool");
}

// ===== MCP TOOL IMPLEMENTATIONS =====
// Each tool is a thin adapter: reads args, delegates to existing manager
// or shell, formats the response as a text block.

fn mcpToolGetSystemInfo(app: *App, res: *httpz.Response, id_json: []const u8) !void {
    const reading = app.powermon.snapshot();
    var buf = std.ArrayList(u8).init(res.arena);
    const w = buf.writer();
    try w.print("Battery: {d}%, status: {s}\n", .{ reading.percentage, reading.status.label() });
    try w.print("Plugged in: {s}\n", .{if (reading.status.isPlugged()) "yes" else "no (DANGER - phone bootloops without charger)"});
    try w.print("Uptime: {d}s\n", .{std.time.timestamp() - app.started_at});

    // Shell out for /proc info (mem + disk) - cheap and self-contained.
    const cmd = "free -m | awk '/^Mem:/ {print \"mem_total_mb=\"$2\" mem_avail_mb=\"$7}'; df -h /data/data/com.termux/files/home | awk 'NR==2 {print \"disk_used=\"$3\" disk_avail=\"$4\" disk_pct=\"$5}'";
    var argv = [_][]const u8{ "sh", "-c", cmd };
    var child = std.process.Child.init(&argv, app.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        try mcpJsonToolText(res, id_json, buf.items, false);
        return;
    };
    if (child.stdout) |stdout| {
        const data = stdout.readToEndAlloc(app.allocator, 8 * 1024) catch "";
        defer app.allocator.free(data);
        try w.writeAll(data);
    }
    _ = child.wait() catch {};
    try mcpJsonToolText(res, id_json, buf.items, false);
}

fn mcpToolGetVersion(app: *App, res: *httpz.Response, id_json: []const u8) !void {
    _ = app;
    var buf = std.ArrayList(u8).init(res.arena);
    const w = buf.writer();
    // Read git HEAD from src repo
    const cmd = "cd ~/rofihosted-src && echo \"local_sha=$(git rev-parse --short HEAD)\" && echo \"local_subject=$(git log -1 --format=%s)\" && git fetch --quiet origin main 2>/dev/null && echo \"remote_sha=$(git rev-parse --short origin/main)\" && echo \"binary_built=$(stat -c %Y ~/zig/hp-server/zig-out/bin/hp-server 2>/dev/null)\"";
    var argv = [_][]const u8{ "sh", "-c", cmd };
    var child = std.process.Child.init(&argv, res.arena);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        try mcpJsonToolText(res, id_json, "version probe failed", true);
        return;
    };
    if (child.stdout) |stdout| {
        const data = stdout.readToEndAlloc(res.arena, 4 * 1024) catch "";
        try w.writeAll(data);
    }
    _ = child.wait() catch {};
    try mcpJsonToolText(res, id_json, buf.items, false);
}

fn mcpToolTriggerUpdate(app: *App, res: *httpz.Response, id_json: []const u8) !void {
    _ = app;
    // Detached so we don't block the response
    var argv = [_][]const u8{ "sh", "-c", "nohup ~/self-update.sh > /tmp/mcp-update.out 2>&1 &" };
    var child = std.process.Child.init(&argv, res.arena);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        try mcpJsonToolText(res, id_json, "failed to spawn self-update.sh", true);
        return;
    };
    _ = child.wait() catch {};
    try mcpJsonToolText(res, id_json, "Update triggered. The phone will be unreachable for ~10s while the watchdog respawns the new binary. Check version after with get_version.", false);
}

fn mcpToolExecShell(app: *App, res: *httpz.Response, id_json: []const u8, args: std.json.ObjectMap) !void {
    _ = app;
    const cmd_v = args.get("cmd") orelse {
        try mcpJsonError(res, id_json, -32602, "cmd required");
        return;
    };
    if (cmd_v != .string) {
        try mcpJsonError(res, id_json, -32602, "cmd must be string");
        return;
    }
    const cmd = cmd_v.string;
    if (cmd.len == 0 or cmd.len > 8192) {
        try mcpJsonError(res, id_json, -32602, "cmd empty or too long");
        return;
    }
    const cwd_opt: ?[]const u8 = blk: {
        if (args.get("cwd")) |c| {
            if (c == .string and c.string.len > 0) break :blk c.string;
        }
        break :blk null;
    };

    // Spawn the shell command. We rely on the LLM to not send rm -rf /;
    // the admin scope is already a strong gate.
    var argv = [_][]const u8{ "sh", "-c", cmd };
    var child = std.process.Child.init(&argv, res.arena);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (cwd_opt) |c| child.cwd = c;
    child.spawn() catch {
        try mcpJsonToolText(res, id_json, "spawn failed", true);
        return;
    };

    var stdout_buf = std.ArrayList(u8).init(res.arena);
    var stderr_buf = std.ArrayList(u8).init(res.arena);
    if (child.stdout) |s| {
        const d = s.readToEndAlloc(res.arena, 256 * 1024) catch "";
        try stdout_buf.appendSlice(d);
    }
    if (child.stderr) |s| {
        const d = s.readToEndAlloc(res.arena, 256 * 1024) catch "";
        try stderr_buf.appendSlice(d);
    }
    const term = child.wait() catch std.process.Child.Term{ .Unknown = 0 };

    var out = std.ArrayList(u8).init(res.arena);
    const w = out.writer();
    const exit_code: i32 = switch (term) {
        .Exited => |c| @as(i32, @intCast(c)),
        .Signal => |s| -@as(i32, @intCast(s)),
        else => -1,
    };
    try w.print("exit={d}\n", .{exit_code});
    if (stdout_buf.items.len > 0) {
        try w.writeAll("--- stdout ---\n");
        try w.writeAll(stdout_buf.items);
        if (!std.mem.endsWith(u8, stdout_buf.items, "\n")) try w.writeByte('\n');
    }
    if (stderr_buf.items.len > 0) {
        try w.writeAll("--- stderr ---\n");
        try w.writeAll(stderr_buf.items);
    }
    try mcpJsonToolText(res, id_json, out.items, exit_code != 0);
}

// ===== project tools =====

fn mcpToolListProjects(app: *App, res: *httpz.Response, id_json: []const u8) !void {
    const json_blob = try app.projects.listJson(res.arena);
    var out = std.ArrayList(u8).init(res.arena);
    try out.writer().print("Project registry (raw JSON):\n{s}", .{json_blob});
    try mcpJsonToolText(res, id_json, out.items, false);
}

fn mcpArgString(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = args.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn mcpArgInt(args: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = args.get(key) orelse return null;
    if (v != .integer) return null;
    return v.integer;
}

fn mcpToolProjectStatus(app: *App, res: *httpz.Response, id_json: []const u8, args: std.json.ObjectMap) !void {
    const id = mcpArgString(args, "id") orelse {
        try mcpJsonError(res, id_json, -32602, "id required");
        return;
    };
    if (!isValidProjectId(id)) {
        try mcpJsonToolText(res, id_json, "invalid project id", true);
        return;
    }
    const proj_opt = app.projects.getById(id);
    const proj = proj_opt orelse {
        try mcpJsonToolText(res, id_json, "project not found", true);
        return;
    };
    const sup = app.supervisor.statusOf(id);
    var out = std.ArrayList(u8).init(res.arena);
    const w = out.writer();
    try w.print("id: {s}\nname: {s}\nsubdomain: {s}\nruntime: {s}\nstatus: {s}\nport: {d}\nrss_limit_mb: {d}\n", .{
        proj.id, proj.name, proj.subdomain, @tagName(proj.runtime), @tagName(proj.status), proj.port, proj.rss_limit_mb,
    });
    try w.print("supervisor_state: {s}\n", .{@tagName(sup.state)});
    if (sup.pid) |p| try w.print("pid: {d}\n", .{p});
    try w.print("rss_kb: {d}\nstarted_at: {d}\ncrash_count: {d}\nlast_exit: {d}\nlast_kill_reason: {s}\n", .{
        sup.rss_kb, sup.started_at, sup.crash_count, sup.last_exit, @tagName(sup.last_kill_reason),
    });
    try mcpJsonToolText(res, id_json, out.items, false);
}

const ProjectAction = enum { start, stop, restart, deploy };

fn mcpToolProjectAction(app: *App, res: *httpz.Response, id_json: []const u8, args: std.json.ObjectMap, action: ProjectAction) !void {
    const id = mcpArgString(args, "id") orelse {
        try mcpJsonError(res, id_json, -32602, "id required");
        return;
    };
    if (!isValidProjectId(id)) {
        try mcpJsonToolText(res, id_json, "invalid project id", true);
        return;
    }
    const proj_opt = app.projects.getById(id);
    const proj = proj_opt orelse {
        try mcpJsonToolText(res, id_json, "project not found", true);
        return;
    };
    var msg_buf: [256]u8 = undefined;
    switch (action) {
        .start => {
            if (proj.runtime == .static) {
                _ = app.projects.update(id, .{ .status = .running }) catch {};
                try mcpJsonToolText(res, id_json, "static project marked running", false);
            } else {
                app.supervisor.start(id) catch |e| {
                    const m = std.fmt.bufPrint(&msg_buf, "start failed: {s}", .{@errorName(e)}) catch "start failed";
                    try mcpJsonToolText(res, id_json, m, true);
                    return;
                };
                try mcpJsonToolText(res, id_json, "started", false);
            }
        },
        .stop => {
            if (proj.runtime == .static) {
                _ = app.projects.update(id, .{ .status = .stopped }) catch {};
                try mcpJsonToolText(res, id_json, "static project marked stopped", false);
            } else {
                app.supervisor.stop(id) catch {};
                try mcpJsonToolText(res, id_json, "SIGTERM sent (5s grace then SIGKILL)", false);
            }
        },
        .restart => {
            if (proj.runtime == .static) {
                _ = app.projects.update(id, .{ .status = .stopped }) catch {};
                std.Thread.sleep(1500 * std.time.ns_per_ms);
                _ = app.projects.update(id, .{ .status = .running }) catch {};
                try mcpJsonToolText(res, id_json, "static project bounced", false);
            } else {
                app.supervisor.restart(id) catch {};
                try mcpJsonToolText(res, id_json, "restarted", false);
            }
        },
        .deploy => {
            app.builder.deployAsync(id) catch |e| {
                const m = std.fmt.bufPrint(&msg_buf, "deploy spawn failed: {s}", .{@errorName(e)}) catch "deploy failed";
                try mcpJsonToolText(res, id_json, m, true);
                return;
            };
            try mcpJsonToolText(res, id_json, "deploy started in background. Use read_build_log to tail.", false);
        },
    }
}

fn mcpToolReadProjectLog(app: *App, res: *httpz.Response, id_json: []const u8, args: std.json.ObjectMap, log_name: []const u8) !void {
    _ = app;
    const id = mcpArgString(args, "id") orelse {
        try mcpJsonError(res, id_json, -32602, "id required");
        return;
    };
    if (!isValidProjectId(id)) {
        try mcpJsonToolText(res, id_json, "invalid project id", true);
        return;
    }
    var n: usize = 200;
    if (mcpArgInt(args, "lines")) |v| n = @min(@as(usize, @intCast(@max(v, 1))), 2000);

    const path = try std.fmt.allocPrint(res.arena, "/data/data/com.termux/files/home/data/projects/{s}/logs/{s}", .{ id, log_name });
    const file = std.fs.openFileAbsolute(path, .{}) catch {
        try mcpJsonToolText(res, id_json, "log not found", true);
        return;
    };
    defer file.close();
    const stat = file.stat() catch {
        try mcpJsonToolText(res, id_json, "stat failed", true);
        return;
    };
    const max_read: u64 = @min(stat.size, 2 * 1024 * 1024);
    if (stat.size > max_read) {
        file.seekFromEnd(-@as(i64, @intCast(max_read))) catch {};
    }
    const data = try file.readToEndAlloc(res.arena, @intCast(max_read));

    // Take last n lines
    var lines = std.ArrayList([]const u8).init(res.arena);
    var iter = std.mem.splitScalar(u8, data, '\n');
    while (iter.next()) |line| try lines.append(line);
    const start = if (lines.items.len > n) lines.items.len - n else 0;

    var out = std.ArrayList(u8).init(res.arena);
    const w = out.writer();
    try w.print("=== {s} (last {d} lines of {d}) ===\n", .{ log_name, lines.items.len - start, lines.items.len });
    for (lines.items[start..]) |line| {
        try w.writeAll(line);
        try w.writeByte('\n');
    }
    try mcpJsonToolText(res, id_json, out.items, false);
}

// ===== secret tools =====

fn mcpToolListSecrets(app: *App, res: *httpz.Response, id_json: []const u8, args: std.json.ObjectMap) !void {
    const pid = mcpArgString(args, "project_id") orelse {
        try mcpJsonError(res, id_json, -32602, "project_id required");
        return;
    };
    if (!isValidProjectId(pid)) {
        try mcpJsonToolText(res, id_json, "invalid project_id", true);
        return;
    }
    const keys = projsecrets.Vault.listKeys(res.arena, app.pepper, pid) catch {
        try mcpJsonToolText(res, id_json, "(no secrets vault yet)", false);
        return;
    };
    var out = std.ArrayList(u8).init(res.arena);
    if (keys.len == 0) {
        try out.appendSlice("(empty)");
    } else {
        try out.writer().print("Keys ({d}):\n", .{keys.len});
        for (keys) |k| {
            try out.writer().print("  - {s}\n", .{k});
        }
    }
    try mcpJsonToolText(res, id_json, out.items, false);
}

fn mcpToolSetSecret(app: *App, res: *httpz.Response, id_json: []const u8, args: std.json.ObjectMap) !void {
    const pid = mcpArgString(args, "project_id") orelse {
        try mcpJsonError(res, id_json, -32602, "project_id required");
        return;
    };
    const key = mcpArgString(args, "key") orelse {
        try mcpJsonError(res, id_json, -32602, "key required");
        return;
    };
    const value = mcpArgString(args, "value") orelse {
        try mcpJsonError(res, id_json, -32602, "value required");
        return;
    };
    if (!isValidProjectId(pid)) {
        try mcpJsonToolText(res, id_json, "invalid project_id", true);
        return;
    }
    if (value.len == 0) {
        try mcpJsonToolText(res, id_json, "value must be non-empty (use delete_secret to remove)", true);
        return;
    }
    projsecrets.Vault.setOne(res.arena, app.pepper, pid, key, value) catch |e| {
        var m: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&m, "set failed: {s}", .{@errorName(e)}) catch "set failed";
        try mcpJsonToolText(res, id_json, msg, true);
        return;
    };
    try mcpJsonToolText(res, id_json, "secret set. Restart project for env to take effect.", false);
}

fn mcpToolDeleteSecret(app: *App, res: *httpz.Response, id_json: []const u8, args: std.json.ObjectMap) !void {
    const pid = mcpArgString(args, "project_id") orelse {
        try mcpJsonError(res, id_json, -32602, "project_id required");
        return;
    };
    const key = mcpArgString(args, "key") orelse {
        try mcpJsonError(res, id_json, -32602, "key required");
        return;
    };
    if (!isValidProjectId(pid)) {
        try mcpJsonToolText(res, id_json, "invalid project_id", true);
        return;
    }
    // setOne with empty value deletes the key.
    projsecrets.Vault.setOne(res.arena, app.pepper, pid, key, "") catch |e| {
        var m: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&m, "delete failed: {s}", .{@errorName(e)}) catch "delete failed";
        try mcpJsonToolText(res, id_json, msg, true);
        return;
    };
    try mcpJsonToolText(res, id_json, "secret deleted", false);
}

// ===== database tools =====

fn mcpToolDbQuery(app: *App, res: *httpz.Response, id_json: []const u8, args: std.json.ObjectMap, read_only: bool) !void {
    _ = app;
    const pid = mcpArgString(args, "project_id") orelse {
        try mcpJsonError(res, id_json, -32602, "project_id required");
        return;
    };
    const sql = mcpArgString(args, "sql") orelse {
        try mcpJsonError(res, id_json, -32602, "sql required");
        return;
    };
    if (!isValidProjectId(pid)) {
        try mcpJsonToolText(res, id_json, "invalid project_id", true);
        return;
    }
    if (read_only) {
        // Cheap read-only sanity check: trim, must start with SELECT/WITH/PRAGMA/EXPLAIN.
        const trimmed = std.mem.trim(u8, sql, " \t\n\r;");
        const lower_first_word_buf = res.arena.alloc(u8, @min(trimmed.len, 16)) catch return;
        for (trimmed[0..@min(trimmed.len, 16)], 0..) |c, i| lower_first_word_buf[i] = std.ascii.toLower(c);
        const head = lower_first_word_buf;
        if (!(std.mem.startsWith(u8, head, "select") or std.mem.startsWith(u8, head, "with") or std.mem.startsWith(u8, head, "pragma") or std.mem.startsWith(u8, head, "explain"))) {
            try mcpJsonToolText(res, id_json, "query_db only accepts SELECT/WITH/PRAGMA/EXPLAIN. Use exec_db for writes.", true);
            return;
        }
    }
    const db_path = try std.fmt.allocPrint(res.arena, "{s}/{s}.db", .{ SQL_DB_ROOT, pid });
    const out = try runSqliteQuery(res.arena, db_path, sql);
    try mcpJsonToolText(res, id_json, out, false);
}

fn mcpToolDbListTables(app: *App, res: *httpz.Response, id_json: []const u8, args: std.json.ObjectMap) !void {
    _ = app;
    const pid = mcpArgString(args, "project_id") orelse {
        try mcpJsonError(res, id_json, -32602, "project_id required");
        return;
    };
    if (!isValidProjectId(pid)) {
        try mcpJsonToolText(res, id_json, "invalid project_id", true);
        return;
    }
    const db_path = try std.fmt.allocPrint(res.arena, "{s}/{s}.db", .{ SQL_DB_ROOT, pid });
    const sql = "SELECT name, (SELECT COUNT(*) FROM pragma_table_info(m.name)) AS col_count FROM sqlite_master m WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;";
    const out = try runSqliteQuery(res.arena, db_path, sql);
    try mcpJsonToolText(res, id_json, out, false);
}

fn runSqliteQuery(arena: std.mem.Allocator, db_path: []const u8, sql: []const u8) ![]const u8 {
    // Spawn `sqlite3 -box <db>` with sql piped on stdin so the table view is human-friendly.
    var argv = [_][]const u8{ "sqlite3", "-box", db_path };
    var child = std.process.Child.init(&argv, arena);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    if (child.stdin) |stdin| {
        stdin.writeAll(sql) catch {};
        stdin.writeAll("\n") catch {};
        stdin.close();
        child.stdin = null;
    }
    var stdout_buf = std.ArrayList(u8).init(arena);
    var stderr_buf = std.ArrayList(u8).init(arena);
    if (child.stdout) |s| {
        const d = s.readToEndAlloc(arena, 1024 * 1024) catch "";
        try stdout_buf.appendSlice(d);
    }
    if (child.stderr) |s| {
        const d = s.readToEndAlloc(arena, 64 * 1024) catch "";
        try stderr_buf.appendSlice(d);
    }
    _ = child.wait() catch {};
    var out = std.ArrayList(u8).init(arena);
    if (stderr_buf.items.len > 0) {
        try out.appendSlice("--- stderr ---\n");
        try out.appendSlice(stderr_buf.items);
        if (!std.mem.endsWith(u8, stderr_buf.items, "\n")) try out.append('\n');
    }
    if (stdout_buf.items.len > 0) {
        try out.appendSlice(stdout_buf.items);
    } else if (stderr_buf.items.len == 0) {
        try out.appendSlice("(no rows)");
    }
    return out.toOwnedSlice();
}

// ===== security & observability tools =====

fn mcpToolListBlockedIps(app: *App, res: *httpz.Response, id_json: []const u8) !void {
    const list = try app.blocklist.snapshot(res.arena);
    var out = std.ArrayList(u8).init(res.arena);
    if (list.len == 0) {
        try out.appendSlice("(blocklist empty)");
    } else {
        try out.writer().print("{d} blocked IP(s):\n", .{list.len});
        for (list) |e| {
            const ttl = if (e.expires_at == 0) -1 else e.expires_at - std.time.timestamp();
            try out.writer().print("  {s}  blocked_at={d}  expires_in={d}s  reason={s}\n", .{ e.ip, e.blocked_at, ttl, e.reason });
        }
    }
    try mcpJsonToolText(res, id_json, out.items, false);
}

fn mcpToolBlockIp(app: *App, res: *httpz.Response, id_json: []const u8, args: std.json.ObjectMap) !void {
    const ip = mcpArgString(args, "ip") orelse {
        try mcpJsonError(res, id_json, -32602, "ip required");
        return;
    };
    const reason = mcpArgString(args, "reason") orelse "manual: via mcp";
    const ttl: i64 = if (mcpArgInt(args, "ttl_seconds")) |v| v else 0;
    app.blocklist.block(ip, reason, ttl) catch |e| {
        var m: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&m, "block failed: {s}", .{@errorName(e)}) catch "block failed";
        try mcpJsonToolText(res, id_json, msg, true);
        return;
    };
    try mcpJsonToolText(res, id_json, "ip blocked", false);
}

fn mcpToolUnblockIp(app: *App, res: *httpz.Response, id_json: []const u8, args: std.json.ObjectMap) !void {
    const ip = mcpArgString(args, "ip") orelse {
        try mcpJsonError(res, id_json, -32602, "ip required");
        return;
    };
    app.blocklist.unblock(ip) catch {};
    try mcpJsonToolText(res, id_json, "ip unblocked (if it existed)", false);
}

fn mcpToolSearchAudit(app: *App, res: *httpz.Response, id_json: []const u8, args: std.json.ObjectMap) !void {
    _ = app;
    var n: usize = 50;
    if (mcpArgInt(args, "limit")) |v| n = @min(@as(usize, @intCast(@max(v, 1))), 500);
    const filter = mcpArgString(args, "action_contains");

    const path = "/data/data/com.termux/files/home/data/audit.jsonl";
    const file = std.fs.openFileAbsolute(path, .{}) catch {
        try mcpJsonToolText(res, id_json, "(no audit log yet)", false);
        return;
    };
    defer file.close();
    const stat = file.stat() catch return;
    const max: u64 = @min(stat.size, 4 * 1024 * 1024);
    if (stat.size > max) file.seekFromEnd(-@as(i64, @intCast(max))) catch {};
    const data = try file.readToEndAlloc(res.arena, @intCast(max));

    var lines = std.ArrayList([]const u8).init(res.arena);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (filter) |f| {
            if (std.mem.indexOf(u8, line, f) == null) continue;
        }
        try lines.append(line);
    }
    const start = if (lines.items.len > n) lines.items.len - n else 0;
    var out = std.ArrayList(u8).init(res.arena);
    try out.writer().print("Audit entries ({d} matching, last {d}):\n", .{ lines.items.len, lines.items.len - start });
    for (lines.items[start..]) |line| {
        try out.writer().writeAll(line);
        try out.writer().writeByte('\n');
    }
    try mcpJsonToolText(res, id_json, out.items, false);
}

fn mcpToolRecentVisits(app: *App, res: *httpz.Response, id_json: []const u8, args: std.json.ObjectMap) !void {
    var n: i64 = 50;
    if (mcpArgInt(args, "limit")) |v| n = @min(@max(v, 1), 500);
    const cls_filter = mcpArgString(args, "classification");

    var sql_buf = std.ArrayList(u8).init(res.arena);
    try sql_buf.writer().writeAll(".mode column\n.headers on\nSELECT visited_at, ip, country, classification, status, path FROM visits");
    if (cls_filter) |f| {
        try sql_buf.writer().print(" WHERE classification='{s}'", .{f});
    }
    try sql_buf.writer().print(" ORDER BY visited_at DESC LIMIT {d};\n", .{n});

    const out = runSqliteQuery(res.arena, dbcache.PATH, sql_buf.items) catch "(query failed)";
    _ = app;
    try mcpJsonToolText(res, id_json, out, false);
}

// ===== backup tools =====

fn mcpToolListBackups(app: *App, res: *httpz.Response, id_json: []const u8) !void {
    _ = app;
    const cmd =
        \\echo "=== local (~/backups/) ==="
        \\ls -la ~/backups/ 2>/dev/null | tail -n +4
        \\echo ""
        \\echo "=== remote (R2) ==="
        \\command -v rclone >/dev/null && rclone lsl r2:rofihosted 2>/dev/null | tail -50 || echo "(rclone not configured)"
    ;
    var argv = [_][]const u8{ "sh", "-c", cmd };
    var child = std.process.Child.init(&argv, res.arena);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        try mcpJsonToolText(res, id_json, "spawn failed", true);
        return;
    };
    var out = std.ArrayList(u8).init(res.arena);
    if (child.stdout) |s| {
        const d = s.readToEndAlloc(res.arena, 64 * 1024) catch "";
        try out.appendSlice(d);
    }
    _ = child.wait() catch {};
    try mcpJsonToolText(res, id_json, out.items, false);
}

fn mcpToolTriggerBackup(app: *App, res: *httpz.Response, id_json: []const u8, args: std.json.ObjectMap) !void {
    _ = app;
    const target = mcpArgString(args, "target") orelse "local";
    const script = if (std.mem.eql(u8, target, "r2")) "~/backup-r2.sh" else "~/backup-quick.sh";
    var argv = [_][]const u8{ "sh", "-c", script };
    var child = std.process.Child.init(&argv, res.arena);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch {
        try mcpJsonToolText(res, id_json, "spawn failed", true);
        return;
    };
    var out = std.ArrayList(u8).init(res.arena);
    if (child.stdout) |s| {
        const d = s.readToEndAlloc(res.arena, 64 * 1024) catch "";
        try out.appendSlice(d);
    }
    if (child.stderr) |s| {
        const d = s.readToEndAlloc(res.arena, 16 * 1024) catch "";
        if (d.len > 0) {
            try out.appendSlice("--- stderr ---\n");
            try out.appendSlice(d);
        }
    }
    const term = child.wait() catch std.process.Child.Term{ .Unknown = 0 };
    const ok = switch (term) {
        .Exited => |c| c == 0,
        else => false,
    };
    try mcpJsonToolText(res, id_json, out.items, !ok);
}

// =================================================================
// SIGNUP + USER MANAGEMENT (multi-tenancy)
// =================================================================

fn handleCheckInvite(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;
    res.header("Cache-Control", "no-store");
    const code_qs = req.url.query;
    var code: []const u8 = "";
    var iter = std.mem.splitScalar(u8, code_qs, '&');
    while (iter.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "code=")) {
            code = pair[5..];
            break;
        }
    }
    // URL-decode minimal (we expect just RH-XXXX-XXXX which has no special chars)
    if (code.len == 0) {
        try res.json(.{ .ok = false, .err = "missing_code" }, .{});
        return;
    }

    // Don't actually consume - just probe. We have to walk the list since
    // there's no findByCode helper yet. Read via list().
    const all = try app.invites.list(res.arena);
    for (all) |inv| {
        if (std.mem.eql(u8, inv.code, code)) {
            if (!inv.isUsable()) {
                try res.json(.{ .ok = false, .err = "already_used" }, .{});
                return;
            }
            try res.json(.{ .ok = true, .note = inv.note }, .{});
            return;
        }
    }
    try res.json(.{ .ok = false, .err = "not_found" }, .{});
}

fn handleSignupSubmit(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JSON;
    res.header("Cache-Control", "no-store");

    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const username = std.mem.trim(u8, form.get("username") orelse "", " \t");
    const email = std.mem.trim(u8, form.get("email") orelse "", " \t");
    const password = form.get("password") orelse "";
    const invite_code_raw = std.mem.trim(u8, form.get("invite_code") orelse "", " \t");
    const reason = std.mem.trim(u8, form.get("signup_reason") orelse "", " \t");

    if (username.len == 0 or password.len == 0 or email.len == 0) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_field" }, .{});
        return;
    }
    if (std.mem.indexOfScalar(u8, email, '@') == null or email.len < 5) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_email" }, .{});
        return;
    }

    var input = users.SignupInput{
        .username = username,
        .email = email,
        .password = password,
        .signup_reason = reason,
    };

    var initial_status: users.Status = .pending;
    var method: users.SignupMethod = .self;
    var consumed_invite: ?[]const u8 = null;

    if (invite_code_raw.len > 0) {
        // Validate + consume invite atomically
        const inv = app.invites.consume(invite_code_raw, username) catch |e| {
            res.status = 400;
            const msg = switch (e) {
                error.NotFound => "invite_invalid",
                error.AlreadyUsed => "invite_used",
                else => "invite_error",
            };
            try res.json(.{ .ok = false, .err = msg }, .{});
            return;
        };
        method = .invite;
        initial_status = .active;
        input.invite_code = inv.code;
        consumed_invite = inv.code;
    }

    const user = app.users.create(input, method, initial_status, null) catch |e| {
        res.status = 400;
        const msg = switch (e) {
            error.UsernameTaken => "username_taken",
            error.EmailTaken => "email_taken",
            error.InvalidUsername => "invalid_username",
            error.InvalidEmail => "invalid_email",
            error.WeakPassword => "weak_password",
            else => "server_error",
        };
        try res.json(.{ .ok = false, .err = msg }, .{});
        return;
    };

    // Audit + bus event
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = "self",
        .action = if (method == .invite) "user_signup_invite" else "user_signup_self",
        .target = user.id,
        .detail = if (consumed_invite) |c| c else "",
        .ok = true,
    }) catch {};

    app.bus.publish(.anomaly_detected, .{
        .timestamp = std.time.timestamp(),
        .kind = if (initial_status == .pending) "user_signup_pending" else "user_signup_active",
        .detail = user.username,
    });

    // Issue a session cookie so they don't have to log in again
    auth.issueUserCookie(app.auth_cfg, user, res) catch {};

    try res.json(.{
        .ok = true,
        .id = user.id,
        .username = user.username,
        .status = user.status.label(),
    }, .{});
}

// ---- admin user management API ----

fn requireAdmin(app: *App, req: *httpz.Request, res: *httpz.Response) !?auth.Identity {
    const ident = auth.currentIdentity(app.auth_cfg, app.users, app.allocator, req) orelse {
        res.status = 401;
        try res.json(.{ .ok = false, .err = "not_authenticated" }, .{});
        return null;
    };
    if (ident.role != .admin) {
        res.status = 403;
        try res.json(.{ .ok = false, .err = "admin_required" }, .{});
        return null;
    }
    return ident;
}

fn apiUsersList(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const ident = (try requireAdmin(app, req, res)) orelse return;
    _ = ident;
    const list = try app.users.list(res.arena);
    var buf = std.ArrayList(u8).init(res.arena);
    const w = buf.writer();
    try w.writeAll("{\"ok\":true,\"users\":[");
    for (list, 0..) |u, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try writeJsonStr(w, u.id);
        try w.writeAll(",\"username\":");
        try writeJsonStr(w, u.username);
        try w.writeAll(",\"email\":");
        try writeJsonStr(w, u.email);
        try w.print(",\"role\":\"{s}\",\"status\":\"{s}\",\"signup_method\":\"{s}\"", .{
            u.role.label(), u.status.label(), u.signup_method.label(),
        });
        if (u.signup_reason.len > 0) {
            try w.writeAll(",\"signup_reason\":");
            try writeJsonStr(w, u.signup_reason);
        }
        if (u.invite_code) |c| {
            try w.writeAll(",\"invite_code\":");
            try writeJsonStr(w, c);
        }
        try w.print(",\"created_at\":{d},\"approved_at\":{d},\"last_login\":{d}", .{
            u.created_at, u.approved_at, u.last_login,
        });
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    res.content_type = .JSON;
    res.body = try buf.toOwnedSlice();
}

fn apiUsersApprove(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const ident = (try requireAdmin(app, req, res)) orelse return;
    res.content_type = .JSON;
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const id = form.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    app.users.approve(id, ident.user_id) catch |e| {
        res.status = 400;
        const msg = switch (e) {
            error.NotFound => "not_found",
            error.NotPending => "not_pending",
            else => "error",
        };
        try res.json(.{ .ok = false, .err = msg }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = ident.username,
        .action = "user_approve",
        .target = id,
        .detail = "",
        .ok = true,
    }) catch {};
    try res.json(.{ .ok = true }, .{});
}

fn apiUsersReject(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const ident = (try requireAdmin(app, req, res)) orelse return;
    res.content_type = .JSON;
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const id = form.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    const reason = form.get("reason") orelse "";
    app.users.reject(id, ident.user_id, reason) catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "error" }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = ident.username,
        .action = "user_reject",
        .target = id,
        .detail = reason,
        .ok = true,
    }) catch {};
    try res.json(.{ .ok = true }, .{});
}

fn apiUsersSuspend(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const ident = (try requireAdmin(app, req, res)) orelse return;
    res.content_type = .JSON;
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const id = form.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    app.users.suspend_(id) catch |e| {
        res.status = 400;
        const msg = switch (e) {
            error.NotFound => "not_found",
            error.CannotSuspendAdmin => "cannot_suspend_admin",
            else => "error",
        };
        try res.json(.{ .ok = false, .err = msg }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = ident.username,
        .action = "user_suspend",
        .target = id,
        .detail = "",
        .ok = true,
    }) catch {};
    try res.json(.{ .ok = true }, .{});
}

fn apiUsersUnsuspend(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const ident = (try requireAdmin(app, req, res)) orelse return;
    res.content_type = .JSON;
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const id = form.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    app.users.unsuspend(id) catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "error" }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = ident.username,
        .action = "user_unsuspend",
        .target = id,
        .detail = "",
        .ok = true,
    }) catch {};
    try res.json(.{ .ok = true }, .{});
}

// ---- invites ----

fn apiInvitesList(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const ident = (try requireAdmin(app, req, res)) orelse return;
    _ = ident;
    const list = try app.invites.list(res.arena);
    var buf = std.ArrayList(u8).init(res.arena);
    const w = buf.writer();
    try w.writeAll("{\"ok\":true,\"invites\":[");
    for (list, 0..) |inv, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"code\":");
        try writeJsonStr(w, inv.code);
        try w.writeAll(",\"created_by\":");
        try writeJsonStr(w, inv.created_by);
        try w.print(",\"created_at\":{d},\"expires_at\":{d},\"max_uses\":{d},\"uses\":{d}", .{
            inv.created_at, inv.expires_at, inv.max_uses, inv.uses,
        });
        if (inv.note.len > 0) {
            try w.writeAll(",\"note\":");
            try writeJsonStr(w, inv.note);
        }
        if (inv.last_used_by) |x| {
            try w.writeAll(",\"last_used_by\":");
            try writeJsonStr(w, x);
        }
        try w.print(",\"last_used_at\":{d}", .{inv.last_used_at});
        try w.print(",\"usable\":{s}", .{if (inv.isUsable()) "true" else "false"});
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    res.content_type = .JSON;
    res.body = try buf.toOwnedSlice();
}

fn apiInvitesCreate(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const ident = (try requireAdmin(app, req, res)) orelse return;
    res.content_type = .JSON;
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const note = form.get("note") orelse "";
    var max_uses: u32 = 1;
    if (form.get("max_uses")) |s| {
        if (std.fmt.parseInt(u32, s, 10) catch null) |n| max_uses = n;
    }
    var expires_at: i64 = 0;
    if (form.get("expires_in_days")) |s| {
        if (std.fmt.parseInt(i64, s, 10) catch null) |days| {
            if (days > 0) expires_at = std.time.timestamp() + days * 86400;
        }
    }
    const inv = app.invites.create(ident.username, note, expires_at, max_uses) catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "create_failed" }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = ident.username,
        .action = "invite_create",
        .target = inv.code,
        .detail = note,
        .ok = true,
    }) catch {};
    try res.json(.{ .ok = true, .code = inv.code, .max_uses = inv.max_uses, .expires_at = inv.expires_at }, .{});
}

fn apiInvitesRevoke(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const ident = (try requireAdmin(app, req, res)) orelse return;
    res.content_type = .JSON;
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const code = form.get("code") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_code" }, .{});
        return;
    };
    app.invites.revoke(code) catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "not_found" }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = ident.username,
        .action = "invite_revoke",
        .target = code,
        .detail = "",
        .ok = true,
    }) catch {};
    try res.json(.{ .ok = true }, .{});
}

// JSON string writer used by the user/invite list endpoints.
fn writeJsonStr(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x00...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn v1PublicStats(app: *App, res: *httpz.Response) !void {
    // CORS so the marketing landing on rofihosted.space can fetch from
    // app.rofihosted.space without preflight.
    res.header("Access-Control-Allow-Origin", "*");
    res.header("Cache-Control", "public, max-age=30");

    // Project count: locked snapshot of the registry.
    var project_count: usize = 0;
    {
        app.projects.mutex.lock();
        defer app.projects.mutex.unlock();
        project_count = app.projects.projects.items.len;
    }

    // Requests in last 24h: served from dbcache (no JSONL scan).
    const requests_24h: u64 = app.dbcache.countVisits(86400, null, null, null, null) catch 0;

    // Uptime: just process started_at.
    const uptime_seconds: i64 = std.time.timestamp() - app.started_at;

    // Battery: snapshot from powermon. -1 means termux-api unavailable, in
    // which case we omit the field and the JS shows '--'.
    const reading = app.powermon.snapshot();
    const battery_pct: ?i32 = if (reading.percentage >= 0) reading.percentage else null;

    if (battery_pct) |b| {
        try res.json(.{
            .ok = true,
            .projects = project_count,
            .requests_24h = requests_24h,
            .uptime_seconds = uptime_seconds,
            .battery_percent = b,
        }, .{});
    } else {
        try res.json(.{
            .ok = true,
            .projects = project_count,
            .requests_24h = requests_24h,
            .uptime_seconds = uptime_seconds,
        }, .{});
    }
}

fn v1Execute(app: *App, req: *httpz.Request, res: *httpz.Response, rec: apikey.Record) !void {
    const body = req.body() orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_body" }, .{});
        return;
    };
    const Payload = struct {
        db: []const u8,
        sql: []const u8,
    };
    const parsed = std.json.parseFromSlice(Payload, res.arena, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_json" }, .{});
        return;
    };
    defer parsed.deinit();
    const p = parsed.value;

    // db must be a simple name [a-z0-9_-], no slashes / dots
    if (p.db.len == 0 or p.db.len > 64) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_db_name" }, .{});
        return;
    }
    for (p.db) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) {
            res.status = 400;
            try res.json(.{ .ok = false, .err = "invalid_db_name" }, .{});
            return;
        }
    }
    if (p.sql.len == 0 or p.sql.len > 64 * 1024) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_sql_size" }, .{});
        return;
    }

    // Build absolute path under SQL_DB_ROOT
    std.fs.makeDirAbsolute(SQL_DB_ROOT) catch {};
    const db_path = try std.fmt.allocPrint(res.arena, "{s}/{s}.db", .{ SQL_DB_ROOT, p.db });
    // p.db has already passed the [a-z0-9_-] regex above, so it cannot escape
    // SQL_DB_ROOT via traversal or symlinks. No further pathsafe check needed.

    // Use a one-shot subprocess against the requested DB (the pool is bound to
    // cache.db only). Output as JSON via .mode json so the client gets a
    // structured response, not raw rows.
    var script = std.ArrayList(u8).init(res.arena);
    try script.appendSlice(".mode json\n");
    try script.appendSlice(p.sql);
    if (script.items.len == 0 or script.items[script.items.len - 1] != '\n') {
        try script.appendSlice("\n");
    }

    var child = std.process.Child.init(
        &.{ "sqlite3", "-batch", "-bail", db_path },
        app.allocator,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "spawn_failed" }, .{});
        return;
    };

    if (child.stdin) |stdin| {
        stdin.writeAll(script.items) catch {};
        stdin.close();
        child.stdin = null;
    }

    var stdout_buf = std.ArrayList(u8).init(res.arena);
    if (child.stdout) |stdout| {
        var rb: [8192]u8 = undefined;
        while (true) {
            const n = stdout.read(&rb) catch 0;
            if (n == 0) break;
            stdout_buf.appendSlice(rb[0..n]) catch break;
            if (stdout_buf.items.len > 8 * 1024 * 1024) break;
        }
    }
    var stderr_buf: [4096]u8 = undefined;
    var stderr_n: usize = 0;
    if (child.stderr) |stderr| {
        stderr_n = stderr.read(&stderr_buf) catch 0;
    }
    const term = child.wait() catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "wait_failed" }, .{});
        return;
    };
    const exit_code = switch (term) {
        .Exited => |c| c,
        else => 1,
    };

    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = rec.name,
        .action = "v1_execute",
        .target = p.db,
        .ok = exit_code == 0,
    });

    if (exit_code != 0) {
        res.status = 400;
        try res.json(.{
            .ok = false,
            .err = "sql_error",
            .stderr = stderr_buf[0..@min(stderr_n, 1024)],
        }, .{});
        return;
    }

    res.content_type = .JSON;
    var envelope = std.ArrayList(u8).init(res.arena);
    try envelope.appendSlice("{\"ok\":true,\"db\":\"");
    try envelope.appendSlice(p.db);
    try envelope.appendSlice("\",\"result\":");
    const trimmed = std.mem.trim(u8, stdout_buf.items, " \t\r\n");
    if (trimmed.len == 0) {
        try envelope.appendSlice("[]");
    } else {
        try envelope.appendSlice(trimmed);
    }
    try envelope.appendSlice("}");
    res.body = try res.arena.dupe(u8, envelope.items);
}

// =================================================================
// API KEYS (operator-only Settings page)
// =================================================================
fn apiApikeysList(app: *App, res: *httpz.Response) !void {
    const json_body = app.apikey.listJson(res.arena) catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "list_failed" }, .{});
        return;
    };
    res.content_type = .JSON;
    res.body = json_body;
}

fn apiApikeysCreate(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const name = form.get("name") orelse "unnamed";
    const scopes_str = form.get("scopes") orelse "sql";

    var scopes = std.ArrayList(apikey.Scope).init(res.arena);
    var it = std.mem.tokenizeScalar(u8, scopes_str, ',');
    while (it.next()) |s| {
        const trimmed = std.mem.trim(u8, s, " ");
        if (apikey.Scope.fromString(trimmed)) |sc| try scopes.append(sc);
    }
    if (scopes.items.len == 0) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "no_scopes" }, .{});
        return;
    }

    const raw = app.apikey.create(name, scopes.items) catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "create_failed" }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "apikey_create",
        .target = name,
    });
    // Return the raw key ONCE. After this, only the hash is on disk.
    try res.json(.{ .ok = true, .key = raw, .name = name }, .{});
}

fn apiApikeysRevoke(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const id = form.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    const did = app.apikey.revoke(id) catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "revoke_failed" }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "apikey_revoke",
        .target = id,
        .ok = did,
    });
    try res.json(.{ .ok = did }, .{});
}

// =================================================================
// HOURLY BACKUP (built-in scheduler, no termux crond required)
// =================================================================
fn hourlyBackupLoop() void {
    // Initial 5 minute delay so the rest of the system has time to settle.
    // We do not want the first backup running during boot when projects are
    // still respawning.
    std.Thread.sleep(5 * 60 * std.time.ns_per_s);
    const home = std.posix.getenv("HOME") orelse "/data/data/com.termux/files/home";

    while (true) {
        // Build the script path each loop so it's always fresh
        const allocator = std.heap.page_allocator;
        const script = std.fmt.allocPrint(allocator, "{s}/backup-r2.sh", .{home}) catch {
            std.Thread.sleep(60 * 60 * std.time.ns_per_s);
            continue;
        };
        defer allocator.free(script);

        // Skip if backup-r2.sh doesn't exist
        std.fs.accessAbsolute(script, .{}) catch {
            std.Thread.sleep(60 * 60 * std.time.ns_per_s);
            continue;
        };

        var argv = [_][]const u8{ "sh", "-c", script };
        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.spawn() catch {
            std.Thread.sleep(60 * 60 * std.time.ns_per_s);
            continue;
        };

        // Drain output briefly (we don't need much)
        var out_buf: [1024]u8 = undefined;
        var n: usize = 0;
        if (child.stdout) |so| n = so.readAll(&out_buf) catch 0;
        const term = child.wait() catch std.process.Child.Term{ .Unknown = 0 };
        const ok = switch (term) {
            .Exited => |c| c == 0,
            else => false,
        };
        if (ok) {
            std.log.info("hourly backup OK: {s}", .{out_buf[0..@min(n, 200)]});
        } else {
            std.log.warn("hourly backup failed: {s}", .{out_buf[0..@min(n, 200)]});
        }

        std.Thread.sleep(60 * 60 * std.time.ns_per_s); // 1 hour
    }
}

// =================================================================
// WEBHOOKS (outbound HTTP on internal events)
// =================================================================
fn webhookFanOut(ctx: *anyopaque, label: []const u8, payload_json: []const u8) void {
    const mgr: *webhook.Manager = @ptrCast(@alignCast(ctx));
    // Map SSE label back to EventType. If unknown, just skip.
    const event_type = webhook.EventType.fromString(label) orelse return;
    // Wrap payload in {event, ts, payload} envelope.
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.print(
        \\{{"event":"{s}","ts":{d},"payload":{s}}}
    , .{ label, std.time.timestamp(), payload_json }) catch return;
    mgr.fire(event_type, fbs.getWritten());
}

fn apiWebhooksList(app: *App, res: *httpz.Response) !void {
    const json_body = app.webhook.listJson(res.arena) catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "list_failed" }, .{});
        return;
    };
    res.content_type = .JSON;
    res.body = json_body;
}

fn apiWebhooksCreate(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const name = form.get("name") orelse "unnamed";
    const url = form.get("url") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_url" }, .{});
        return;
    };
    const events_str = form.get("events") orelse "";

    var ev_list = std.ArrayList(webhook.EventType).init(res.arena);
    var it = std.mem.tokenizeScalar(u8, events_str, ',');
    while (it.next()) |s| {
        const trimmed = std.mem.trim(u8, s, " ");
        if (webhook.EventType.fromString(trimmed)) |e| try ev_list.append(e);
    }
    if (ev_list.items.len == 0) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "no_events" }, .{});
        return;
    }

    const id = app.webhook.create(name, url, ev_list.items) catch |err| {
        const code: []const u8 = switch (err) {
            error.InvalidUrl => "invalid_url",
            else => "create_failed",
        };
        res.status = 400;
        try res.json(.{ .ok = false, .err = code }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "webhook_create",
        .target = name,
    });
    try res.json(.{ .ok = true, .id = id }, .{});
}

fn apiWebhooksDelete(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const id = form.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    const did = app.webhook.delete(id) catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "delete_failed" }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "webhook_delete",
        .target = id,
        .ok = did,
    });
    try res.json(.{ .ok = did }, .{});
}

// =================================================================
// PROJECTS (Netlify-style deployable units, full lifecycle)
// =================================================================

/// Try to serve a request from a project that owns the host's subdomain.
/// Returns true if the request was handled (200/404/etc set on res).
fn tryServeProject(app: *App, req: *httpz.Request, host: []const u8, req_path: []const u8, client_ip: []const u8, res: *httpz.Response) !bool {
    const sub = hosted.extractSubdomain(host) orelse return false;
    const project = app.projects.getBySubdomain(sub) orelse return false;

    // Built-in auth endpoints under /auth/* are intercepted by hp-server even
    // for backend projects, so the project's own code never sees raw passwords.
    // The project verifies tokens by hitting <sub>/auth/verify with the user's
    // bearer token.
    if (std.mem.startsWith(u8, req_path, "/auth/")) {
        return tryServeAuth(app, req, project, req_path, res);
    }

    // Honor the dashboard 'stopped' status for static projects: serve a
    // 'site paused' page instead of the build output. Backend projects also
    // respect .stopped (the supervisor isn't running them, but make sure
    // visitors see a friendly message instead of a 502).
    if (project.status == .stopped) {
        return servePausedPage(project, res);
    }

    if (project.runtime == .static) {
        return tryServeProjectStatic(app, project, req_path, res);
    }

    // Backend / dynamic project: reverse proxy to 127.0.0.1:<port>.
    if (project.port == 0) {
        res.status = 503;
        res.content_type = .TEXT;
        res.body = "project has no allocated port\n";
        return true;
    }
    const status = app.supervisor.statusOf(project.id);
    if (status.state != .running or status.pid == null) {
        res.status = 503;
        res.content_type = .TEXT;
        res.body = "project not running, click Start in the dashboard\n";
        return true;
    }
    proxy.proxy(app.allocator, project.port, req, res, host, client_ip) catch |err| {
        std.log.warn("proxy {s}:{d} failed: {}", .{ project.subdomain, project.port, err });
        res.status = 502;
        res.content_type = .TEXT;
        res.body = "proxy error\n";
    };
    return true;
}

/// Render a friendly 'Site paused' page when the operator has stopped the
/// project. Uses inline HTML so it works without any template files.
fn servePausedPage(project: projects.Project, res: *httpz.Response) !bool {
    res.status = 503;
    res.content_type = .HTML;
    res.header("Cache-Control", "no-store, must-revalidate");
    const html = try std.fmt.allocPrint(res.arena,
        \\<!DOCTYPE html>
        \\<html lang="en"><head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>{s} is paused</title>
        \\<style>
        \\:root {{ color-scheme: light dark; }}
        \\body {{ margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center; padding:1.5rem;
        \\  font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
        \\  background: linear-gradient(135deg, #0f0e17 0%, #1a1825 100%); color: #e7e5e4; }}
        \\.card {{ max-width: 480px; width:100%; padding: 2.5rem 2.2rem; border-radius: 16px;
        \\  background: rgba(30,28,42,0.6); border: 1px solid rgba(255,255,255,0.08);
        \\  backdrop-filter: blur(8px); box-shadow: 0 20px 60px rgba(0,0,0,0.4); text-align: center; }}
        \\.dot {{ width: 12px; height: 12px; border-radius: 50%; background: #f59e0b; display: inline-block; margin-right: .5rem;
        \\  box-shadow: 0 0 14px rgba(245, 158, 11, 0.6); animation: pulse 2s ease-in-out infinite; }}
        \\@keyframes pulse {{ 0%, 100% {{ opacity: 1; }} 50% {{ opacity: .4; }} }}
        \\h1 {{ margin: 0 0 .8rem; font-size: 1.4rem; font-weight: 600; letter-spacing: -0.02em; }}
        \\p  {{ margin: 0 0 .4rem; color: #a8a29e; font-size: .9rem; line-height: 1.5; }}
        \\.sub {{ font-family: ui-monospace, "SF Mono", Menlo, monospace; color: #d4d4d8; font-size: .82rem;
        \\  margin-top: 1.4rem; padding: .65rem .9rem; background: rgba(0,0,0,0.3); border-radius: 8px;
        \\  border: 1px solid rgba(255,255,255,0.05); display:inline-block; }}
        \\.foot {{ margin-top: 1.6rem; font-size: .72rem; color: #71717a; letter-spacing: .04em; text-transform: uppercase; }}
        \\a {{ color: #a78bfa; text-decoration: none; }}
        \\</style>
        \\</head><body>
        \\<div class="card">
        \\  <div style="margin-bottom:1.2rem"><span class="dot"></span><span style="color:#f59e0b; font-size:.72rem; letter-spacing:.08em; text-transform:uppercase; font-weight:600">Paused</span></div>
        \\  <h1>{s} is paused</h1>
        \\  <p>The operator has stopped this site from the dashboard. Once they hit Start again, the site will be live within seconds.</p>
        \\  <div class="sub">{s}.rofihosted.space</div>
        \\  <div class="foot">Hosted on <a href="https://rofihosted.space">rofihosted</a></div>
        \\</div>
        \\</body></html>
    , .{ project.name, project.name, project.subdomain });
    res.body = html;
    return true;
}

fn tryServeProjectStatic(app: *App, project: projects.Project, req_path: []const u8, res: *httpz.Response) !bool {
    _ = app;
    pathsafe.validateRequestPath(req_path) catch {
        res.status = 400;
        res.content_type = .TEXT;
        res.body = "bad path\n";
        return true;
    };

    const lookup = if (req_path.len == 1 and req_path[0] == '/') "/index.html" else req_path;

    const proj_root = try std.fmt.allocPrint(
        res.arena,
        "{s}/{s}/current",
        .{ projects.PROJECTS_DIR, project.id },
    );

    // Confirm current/ exists
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const canonical = std.fs.realpath(proj_root, &rbuf) catch {
        res.status = 503;
        res.content_type = .TEXT;
        res.body = "project not deployed yet\n";
        return true;
    };

    const resolved = pathsafe.resolveWithinRoot(res.arena, canonical, lookup) catch |err| switch (err) {
        error.FileNotFound, error.Unreadable => {
            res.status = 404;
            res.content_type = .TEXT;
            res.body = "not found\n";
            return true;
        },
        else => {
            res.status = 400;
            res.content_type = .TEXT;
            res.body = "bad path\n";
            return true;
        },
    };

    const file = std.fs.openFileAbsolute(resolved, .{}) catch {
        res.status = 404;
        res.content_type = .TEXT;
        res.body = "not found\n";
        return true;
    };
    defer file.close();
    const stat = file.stat() catch {
        res.status = 404;
        res.content_type = .TEXT;
        res.body = "not found\n";
        return true;
    };
    if (stat.kind == .directory) {
        // dir hit -> try /index.html
        const idx = try std.fmt.allocPrint(res.arena, "{s}/index.html", .{resolved});
        const idx_file = std.fs.openFileAbsolute(idx, .{}) catch {
            res.status = 404;
            res.content_type = .TEXT;
            res.body = "not found\n";
            return true;
        };
        defer idx_file.close();
        const body = try idx_file.readToEndAlloc(res.arena, 16 * 1024 * 1024);
        res.status = 200;
        res.header("Content-Type", "text/html; charset=utf-8");
        res.header("Cache-Control", "public, max-age=60");
        res.body = body;
        return true;
    }

    const body = try file.readToEndAlloc(res.arena, 16 * 1024 * 1024);
    const ct = projectMimeFromPath(resolved);
    res.status = 200;
    res.header("Content-Type", ct);
    res.header("Cache-Control", "public, max-age=60");
    res.body = body;
    return true;
}

fn projectMimeFromPath(p: []const u8) []const u8 {
    const ext_idx = std.mem.lastIndexOfScalar(u8, p, '.') orelse return "application/octet-stream";
    const ext = p[ext_idx..];
    if (std.mem.eql(u8, ext, ".html") or std.mem.eql(u8, ext, ".htm")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext, ".css")) return "text/css; charset=utf-8";
    if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".mjs")) return "application/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".json")) return "application/json; charset=utf-8";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".webp")) return "image/webp";
    if (std.mem.eql(u8, ext, ".gif")) return "image/gif";
    if (std.mem.eql(u8, ext, ".ico")) return "image/x-icon";
    if (std.mem.eql(u8, ext, ".woff2")) return "font/woff2";
    if (std.mem.eql(u8, ext, ".woff")) return "font/woff";
    if (std.mem.eql(u8, ext, ".txt")) return "text/plain; charset=utf-8";
    if (std.mem.eql(u8, ext, ".md")) return "text/markdown; charset=utf-8";
    if (std.mem.eql(u8, ext, ".wasm")) return "application/wasm";
    return "application/octet-stream";
}

fn apiProjectsList(app: *App, res: *httpz.Response) !void {
    const json_body = app.projects.listJson(res.arena) catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "list_failed" }, .{});
        return;
    };
    res.content_type = .JSON;
    res.body = json_body;
}

fn apiProjectsCreate(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const name = form.get("name") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_name" }, .{});
        return;
    };
    const subdomain = form.get("subdomain") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_subdomain" }, .{});
        return;
    };
    const runtime_str = form.get("runtime") orelse "static";
    const runtime = projects.Runtime.fromString(runtime_str) orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_runtime" }, .{});
        return;
    };

    const project = app.projects.create(.{
        .name = name,
        .subdomain = subdomain,
        .repo_url = form.get("repo_url") orelse "",
        .branch = form.get("branch") orelse "main",
        .runtime = runtime,
        .install_cmd = form.get("install_cmd") orelse "",
        .build_cmd = form.get("build_cmd") orelse "",
        .start_cmd = form.get("start_cmd") orelse "",
        .publish_dir = form.get("publish_dir") orelse "",
        .rss_limit_mb = blk: {
            const v = form.get("rss_limit_mb") orelse break :blk 0;
            break :blk std.fmt.parseInt(u32, v, 10) catch 0;
        },
    }) catch |err| {
        const code: []const u8 = switch (err) {
            error.SubdomainTaken => "subdomain_taken",
            error.InvalidSubdomain => "invalid_subdomain",
            error.InvalidName => "invalid_name",
            error.PortExhausted => "port_exhausted",
            else => "create_failed",
        };
        res.status = 400;
        try res.json(.{ .ok = false, .err = code }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "project_create",
        .target = project.subdomain,
    });
    try res.json(.{ .ok = true, .id = project.id, .port = project.port }, .{});
}

fn apiProjectsUpdate(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const id = form.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    var input = projects.Manager.UpdateInput{};
    if (form.get("name")) |v| input.name = v;
    if (form.get("repo_url")) |v| input.repo_url = v;
    if (form.get("branch")) |v| input.branch = v;
    if (form.get("install_cmd")) |v| input.install_cmd = v;
    if (form.get("build_cmd")) |v| input.build_cmd = v;
    if (form.get("start_cmd")) |v| input.start_cmd = v;
    if (form.get("publish_dir")) |v| input.publish_dir = v;
    if (form.get("rss_limit_mb")) |v| {
        if (std.fmt.parseInt(u32, v, 10)) |n| {
            input.rss_limit_mb = n;
        } else |_| {}
    }

    const updated = app.projects.update(id, input) catch |err| {
        const code: []const u8 = switch (err) {
            error.NotFound => "not_found",
            error.InvalidName => "invalid_name",
            else => "update_failed",
        };
        res.status = 400;
        try res.json(.{ .ok = false, .err = code }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "project_update",
        .target = updated.id,
    });
    try res.json(.{ .ok = true }, .{});
}

fn apiProjectsDelete(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const id = form.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    if (!isValidProjectId(id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    const purge_raw = form.get("purge") orelse "";
    const purge = std.mem.eql(u8, purge_raw, "true") or std.mem.eql(u8, purge_raw, "1") or std.mem.eql(u8, purge_raw, "on");

    // Best-effort: stop any supervised process before pulling the registry entry.
    app.supervisor.stop(id) catch {};

    app.projects.delete(id) catch |err| {
        const code: []const u8 = switch (err) {
            error.NotFound => "not_found",
            else => "delete_failed",
        };
        res.status = 400;
        try res.json(.{ .ok = false, .err = code }, .{});
        return;
    };

    var purged_files = false;
    var purged_db = false;
    if (purge) {
        // Working tree (also contains secrets.bin and any logs under the project dir).
        const proj_dir = std.fmt.allocPrint(res.arena, "{s}/{s}", .{ projects.PROJECTS_DIR, id }) catch null;
        if (proj_dir) |dir| {
            std.fs.deleteTreeAbsolute(dir) catch |err| {
                std.log.warn("project_purge: deleteTreeAbsolute({s}) failed: {s}", .{ dir, @errorName(err) });
            };
            purged_files = true;
        }
        // Per-project auth/data DB.
        const db_path = std.fmt.allocPrint(res.arena, "{s}/{s}.db", .{ projauth.DBS_DIR, id }) catch null;
        if (db_path) |p| {
            std.fs.deleteFileAbsolute(p) catch |err| switch (err) {
                error.FileNotFound => {},
                else => std.log.warn("project_purge: deleteFileAbsolute({s}) failed: {s}", .{ p, @errorName(err) }),
            };
            // Drop SQLite sidecar files too if the DB ever ran in WAL mode.
            const wal = std.fmt.allocPrint(res.arena, "{s}-wal", .{p}) catch null;
            if (wal) |w| std.fs.deleteFileAbsolute(w) catch {};
            const shm = std.fmt.allocPrint(res.arena, "{s}-shm", .{p}) catch null;
            if (shm) |s| std.fs.deleteFileAbsolute(s) catch {};
            purged_db = true;
        }
    }

    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = if (purge) "project_delete_purge" else "project_delete",
        .target = id,
    });
    try res.json(.{ .ok = true, .purged_files = purged_files, .purged_db = purged_db }, .{});
}

// id-validating helper: must be 16 hex chars.
fn isValidProjectId(id: []const u8) bool {
    if (id.len != 16) return false;
    for (id) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return false;
    }
    return true;
}

fn apiProjectSecretsList(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const id = req.query() catch return res.json(.{ .ok = false, .err = "bad_query" }, .{});
    const project_id = id.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    if (!isValidProjectId(project_id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    if (app.projects.getById(project_id) == null) {
        res.status = 404;
        try res.json(.{ .ok = false, .err = "not_found" }, .{});
        return;
    }

    const keys = projsecrets.Vault.listKeys(res.arena, app.pepper, project_id) catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "vault_unreadable" }, .{});
        return;
    };
    try res.json(.{ .ok = true, .keys = keys }, .{});
}

fn apiProjectSecretsSet(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const project_id = form.get("project_id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_project_id" }, .{});
        return;
    };
    if (!isValidProjectId(project_id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    if (app.projects.getById(project_id) == null) {
        res.status = 404;
        try res.json(.{ .ok = false, .err = "not_found" }, .{});
        return;
    }
    const k = form.get("key") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_key" }, .{});
        return;
    };
    const v = form.get("value") orelse "";
    if (!projsecrets.isValidKey(k)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_key" }, .{});
        return;
    }

    projsecrets.Vault.setOne(app.allocator, app.pepper, project_id, k, v) catch |err| {
        const code: []const u8 = switch (err) {
            error.InvalidKey => "invalid_key",
            error.TooLarge => "too_large",
            else => "set_failed",
        };
        res.status = 500;
        try res.json(.{ .ok = false, .err = code }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "secret_set",
        .target = project_id,
        .detail = k,
    });
    try res.json(.{ .ok = true }, .{});
}

fn apiProjectSecretsDelete(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const project_id = form.get("project_id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_project_id" }, .{});
        return;
    };
    if (!isValidProjectId(project_id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    const k = form.get("key") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_key" }, .{});
        return;
    };
    projsecrets.Vault.setOne(app.allocator, app.pepper, project_id, k, "") catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "delete_failed" }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "secret_delete",
        .target = project_id,
        .detail = k,
    });
    try res.json(.{ .ok = true }, .{});
}

fn apiProjectsDeploy(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const id = form.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    if (!isValidProjectId(id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    if (app.projects.getById(id) == null) {
        res.status = 404;
        try res.json(.{ .ok = false, .err = "not_found" }, .{});
        return;
    }
    app.builder.deployAsync(id) catch |err| {
        const code: []const u8 = switch (err) {
            error.AlreadyInFlight => "already_in_flight",
            else => "deploy_failed",
        };
        res.status = 409;
        try res.json(.{ .ok = false, .err = code }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "project_deploy",
        .target = id,
    });
    try res.json(.{ .ok = true, .triggered = true }, .{});
}

fn apiProjectsLogs(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const q = req.query() catch return res.json(.{ .ok = false, .err = "bad_query" }, .{});
    const id = q.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    if (!isValidProjectId(id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    if (app.projects.getById(id) == null) {
        res.status = 404;
        try res.json(.{ .ok = false, .err = "not_found" }, .{});
        return;
    }
    const tail = builder.tailLog(res.arena, id, 64 * 1024) catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "log_read_failed" }, .{});
        return;
    };
    res.content_type = .JSON;
    var out = std.ArrayList(u8).init(res.arena);
    try out.appendSlice("{\"ok\":true,\"log\":");
    try std.json.stringify(tail, .{}, out.writer());
    try out.appendSlice("}");
    res.body = try out.toOwnedSlice();
}

fn handleGithubWebhook(app: *App, req: *httpz.Request, res: *httpz.Response, project_id: []const u8) !void {
    if (!isValidProjectId(project_id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    const project = app.projects.getById(project_id) orelse {
        res.status = 404;
        try res.json(.{ .ok = false, .err = "not_found" }, .{});
        return;
    };

    const sig = req.header("x-hub-signature-256") orelse req.header("X-Hub-Signature-256") orelse "";
    const body = req.body() orelse "";
    if (!builder.verifyGithubSignature(project.webhook_secret, sig, body)) {
        res.status = 401;
        try res.json(.{ .ok = false, .err = "invalid_signature" }, .{});
        return;
    }

    // Honour the 'ping' event by just acking.
    const event = req.header("x-github-event") orelse req.header("X-GitHub-Event") orelse "";
    if (std.mem.eql(u8, event, "ping")) {
        try res.json(.{ .ok = true, .pong = true }, .{});
        return;
    }
    if (!std.mem.eql(u8, event, "push") and event.len > 0) {
        try res.json(.{ .ok = true, .ignored = event }, .{});
        return;
    }

    // Optional: only deploy when the pushed branch matches project.branch.
    // GitHub push payload contains a "ref":"refs/heads/<branch>" field. We do a
    // simple substring check to avoid pulling in a full JSON parser path here.
    const expected = std.fmt.allocPrint(res.arena, "\"ref\":\"refs/heads/{s}\"", .{project.branch}) catch null;
    if (expected) |e| {
        if (std.mem.indexOf(u8, body, e) == null and body.len > 0) {
            try res.json(.{ .ok = true, .ignored = "branch mismatch" }, .{});
            return;
        }
    }

    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = "github_webhook",
        .action = "project_deploy",
        .target = project_id,
    });
    app.builder.deployAsync(project_id) catch |err| {
        const code: []const u8 = switch (err) {
            error.AlreadyInFlight => "already_in_flight",
            else => "deploy_failed",
        };
        res.status = 202;
        try res.json(.{ .ok = false, .err = code }, .{});
        return;
    };
    try res.json(.{ .ok = true, .triggered = true }, .{});
}

fn apiProjectsStart(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const id = form.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    if (!isValidProjectId(id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    const project = app.projects.getById(id) orelse {
        res.status = 404;
        try res.json(.{ .ok = false, .err = "not_found" }, .{});
        return;
    };

    // Static projects: just flip the registry status. The static serving path
    // honors .stopped and serves a 'site paused' page instead of the build
    // output.
    if (project.runtime == .static) {
        if (project.status == .running) {
            res.status = 400;
            try res.json(.{ .ok = false, .err = "already_running" }, .{});
            return;
        }
        _ = app.projects.update(id, .{ .status = .running }) catch {
            res.status = 500;
            try res.json(.{ .ok = false, .err = "update_failed" }, .{});
            return;
        };
        audit.append(.{
            .timestamp = std.time.timestamp(),
            .actor = actor,
            .action = "project_start",
            .target = id,
        });
        try res.json(.{ .ok = true }, .{});
        return;
    }

    app.supervisor.start(id) catch |err| {
        const code: []const u8 = switch (err) {
            error.NotFound => "not_found",
            error.StaticProject => "static_project",
            error.NoStartCommand => "no_start_cmd",
            error.AlreadyRunning => "already_running",
            else => "start_failed",
        };
        res.status = 400;
        try res.json(.{ .ok = false, .err = code }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "project_start",
        .target = id,
    });
    try res.json(.{ .ok = true }, .{});
}

fn apiProjectsStop(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const id = form.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    if (!isValidProjectId(id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    const project = app.projects.getById(id) orelse {
        res.status = 404;
        try res.json(.{ .ok = false, .err = "not_found" }, .{});
        return;
    };

    // Static projects: flip status to stopped. The static serving path will
    // return a 'site paused' page instead of the build output.
    if (project.runtime == .static) {
        if (project.status == .stopped) {
            res.status = 400;
            try res.json(.{ .ok = false, .err = "not_running" }, .{});
            return;
        }
        _ = app.projects.update(id, .{ .status = .stopped }) catch {
            res.status = 500;
            try res.json(.{ .ok = false, .err = "update_failed" }, .{});
            return;
        };
        audit.append(.{
            .timestamp = std.time.timestamp(),
            .actor = actor,
            .action = "project_stop",
            .target = id,
        });
        try res.json(.{ .ok = true }, .{});
        return;
    }

    app.supervisor.stop(id) catch |err| {
        const code: []const u8 = switch (err) {
            error.NotFound => "not_found",
            error.StaticProject => "static_project",
            error.NotRunning => "not_running",
            else => "stop_failed",
        };
        res.status = 400;
        try res.json(.{ .ok = false, .err = code }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "project_stop",
        .target = id,
    });
    try res.json(.{ .ok = true }, .{});
}

fn apiProjectsRestart(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const id = form.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    if (!isValidProjectId(id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    const project = app.projects.getById(id) orelse {
        res.status = 404;
        try res.json(.{ .ok = false, .err = "not_found" }, .{});
        return;
    };

    // Static projects: restart is just a status flip to running. No process
    // to recycle.
    if (project.runtime == .static) {
        _ = app.projects.update(id, .{ .status = .running }) catch {
            res.status = 500;
            try res.json(.{ .ok = false, .err = "update_failed" }, .{});
            return;
        };
        audit.append(.{
            .timestamp = std.time.timestamp(),
            .actor = actor,
            .action = "project_restart",
            .target = id,
        });
        try res.json(.{ .ok = true }, .{});
        return;
    }

    app.supervisor.restart(id) catch |err| {
        const code: []const u8 = switch (err) {
            error.NotFound => "not_found",
            error.StaticProject => "static_project",
            error.NoStartCommand => "no_start_cmd",
            error.AlreadyRunning => "already_running",
            else => "restart_failed",
        };
        res.status = 400;
        try res.json(.{ .ok = false, .err = code }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "project_restart",
        .target = id,
    });
    try res.json(.{ .ok = true }, .{});
}

fn apiProjectsRuntimeLogs(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = app;
    const q = req.query() catch return res.json(.{ .ok = false, .err = "bad_query" }, .{});
    const id = q.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    if (!isValidProjectId(id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    const tail = supervisor.tailLog(res.arena, id, 64 * 1024) catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "log_read_failed" }, .{});
        return;
    };
    var out = std.ArrayList(u8).init(res.arena);
    try out.appendSlice("{\"ok\":true,\"log\":");
    try std.json.stringify(tail, .{}, out.writer());
    try out.appendSlice("}");
    res.content_type = .JSON;
    res.body = try out.toOwnedSlice();
}

fn apiProjectsStatus(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const q = req.query() catch return res.json(.{ .ok = false, .err = "bad_query" }, .{});
    const id = q.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    if (!isValidProjectId(id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    const s = app.supervisor.statusOf(id);
    const project = app.projects.getById(id);
    const rss_limit_mb: u32 = if (project) |p| p.rss_limit_mb else 0;
    try res.json(.{
        .ok = true,
        .state = @tagName(s.state),
        .pid = if (s.pid) |p| @as(i64, @intCast(p)) else null,
        .started_at = s.started_at,
        .crash_count = s.crash_count,
        .last_exit = s.last_exit,
        .rss_kb = s.rss_kb,
        .rss_mb = s.rss_kb / 1024,
        .rss_limit_mb = rss_limit_mb,
        .last_kill_reason = @tagName(s.last_kill_reason),
    }, .{});
}

// =================================================================
// PROJECT AUTH (built-in signup/login/verify per project)
// =================================================================
fn tryServeAuth(app: *App, req: *httpz.Request, project: projects.Project, req_path: []const u8, res: *httpz.Response) !bool {
    var svc = projauth.Service.init(app.allocator, app.pepper, app.dbpool);

    // CORS for any origin so the project's own SPA can call these endpoints
    res.header("Access-Control-Allow-Origin", "*");
    res.header("Access-Control-Allow-Methods", "POST, GET, OPTIONS");
    res.header("Access-Control-Allow-Headers", "Content-Type, Authorization");
    if (req.method == .OPTIONS) {
        res.status = 204;
        res.body = "";
        return true;
    }

    if (std.mem.eql(u8, req_path, "/auth/signup") or std.mem.eql(u8, req_path, "/auth/login")) {
        const body = req.body() orelse "";
        const Payload = struct { email: []const u8, password: []const u8 };
        const parsed = std.json.parseFromSlice(Payload, res.arena, body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            res.status = 400;
            try res.json(.{ .ok = false, .err = "invalid_json" }, .{});
            return true;
        };
        defer parsed.deinit();
        const p = parsed.value;

        if (std.mem.eql(u8, req_path, "/auth/signup")) {
            const r = svc.signup(project.id, p.email, p.password) catch |err| {
                const code: []const u8 = switch (err) {
                    error.InvalidEmail => "invalid_email",
                    error.WeakPassword => "weak_password",
                    error.EmailTaken => "email_taken",
                    else => "signup_failed",
                };
                res.status = 400;
                try res.json(.{ .ok = false, .err = code }, .{});
                return true;
            };
            // Token owned by allocator; copy to arena and free original.
            const token_arena = try res.arena.dupe(u8, r.token);
            app.allocator.free(r.token);
            try res.json(.{ .ok = true, .user_id = r.user_id, .token = token_arena }, .{});
            return true;
        } else {
            const r = svc.login(project.id, p.email, p.password) catch {
                res.status = 401;
                try res.json(.{ .ok = false, .err = "auth_failed" }, .{});
                return true;
            };
            const token_arena = try res.arena.dupe(u8, r.token);
            app.allocator.free(r.token);
            try res.json(.{ .ok = true, .user_id = r.user_id, .token = token_arena }, .{});
            return true;
        }
    }

    if (std.mem.eql(u8, req_path, "/auth/verify")) {
        const auth_h = req.header("authorization") orelse req.header("Authorization") orelse "";
        const prefix = "Bearer ";
        if (auth_h.len <= prefix.len or !std.mem.startsWith(u8, auth_h, prefix)) {
            res.status = 401;
            try res.json(.{ .ok = false, .err = "missing_bearer" }, .{});
            return true;
        }
        const token = auth_h[prefix.len..];
        const user_id = svc.verifyToken(project.id, token) catch {
            res.status = 401;
            try res.json(.{ .ok = false, .err = "invalid_token" }, .{});
            return true;
        };
        try res.json(.{ .ok = true, .user_id = user_id }, .{});
        return true;
    }

    res.status = 404;
    try res.json(.{ .ok = false, .err = "unknown_auth_endpoint" }, .{});
    return true;
}

// =================================================================
// PROJECT ZIP UPLOAD + RELEASES + ROLLBACK
// =================================================================
fn apiProjectsUpload(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";

    // Expect: multipart with field 'id' = project_id, and the rest of the body
    // is the raw zip bytes posted as a single 'file' field. httpz form parser
    // doesn't expose multipart files cleanly, so we use a simpler protocol:
    // the operator uploads via PUT-like POST where the URL has ?id=<pid> and
    // the body IS the raw zip content (Content-Type: application/zip).
    const q = req.query() catch return res.json(.{ .ok = false, .err = "bad_query" }, .{});
    const project_id = q.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    if (!isValidProjectId(project_id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    const project = app.projects.getById(project_id) orelse {
        res.status = 404;
        try res.json(.{ .ok = false, .err = "not_found" }, .{});
        return;
    };
    if (project.runtime != .static) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "not_static" }, .{});
        return;
    }

    const body = req.body() orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_body" }, .{});
        return;
    };
    // Sanity-check: zip starts with PK\x03\x04 (or PK\x05\x06 for empty).
    if (body.len < 4 or body[0] != 'P' or body[1] != 'K') {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "not_a_zip" }, .{});
        return;
    }

    // Write to ~/data/projects/<id>/.upload.zip
    const work = try projects.Manager.workingDir(res.arena, project_id);
    std.fs.makeDirAbsolute(work) catch {};
    const tmp_path = try std.fmt.allocPrint(res.arena, "{s}/.upload.zip", .{work});
    var f = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true, .mode = 0o600 });
    f.writeAll(body) catch |err| {
        f.close();
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        res.status = 500;
        try res.json(.{ .ok = false, .err = @errorName(err) }, .{});
        return;
    };
    f.close();

    builder.deployZip(app.builder, project_id, tmp_path) catch |err| {
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        const code: []const u8 = switch (err) {
            error.NotStaticProject => "not_static",
            error.UnzipFailed => "unzip_failed",
            error.PublishDirMissing => "publish_dir_missing",
            error.SwapFailed => "swap_failed",
            else => "deploy_failed",
        };
        res.status = 500;
        try res.json(.{ .ok = false, .err = code }, .{});
        return;
    };
    std.fs.deleteFileAbsolute(tmp_path) catch {};

    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "project_zip_deploy",
        .target = project_id,
    });
    try res.json(.{ .ok = true, .bytes = body.len }, .{});
}

fn apiProjectsReleases(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const q = req.query() catch return res.json(.{ .ok = false, .err = "bad_query" }, .{});
    const id = q.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    if (!isValidProjectId(id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    if (app.projects.getById(id) == null) {
        res.status = 404;
        try res.json(.{ .ok = false, .err = "not_found" }, .{});
        return;
    }

    const list = builder.listReleases(res.arena, id) catch &[_][]u8{};
    const current = builder.readCurrentRelease(res.arena, id) catch try res.arena.dupe(u8, "");

    var out = std.ArrayList(u8).init(res.arena);
    const w = out.writer();
    try w.writeAll("{\"ok\":true,\"current\":\"");
    try w.writeAll(current);
    try w.writeAll("\",\"releases\":[");
    for (list, 0..) |name, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('"');
        try w.writeAll(name);
        try w.writeByte('"');
    }
    try w.writeAll("]}");
    res.content_type = .JSON;
    res.body = try out.toOwnedSlice();
}

fn apiProjectsRollback(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const id = form.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    const release = form.get("release") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_release" }, .{});
        return;
    };
    if (!isValidProjectId(id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    if (app.projects.getById(id) == null) {
        res.status = 404;
        try res.json(.{ .ok = false, .err = "not_found" }, .{});
        return;
    }
    builder.rollbackTo(app.allocator, id, release) catch |err| {
        const code: []const u8 = switch (err) {
            error.InvalidRelease => "invalid_release",
            error.NotFound => "release_not_found",
            else => "rollback_failed",
        };
        res.status = 400;
        try res.json(.{ .ok = false, .err = code }, .{});
        return;
    };
    // For backend projects, restart so they pick up the rolled-back code.
    const project = app.projects.getById(id).?;
    if (project.runtime != .static) {
        app.supervisor.restart(id) catch {};
    }
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "project_rollback",
        .target = id,
        .detail = release,
    });
    try res.json(.{ .ok = true, .release = release }, .{});
}

// =================================================================
// PER-PROJECT SQL RUNNER (Supabase-style query UI)
// =================================================================
fn apiProjectsSql(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const body = req.body() orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_body" }, .{});
        return;
    };
    const Payload = struct {
        project_id: []const u8,
        sql: []const u8,
    };
    const parsed = std.json.parseFromSlice(Payload, res.arena, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_json" }, .{});
        return;
    };
    defer parsed.deinit();
    const p = parsed.value;
    if (!isValidProjectId(p.project_id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    if (app.projects.getById(p.project_id) == null) {
        res.status = 404;
        try res.json(.{ .ok = false, .err = "not_found" }, .{});
        return;
    }
    if (p.sql.len == 0 or p.sql.len > 256 * 1024) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_sql_size" }, .{});
        return;
    }

    // Run via one-shot sqlite3 against ~/data/dbs/<project_id>.db with
    // .mode json so the result comes back as JSON rows.
    const db_path = try std.fmt.allocPrint(res.arena, "/data/data/com.termux/files/home/data/dbs/{s}.db", .{p.project_id});
    std.fs.makeDirAbsolute("/data/data/com.termux/files/home/data/dbs") catch {};

    var script = std.ArrayList(u8).init(res.arena);
    try script.appendSlice(".mode json\n");
    try script.appendSlice(p.sql);
    if (script.items.len == 0 or script.items[script.items.len - 1] != '\n') try script.appendSlice("\n");

    var argv = [_][]const u8{ "sqlite3", "-batch", "-bail", db_path };
    var child = std.process.Child.init(&argv, app.allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "spawn_failed" }, .{});
        return;
    };
    if (child.stdin) |stdin| {
        stdin.writeAll(script.items) catch {};
        stdin.close();
        child.stdin = null;
    }
    var stdout_buf = std.ArrayList(u8).init(res.arena);
    if (child.stdout) |stdout| {
        var rb: [8192]u8 = undefined;
        while (true) {
            const n = stdout.read(&rb) catch 0;
            if (n == 0) break;
            stdout_buf.appendSlice(rb[0..n]) catch break;
            if (stdout_buf.items.len > 8 * 1024 * 1024) break;
        }
    }
    var stderr_buf: [4096]u8 = undefined;
    var stderr_n: usize = 0;
    if (child.stderr) |stderr| stderr_n = stderr.read(&stderr_buf) catch 0;
    const term = child.wait() catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "wait_failed" }, .{});
        return;
    };
    const exit_code = switch (term) {
        .Exited => |c| c,
        else => 1,
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "project_sql",
        .target = p.project_id,
        .ok = exit_code == 0,
    });
    if (exit_code != 0) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "sql_error", .stderr = stderr_buf[0..@min(stderr_n, 1024)] }, .{});
        return;
    }
    var envelope = std.ArrayList(u8).init(res.arena);
    try envelope.appendSlice("{\"ok\":true,\"result\":");
    const trimmed = std.mem.trim(u8, stdout_buf.items, " \t\r\n");
    if (trimmed.len == 0) {
        try envelope.appendSlice("[]");
    } else {
        try envelope.appendSlice(trimmed);
    }
    try envelope.appendSlice("}");
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, envelope.items);
}

// =================================================================
// CRON / SCHEDULED TASKS
// =================================================================
fn apiCronList(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const q = req.query() catch return res.json(.{ .ok = false, .err = "bad_query" }, .{});
    const project_id = q.get("project_id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_project_id" }, .{});
        return;
    };
    if (!isValidProjectId(project_id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    const json_body = app.cron.listForProject(res.arena, project_id) catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "list_failed" }, .{});
        return;
    };
    res.content_type = .JSON;
    res.body = json_body;
}

fn apiCronCreate(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const project_id = form.get("project_id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_project_id" }, .{});
        return;
    };
    const name = form.get("name") orelse "task";
    const schedule = form.get("schedule") orelse "";
    const command = form.get("command") orelse "";
    if (!isValidProjectId(project_id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    const t = app.cron.create(name, project_id, schedule, command) catch |err| {
        const code: []const u8 = switch (err) {
            error.InvalidName => "invalid_name",
            error.InvalidCommand => "invalid_command",
            error.InvalidSchedule => "invalid_schedule",
            error.ProjectNotFound => "project_not_found",
            else => "create_failed",
        };
        res.status = 400;
        try res.json(.{ .ok = false, .err = code }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "cron_create",
        .target = project_id,
        .detail = name,
    });
    try res.json(.{ .ok = true, .id = t.id }, .{});
}

fn apiCronDelete(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const id = form.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    app.cron.delete(id) catch {
        res.status = 404;
        try res.json(.{ .ok = false, .err = "not_found" }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "cron_delete",
        .target = id,
    });
    try res.json(.{ .ok = true }, .{});
}

fn apiCronToggle(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const id = form.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    const enabled_str = form.get("enabled") orelse "true";
    const enabled = std.mem.eql(u8, enabled_str, "true") or std.mem.eql(u8, enabled_str, "on") or std.mem.eql(u8, enabled_str, "1");
    app.cron.toggle(id, enabled) catch {
        res.status = 404;
        try res.json(.{ .ok = false, .err = "not_found" }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "cron_toggle",
        .target = id,
        .detail = if (enabled) "on" else "off",
    });
    try res.json(.{ .ok = true }, .{});
}

fn apiCronRun(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = auth.currentUser(app.auth_cfg, app.allocator, req) orelse "unknown";
    const form = req.formData() catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "bad_form" }, .{});
        return;
    };
    const id = form.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    app.cron.runOnce(id) catch |err| {
        const code: []const u8 = switch (err) {
            error.NotFound => "not_found",
            error.ProjectNotFound => "project_not_found",
            else => "run_failed",
        };
        res.status = 500;
        try res.json(.{ .ok = false, .err = code }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "cron_run",
        .target = id,
    });
    try res.json(.{ .ok = true }, .{});
}

// =================================================================
// PROJECT IMPORT WIZARD HELPERS
// =================================================================

/// Shallow-clone or unzip a repo URL to ~/.tmp-preview/<random>/, run the
/// framework detector against it, return the suggestions, then delete the
/// temp tree. Lets the wizard show pre-filled commands like Netlify does.
fn apiProjectsPreviewRepo(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = app;
    const body = req.body() orelse "";
    const Payload = struct {
        repo_url: []const u8,
        branch: []const u8 = "main",
    };
    const parsed = std.json.parseFromSlice(Payload, res.arena, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_json" }, .{});
        return;
    };
    defer parsed.deinit();
    const p = parsed.value;
    if (p.repo_url.len == 0 or p.repo_url.len > 512) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_repo_url" }, .{});
        return;
    }
    if (!std.mem.startsWith(u8, p.repo_url, "https://") and !std.mem.startsWith(u8, p.repo_url, "git@")) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_protocol" }, .{});
        return;
    }

    const tmp_root = "/data/data/com.termux/files/home/.tmp-preview";
    std.fs.makeDirAbsolute(tmp_root) catch {};
    var rand: [8]u8 = undefined;
    std.crypto.random.bytes(&rand);
    const cs = "0123456789abcdef";
    var rand_hex: [16]u8 = undefined;
    for (rand, 0..) |b, i| {
        rand_hex[i * 2] = cs[b >> 4];
        rand_hex[i * 2 + 1] = cs[b & 0xf];
    }
    const tmp_dir = try std.fmt.allocPrint(res.arena, "{s}/{s}", .{ tmp_root, &rand_hex });
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    // git clone with auto-fallback to default branch if requested branch fails
    var stderr_buf: [2048]u8 = undefined;
    var stderr_n: usize = 0;
    const used_branch = cloneWithFallback(res.arena, p.repo_url, p.branch, tmp_dir, &stderr_buf, &stderr_n) orelse {
        res.status = 400;
        try res.json(.{
            .ok = false,
            .err = "clone_failed",
            .stderr = stderr_buf[0..@min(stderr_n, 1024)],
        }, .{});
        return;
    };

    const sug = detect.detect(res.arena, tmp_dir) catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "detect_failed" }, .{});
        return;
    };
    const name_hint = detect.nameFromRepo(res.arena, p.repo_url) catch try res.arena.dupe(u8, "");
    const sub_hint = detect.suggestSubdomain(res.arena, name_hint) catch try res.arena.dupe(u8, "");

    try res.json(.{
        .ok = true,
        .suggested_name = name_hint,
        .suggested_subdomain = sub_hint,
        .actual_branch = used_branch,
        .runtime = sug.runtime,
        .install_cmd = sug.install_cmd,
        .build_cmd = sug.build_cmd,
        .start_cmd = sug.start_cmd,
        .publish_dir = sug.publish_dir,
        .framework_hint = sug.framework_hint,
    }, .{});
}

/// List users in the per-project auth DB.
fn apiProjectsUsers(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = app;
    const q = req.query() catch return res.json(.{ .ok = false, .err = "bad_query" }, .{});
    const id = q.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    if (!isValidProjectId(id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    const db_path = try std.fmt.allocPrint(res.arena, "/data/data/com.termux/files/home/data/dbs/{s}.db", .{id});
    // Check db file exists
    std.fs.accessAbsolute(db_path, .{}) catch {
        try res.json(.{ .ok = true, .users = &[_]u8{} }, .{});
        return;
    };

    const sql =
        \\.mode json
        \\SELECT id, email, created_at, last_login FROM users ORDER BY id DESC LIMIT 200;
        \\
    ;
    var argv = [_][]const u8{ "sqlite3", "-batch", db_path };
    var child = std.process.Child.init(&argv, res.arena);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "spawn_failed" }, .{});
        return;
    };
    if (child.stdin) |stdin| {
        stdin.writeAll(sql) catch {};
        stdin.close();
        child.stdin = null;
    }
    var stdout_buf = std.ArrayList(u8).init(res.arena);
    if (child.stdout) |stdout| {
        var rb: [4096]u8 = undefined;
        while (true) {
            const n = stdout.read(&rb) catch 0;
            if (n == 0) break;
            stdout_buf.appendSlice(rb[0..n]) catch break;
        }
    }
    _ = child.wait() catch {};

    res.content_type = .JSON;
    var out = std.ArrayList(u8).init(res.arena);
    try out.appendSlice("{\"ok\":true,\"users\":");
    const trimmed = std.mem.trim(u8, stdout_buf.items, " \t\r\n");
    try out.appendSlice(if (trimmed.len > 0) trimmed else "[]");
    try out.appendSlice("}");
    res.body = try out.toOwnedSlice();
}

/// List tables in the per-project DB. Used to populate the Database tab.
fn apiProjectsTables(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = app;
    const q = req.query() catch return res.json(.{ .ok = false, .err = "bad_query" }, .{});
    const id = q.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    if (!isValidProjectId(id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }
    const db_path = try std.fmt.allocPrint(res.arena, "/data/data/com.termux/files/home/data/dbs/{s}.db", .{id});
    std.fs.accessAbsolute(db_path, .{}) catch {
        try res.json(.{ .ok = true, .tables = &[_]u8{} }, .{});
        return;
    };

    const sql =
        \\.mode json
        \\SELECT name, (SELECT COUNT(*) FROM pragma_table_info(m.name)) as col_count FROM sqlite_master m WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;
        \\
    ;
    var argv = [_][]const u8{ "sqlite3", "-batch", db_path };
    var child = std.process.Child.init(&argv, res.arena);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        try res.json(.{ .ok = true, .tables = &[_]u8{} }, .{});
        return;
    };
    if (child.stdin) |stdin| {
        stdin.writeAll(sql) catch {};
        stdin.close();
        child.stdin = null;
    }
    var stdout_buf = std.ArrayList(u8).init(res.arena);
    if (child.stdout) |stdout| {
        var rb: [4096]u8 = undefined;
        while (true) {
            const n = stdout.read(&rb) catch 0;
            if (n == 0) break;
            stdout_buf.appendSlice(rb[0..n]) catch break;
        }
    }
    _ = child.wait() catch {};

    res.content_type = .JSON;
    var out = std.ArrayList(u8).init(res.arena);
    try out.appendSlice("{\"ok\":true,\"tables\":");
    const trimmed = std.mem.trim(u8, stdout_buf.items, " \t\r\n");
    try out.appendSlice(if (trimmed.len > 0) trimmed else "[]");
    try out.appendSlice("}");
    res.body = try out.toOwnedSlice();
}

/// SSE endpoint that streams the build log of a project as it grows. Used by
/// the wizard's 'deploying...' screen so the operator sees output live.
fn apiProjectsLogStream(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = app;
    const q = req.query() catch return res.json(.{ .ok = false, .err = "bad_query" }, .{});
    const id = q.get("id") orelse {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "missing_id" }, .{});
        return;
    };
    const kind = q.get("kind") orelse "build"; // build|runtime|cron
    if (!isValidProjectId(id)) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_id" }, .{});
        return;
    }

    const log_name: []const u8 = if (std.mem.eql(u8, kind, "runtime"))
        "runtime.log"
    else if (std.mem.eql(u8, kind, "cron"))
        "cron.log"
    else
        "build.log";

    const log_path = try std.fmt.allocPrint(res.arena, "/data/data/com.termux/files/home/data/projects/{s}/logs/{s}", .{ id, log_name });

    res.header("Content-Type", "text/event-stream");
    res.header("Cache-Control", "no-cache");
    res.header("X-Accel-Buffering", "no");

    var stream = try res.startEventStreamSync();

    // Tail-follow: send what's there now, then poll the file size every 500ms.
    var offset: u64 = 0;
    var idle_ticks: u32 = 0;
    const MAX_IDLE: u32 = 240; // 2 minutes of silence -> close
    while (idle_ticks < MAX_IDLE) {
        const file = std.fs.openFileAbsolute(log_path, .{}) catch {
            // Send a comment so the connection stays warm even if file isn't
            // there yet (deploy hasn't started).
            stream.writeAll(":waiting\n\n") catch break;
            std.Thread.sleep(500 * std.time.ns_per_ms);
            idle_ticks += 1;
            continue;
        };
        defer file.close();

        const stat = file.stat() catch break;
        if (stat.size > offset) {
            const to_read = stat.size - offset;
            const chunk = std.heap.page_allocator.alloc(u8, to_read) catch break;
            defer std.heap.page_allocator.free(chunk);
            file.seekTo(offset) catch break;
            const n = file.readAll(chunk) catch 0;
            // Emit as SSE data line(s). Split on newlines so the client gets
            // one event per line (cleaner UX).
            var line_iter = std.mem.splitScalar(u8, chunk[0..n], '\n');
            while (line_iter.next()) |line| {
                if (line.len == 0) continue;
                stream.writeAll("data: ") catch return;
                stream.writeAll(line) catch return;
                stream.writeAll("\n\n") catch return;
            }
            offset += n;
            idle_ticks = 0;
        } else {
            stream.writeAll(":heartbeat\n\n") catch break;
            idle_ticks += 1;
        }

        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
    stream.writeAll("event: end\ndata: done\n\n") catch {};
}

// =================================================================
// PROJECT AI ANALYZER (best-fit deploy config)
// =================================================================
fn apiProjectsAnalyze(app: *App, req: *httpz.Request, res: *httpz.Response) !void {
    if (!app.ai_cfg.enabled()) {
        res.status = 503;
        try res.json(.{ .ok = false, .err = "ai_disabled" }, .{});
        return;
    }
    const body = req.body() orelse "";
    const Payload = struct {
        repo_url: []const u8,
        branch: []const u8 = "main",
    };
    const parsed = std.json.parseFromSlice(Payload, res.arena, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_json" }, .{});
        return;
    };
    defer parsed.deinit();
    const p = parsed.value;
    if (p.repo_url.len == 0 or p.repo_url.len > 512) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_repo_url" }, .{});
        return;
    }
    if (!std.mem.startsWith(u8, p.repo_url, "https://") and !std.mem.startsWith(u8, p.repo_url, "git@")) {
        res.status = 400;
        try res.json(.{ .ok = false, .err = "invalid_protocol" }, .{});
        return;
    }

    const tmp_root = "/data/data/com.termux/files/home/.tmp-preview";
    std.fs.makeDirAbsolute(tmp_root) catch {};
    var rand: [8]u8 = undefined;
    std.crypto.random.bytes(&rand);
    const cs = "0123456789abcdef";
    var rand_hex: [16]u8 = undefined;
    for (rand, 0..) |b, i| {
        rand_hex[i * 2] = cs[b >> 4];
        rand_hex[i * 2 + 1] = cs[b & 0xf];
    }
    const tmp_dir = try std.fmt.allocPrint(res.arena, "{s}/{s}", .{ tmp_root, &rand_hex });
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    // Shallow clone with fallback to default branch if the requested one fails
    var clone_err_buf: [1024]u8 = undefined;
    var clone_err_n: usize = 0;
    const used_branch = cloneWithFallback(res.arena, p.repo_url, p.branch, tmp_dir, &clone_err_buf, &clone_err_n) orelse {
        res.status = 400;
        try res.json(.{
            .ok = false,
            .err = "clone_failed",
            .stderr = clone_err_buf[0..@min(clone_err_n, 512)],
        }, .{});
        return;
    };

    // Detect framework first
    const sug = detect.detect(res.arena, tmp_dir) catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "detect_failed" }, .{});
        return;
    };

    // Read package.json (truncated)
    const pkg_path = try std.fmt.allocPrint(res.arena, "{s}/package.json", .{tmp_dir});
    var pkg_content: []const u8 = "";
    if (std.fs.openFileAbsolute(pkg_path, .{})) |pf| {
        defer pf.close();
        pkg_content = pf.readToEndAlloc(res.arena, 6 * 1024) catch "";
    } else |_| {}

    // Read README (truncated)
    const readme_paths = [_][]const u8{ "README.md", "readme.md", "README", "Readme.md" };
    var readme_content: []const u8 = "";
    for (readme_paths) |rp| {
        const path_full = std.fmt.allocPrint(res.arena, "{s}/{s}", .{ tmp_dir, rp }) catch continue;
        if (std.fs.openFileAbsolute(path_full, .{})) |rf| {
            defer rf.close();
            readme_content = rf.readToEndAlloc(res.arena, 2 * 1024) catch "";
            if (readme_content.len > 0) break;
        } else |_| {}
    }

    // List repo root files (only top-level, max 50)
    var file_list_buf = std.ArrayList(u8).init(res.arena);
    if (std.fs.openDirAbsolute(tmp_dir, .{ .iterate = true })) |*dir_const| {
        var dir = dir_const.*;
        defer dir.close();
        var it = dir.iterate();
        var count: u32 = 0;
        while (it.next() catch null) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if (count >= 50) break;
            file_list_buf.appendSlice(entry.name) catch break;
            file_list_buf.append('\n') catch break;
            count += 1;
        }
    } else |_| {}

    const ai_result = ai.analyzeProject(app.ai_cfg, res.arena, .{
        .framework_hint = sug.framework_hint,
        .detected_runtime = sug.runtime,
        .detected_install = sug.install_cmd,
        .detected_build = sug.build_cmd,
        .detected_start = sug.start_cmd,
        .detected_publish = sug.publish_dir,
        .package_json_excerpt = pkg_content,
        .readme_excerpt = readme_content,
        .file_list = file_list_buf.items,
    }) orelse {
        res.status = 502;
        try res.json(.{ .ok = false, .err = "ai_failed" }, .{});
        return;
    };

    // ai_result is already a JSON object. Wrap it with detection metadata.
    var envelope = std.ArrayList(u8).init(res.arena);
    try envelope.appendSlice("{\"ok\":true,\"detected\":{");
    try envelope.appendSlice("\"actual_branch\":");
    try std.json.stringify(used_branch, .{}, envelope.writer());
    try envelope.appendSlice(",\"framework_hint\":");
    try std.json.stringify(sug.framework_hint, .{}, envelope.writer());
    try envelope.appendSlice(",\"runtime\":");
    try std.json.stringify(sug.runtime, .{}, envelope.writer());
    try envelope.appendSlice(",\"install_cmd\":");
    try std.json.stringify(sug.install_cmd, .{}, envelope.writer());
    try envelope.appendSlice(",\"build_cmd\":");
    try std.json.stringify(sug.build_cmd, .{}, envelope.writer());
    try envelope.appendSlice(",\"start_cmd\":");
    try std.json.stringify(sug.start_cmd, .{}, envelope.writer());
    try envelope.appendSlice(",\"publish_dir\":");
    try std.json.stringify(sug.publish_dir, .{}, envelope.writer());
    try envelope.appendSlice("},\"ai\":");
    try envelope.appendSlice(ai_result);
    try envelope.appendSlice("}");
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, envelope.items);
}

/// Resolve the default branch of a remote repo via `git ls-remote --symref <url> HEAD`.
/// Output looks like:
///   ref: refs/heads/master <TAB> HEAD
///   <sha> <TAB> HEAD
/// Returns owned slice with just the branch name (e.g. "master") or null on failure.
fn resolveDefaultBranch(allocator: std.mem.Allocator, repo_url: []const u8) ?[]u8 {
    var argv = [_][]const u8{ "git", "ls-remote", "--symref", repo_url, "HEAD" };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;
    var out_buf = std.ArrayList(u8).init(allocator);
    defer out_buf.deinit();
    if (child.stdout) |so| {
        var rb: [1024]u8 = undefined;
        while (true) {
            const n = so.read(&rb) catch 0;
            if (n == 0) break;
            out_buf.appendSlice(rb[0..n]) catch break;
        }
    }
    _ = child.wait() catch {};
    // Parse the first line "ref: refs/heads/<branch>\tHEAD"
    const first_nl = std.mem.indexOfScalar(u8, out_buf.items, '\n') orelse return null;
    const first_line = out_buf.items[0..first_nl];
    const prefix = "ref: refs/heads/";
    if (!std.mem.startsWith(u8, first_line, prefix)) return null;
    const after = first_line[prefix.len..];
    const tab = std.mem.indexOfScalar(u8, after, '\t') orelse after.len;
    const branch = std.mem.trim(u8, after[0..tab], " \t\r\n");
    if (branch.len == 0 or branch.len > 128) return null;
    return allocator.dupe(u8, branch) catch null;
}

/// Try to clone <repo_url> at <branch> into <dest>. If branch fails, attempt
/// to resolve the actual default branch and retry once. Returns the actual
/// branch name used on success, or null on failure (with stderr_buf populated).
fn cloneWithFallback(
    allocator: std.mem.Allocator,
    repo_url: []const u8,
    requested_branch: []const u8,
    dest: []const u8,
    stderr_out: []u8,
    stderr_n_out: *usize,
) ?[]u8 {
    stderr_n_out.* = 0;

    // Attempt 1: requested branch
    {
        var argv = [_][]const u8{ "git", "clone", "--depth=1", "--single-branch", "--branch", requested_branch, repo_url, dest };
        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Pipe;
        child.spawn() catch return null;
        // Drain stderr fully (small reads can miss the actual error message)
        if (child.stderr) |stderr| {
            var written: usize = 0;
            while (written < stderr_out.len) {
                const n = stderr.read(stderr_out[written..]) catch 0;
                if (n == 0) break;
                written += n;
            }
            stderr_n_out.* = written;
        }
        const term = child.wait() catch return null;
        const exit_code: i32 = switch (term) {
            .Exited => |c| @intCast(c),
            else => -1,
        };
        if (exit_code == 0) return allocator.dupe(u8, requested_branch) catch null;
    }

    // Attempt 2: resolve default branch, retry if different
    const default_branch = resolveDefaultBranch(allocator, repo_url) orelse return null;
    if (std.mem.eql(u8, default_branch, requested_branch)) {
        // Same branch; original failure stands.
        allocator.free(default_branch);
        return null;
    }

    // Clean up partial dir from first attempt if it exists
    std.fs.deleteTreeAbsolute(dest) catch {};

    var argv = [_][]const u8{ "git", "clone", "--depth=1", "--single-branch", "--branch", default_branch, repo_url, dest };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    child.spawn() catch {
        allocator.free(default_branch);
        return null;
    };
    stderr_n_out.* = 0;
    if (child.stderr) |stderr| {
        var written: usize = 0;
        while (written < stderr_out.len) {
            const n = stderr.read(stderr_out[written..]) catch 0;
            if (n == 0) break;
            written += n;
        }
        stderr_n_out.* = written;
    }
    const term = child.wait() catch {
        allocator.free(default_branch);
        return null;
    };
    const exit_code: i32 = switch (term) {
        .Exited => |c| @intCast(c),
        else => -1,
    };
    if (exit_code != 0) {
        allocator.free(default_branch);
        return null;
    }
    return default_branch;
}
