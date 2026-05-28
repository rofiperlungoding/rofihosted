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
const projsecrets = @import("projsecrets.zig");
const builder = @import("builder.zig");
const supervisor = @import("supervisor.zig");
const proxy = @import("proxy.zig");
const projauth = @import("projauth.zig");
const cron = @import("cron.zig");

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
    pepper: []const u8,
    /// Type-erased pointer to the httpz.Server(*App), set after server init.
    /// Used only by the SIGTERM handler to call .stop(). Casting back to the
    /// concrete type avoids a struct-cycle compilation error.
    server_ptr: ?*anyopaque = null,
};

/// Global pointer used only by the SIGTERM handler. Set in main(), null otherwise.
var g_app: ?*App = null;

fn shutdownHandler(_: c_int) callconv(.c) void {
    std.log.info("hp-server: SIGTERM received, shutting down gracefully", .{});
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
    const is_authed = is_authed_cookie or (is_v1 and has_apikey_header);
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
    if (std.mem.eql(u8, path, "/api/hosted/stats")) return apiHostedStats(app, res);
    if (std.mem.eql(u8, path, "/api/hosted/list")) return apiHostedList(app, res);
    if (std.mem.eql(u8, path, "/api/hosted/refresh")) return apiHostedRefresh(app, req, res);
    if (std.mem.eql(u8, path, "/api/ai/scrub")) return apiAiScrub(app, req, res);
    if (std.mem.eql(u8, path, "/api/audit")) return apiAudit(app, res);
    if (std.mem.eql(u8, path, "/api/tunnel/health")) return apiTunnelHealth(app, res);
    if (std.mem.eql(u8, path, "/api/geoblock")) return apiGeoblockGet(app, res);
    if (std.mem.eql(u8, path, "/api/geoblock/update")) return apiGeoblockUpdate(app, req, res);

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
    if (std.mem.eql(u8, path, "/projects")) {
        res.content_type = .HTML;
        res.body = @embedFile("templates/app-projects.html");
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
    res.status = 404;
    try res.json(.{ .ok = false, .err = "unknown_endpoint" }, .{});
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
    app.projects.delete(id) catch |err| {
        const code: []const u8 = switch (err) {
            error.NotFound => "not_found",
            else => "delete_failed",
        };
        res.status = 400;
        try res.json(.{ .ok = false, .err = code }, .{});
        return;
    };
    audit.append(.{
        .timestamp = std.time.timestamp(),
        .actor = actor,
        .action = "project_delete",
        .target = id,
    });
    try res.json(.{ .ok = true }, .{});
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
    app.supervisor.stop(id) catch |err| {
        const code: []const u8 = switch (err) {
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
    app.supervisor.restart(id) catch {
        res.status = 500;
        try res.json(.{ .ok = false, .err = "restart_failed" }, .{});
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
    try res.json(.{
        .ok = true,
        .state = @tagName(s.state),
        .pid = if (s.pid) |p| @as(i64, @intCast(p)) else null,
        .started_at = s.started_at,
        .crash_count = s.crash_count,
        .last_exit = s.last_exit,
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
