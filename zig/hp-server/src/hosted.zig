//! Static-site hosting at *.rofihosted.space.
//!
//! Layout on disk:
//!   ~/hosted/sites/<subdomain>/
//!     releases/<timestamp>/    <- one folder per deploy (rsync'd from laptop)
//!     current -> releases/<ts> <- symlink updated atomically by deploy script
//!
//! Serving rules:
//!   - <sub>.rofihosted.space/<path> -> ~/hosted/sites/<sub>/current/<path>
//!   - If <path> is "/", serve "/index.html"
//!   - If file not found AND site has spa.flag in current/, fall back to /index.html
//!   - 404 if subdomain unknown or current symlink missing
//!
//! Path safety:
//!   - Subdomain must pass pathsafe.validateSubdomain (only [a-z0-9-])
//!   - Request path must pass pathsafe.validateRequestPath (no '..', no NUL)
//!   - Resolved file must stay within the site root after realpath()
//!
//! MIME:
//!   - Common web extensions handled inline. Unknown -> application/octet-stream.
//!
//! In-memory cache:
//!   - Per-site: a small LRU of (path -> body) for files <= 256KB.
//!   - Bumped on deploy via `bumpSite()` (called when deploy endpoint runs, or
//!     periodically by the inotify-style mtime watcher).
//!   - For now we just check the symlink mtime and invalidate when it changes.
const std = @import("std");
const httpz = @import("httpz");
const pathsafe = @import("pathsafe.zig");
const paths = @import("paths.zig");

const HOSTED_REL = "hosted/sites";
var root_buf: [std.fs.max_path_bytes]u8 = undefined;
var root_slice: ?[]const u8 = null;

/// Absolute root of the hosted-sites tree, resolved from HOME once and cached.
/// Benign cross-thread race (identical bytes), same as dbcache.dbPath().
pub fn hostedRoot() []const u8 {
    if (root_slice) |p| return p;
    const p = paths.join(&root_buf, HOSTED_REL);
    root_slice = p;
    return p;
}
const APEX_DOMAIN = "rofihosted.space";

const CACHE_BODY_MAX: usize = 256 * 1024; // 256 KB per file
const CACHE_PER_SITE_MAX: usize = 32; // 32 files per site
const SUFFIX_INDEX = "/index.html";

pub const Manager = struct {
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    sites: std.StringHashMap(*Site),

    pub fn init(allocator: std.mem.Allocator) !*Manager {
        const m = try allocator.create(Manager);
        m.* = .{
            .mutex = .{},
            .allocator = allocator,
            .sites = std.StringHashMap(*Site).init(allocator),
        };
        return m;
    }

    /// Look up the site by subdomain label. Returns null if no current/ exists.
    pub fn get(self: *Manager, subdomain: []const u8) ?*Site {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.sites.get(subdomain)) |s| return s;

        // Try to lazily register: only if ~/hosted/sites/<sub>/current exists.
        const current_path = std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/current",
            .{ hostedRoot(), subdomain },
        ) catch return null;
        defer self.allocator.free(current_path);
        std.fs.accessAbsolute(current_path, .{}) catch return null;

        const owned_label = self.allocator.dupe(u8, subdomain) catch return null;
        const s = self.allocator.create(Site) catch {
            self.allocator.free(owned_label);
            return null;
        };
        s.* = Site.init(self.allocator, owned_label) catch {
            self.allocator.free(owned_label);
            self.allocator.destroy(s);
            return null;
        };
        self.sites.put(owned_label, s) catch {
            s.deinit();
            self.allocator.destroy(s);
            self.allocator.free(owned_label);
            return null;
        };
        return s;
    }

    /// Force-invalidate caches for one site (called after a deploy).
    pub fn bumpSite(self: *Manager, subdomain: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.sites.get(subdomain)) |s| s.invalidate();
    }

    /// Statistics across all sites.
    pub fn statsJson(self: *Manager, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out = std.ArrayList(u8).init(allocator);
        const w = out.writer();
        try w.writeAll("{\"ok\":true,\"sites\":[");
        var it = self.sites.iterator();
        var first = true;
        while (it.next()) |kv| {
            if (!first) try w.writeByte(',');
            first = false;
            const s = kv.value_ptr.*;
            const stat = s.stats();
            try w.print(
                \\{{"subdomain":"{s}","cache_entries":{d},"cache_bytes":{d},"hits":{d},"misses":{d},"deploys_seen":{d}}}
            ,
                .{ s.subdomain, stat.cache_entries, stat.cache_bytes, stat.hits, stat.misses, stat.deploys_seen },
            );
        }
        try w.writeAll("]}");
        return out.toOwnedSlice();
    }
};

pub const Site = struct {
    allocator: std.mem.Allocator,
    subdomain: []const u8, // owned
    /// Absolute path of ~/hosted/sites/<sub>
    site_root: []const u8, // owned
    mutex: std.Thread.Mutex,
    /// Last seen mtime of the current symlink. If it changes, blow the cache.
    last_current_mtime_ns: i128 = 0,
    /// Cached canonical path of where current/ points. Invalidated on mtime change.
    canonical_root: ?[]u8 = null,
    cache: std.StringHashMap(CacheEntry),
    cache_bytes: usize = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    deploys_seen: u64 = 0,
    /// Cached SPA flag (presence of spa.flag in current/).
    spa_mode: bool = false,

    fn init(allocator: std.mem.Allocator, subdomain: []const u8) !Site {
        const site_root = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ hostedRoot(), subdomain });
        return .{
            .allocator = allocator,
            .subdomain = subdomain,
            .site_root = site_root,
            .mutex = .{},
            .cache = std.StringHashMap(CacheEntry).init(allocator),
        };
    }

    fn deinit(self: *Site) void {
        self.invalidate();
        self.cache.deinit();
        self.allocator.free(self.site_root);
        // subdomain is freed by manager
    }

    fn invalidate(self: *Site) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.invalidateLocked();
    }

    fn invalidateLocked(self: *Site) void {
        var it = self.cache.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.body);
        }
        self.cache.clearAndFree();
        self.cache_bytes = 0;
        if (self.canonical_root) |old| self.allocator.free(old);
        self.canonical_root = null;
        self.deploys_seen += 1;
    }

    pub const Stats = struct {
        cache_entries: usize,
        cache_bytes: usize,
        hits: u64,
        misses: u64,
        deploys_seen: u64,
    };

    pub fn stats(self: *Site) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .cache_entries = self.cache.count(),
            .cache_bytes = self.cache_bytes,
            .hits = self.hits,
            .misses = self.misses,
            .deploys_seen = self.deploys_seen,
        };
    }

    /// Refresh canonical_root if current symlink mtime changed. Caller holds mutex.
    fn refreshCurrentLocked(self: *Site) !void {
        const current_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/current",
            .{self.site_root},
        );
        defer self.allocator.free(current_path);

        // Use lstat-equivalent on the symlink itself by opening with no_follow.
        // std.fs has no direct lstat, so we statFile via openFile follows links.
        // Instead, we just realpath and compare against cached canonical_root.
        var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
        const resolved = std.fs.realpath(current_path, &resolved_buf) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return error.NoCurrent,
            else => return err,
        };

        // If unchanged, return
        if (self.canonical_root) |cached| {
            if (std.mem.eql(u8, cached, resolved)) return;
        }

        // Changed: invalidate cache, update canonical_root, refresh spa_mode.
        self.invalidateLocked();
        self.canonical_root = try self.allocator.dupe(u8, resolved);

        // SPA detection: presence of <root>/spa.flag enables SPA fallback.
        const spa_flag = try std.fmt.allocPrint(self.allocator, "{s}/spa.flag", .{resolved});
        defer self.allocator.free(spa_flag);
        self.spa_mode = blk: {
            std.fs.accessAbsolute(spa_flag, .{}) catch break :blk false;
            break :blk true;
        };
    }

    /// Read a file under current/, with caching, SPA fallback, MIME guessing.
    /// Returns one of: a body slice + content_type + status, or NotFound.
    pub fn serve(
        self: *Site,
        arena: std.mem.Allocator,
        req_path: []const u8,
    ) !ServeResult {
        try pathsafe.validateRequestPath(req_path);

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.refreshCurrentLocked();
        const root = self.canonical_root orelse return error.NoCurrent;

        const lookup_path = if (req_path.len == 1 and req_path[0] == '/')
            SUFFIX_INDEX
        else
            req_path;

        // Check cache first
        if (self.cache.get(lookup_path)) |entry| {
            self.hits += 1;
            return .{
                .body = try arena.dupe(u8, entry.body),
                .content_type = entry.content_type,
                .status = 200,
            };
        }
        self.misses += 1;

        // Resolve safely under canonical root
        const resolved = pathsafe.resolveWithinRoot(arena, root, lookup_path) catch |err| switch (err) {
            error.EscapesRoot, error.DotDotSegment, error.NullByte, error.ControlChar => {
                return .{ .body = "forbidden\n", .content_type = "text/plain", .status = 403 };
            },
            error.FileNotFound, error.Unreadable => return self.serveNotFound(arena),
            else => return err,
        };

        const file = std.fs.openFileAbsolute(resolved, .{}) catch return self.serveNotFound(arena);
        defer file.close();

        const stat = file.stat() catch return self.serveNotFound(arena);
        if (stat.kind == .directory) {
            // Directory hit: try /index.html under it
            const idx_path = try std.fmt.allocPrint(arena, "{s}/index.html", .{resolved});
            const idx_file = std.fs.openFileAbsolute(idx_path, .{}) catch return self.serveNotFound(arena);
            defer idx_file.close();
            const idx_stat = idx_file.stat() catch return self.serveNotFound(arena);
            const body = try idx_file.readToEndAlloc(arena, 16 * 1024 * 1024);
            return .{
                .body = body,
                .content_type = "text/html; charset=utf-8",
                .status = 200,
                .last_modified_ns = idx_stat.mtime,
            };
        }

        const body = try file.readToEndAlloc(arena, 16 * 1024 * 1024);
        const ct = mimeFromPath(resolved);
        const result = ServeResult{
            .body = body,
            .content_type = ct,
            .status = 200,
            .last_modified_ns = stat.mtime,
        };

        // Cache if small enough and we have headroom
        if (body.len <= CACHE_BODY_MAX and self.cache.count() < CACHE_PER_SITE_MAX) {
            const owned_key = self.allocator.dupe(u8, lookup_path) catch return result;
            const owned_body = self.allocator.dupe(u8, body) catch {
                self.allocator.free(owned_key);
                return result;
            };
            self.cache.put(owned_key, .{
                .body = owned_body,
                .content_type = ct,
            }) catch {
                self.allocator.free(owned_key);
                self.allocator.free(owned_body);
                return result;
            };
            self.cache_bytes += owned_body.len;
        }
        return result;
    }

    fn serveNotFound(self: *Site, arena: std.mem.Allocator) !ServeResult {
        // SPA fallback: serve /index.html for any 404 if spa.flag is present.
        if (self.spa_mode) {
            const root = self.canonical_root orelse return error.NoCurrent;
            const idx_path = try std.fmt.allocPrint(arena, "{s}/index.html", .{root});
            const idx_file = std.fs.openFileAbsolute(idx_path, .{}) catch {
                return .{ .body = "not found\n", .content_type = "text/plain", .status = 404 };
            };
            defer idx_file.close();
            const body = idx_file.readToEndAlloc(arena, 16 * 1024 * 1024) catch {
                return .{ .body = "not found\n", .content_type = "text/plain", .status = 404 };
            };
            return .{ .body = body, .content_type = "text/html; charset=utf-8", .status = 200 };
        }
        return .{ .body = "not found\n", .content_type = "text/plain", .status = 404 };
    }
};

pub const CacheEntry = struct {
    body: []u8,
    content_type: []const u8, // static literal, not owned
};

pub const ServeResult = struct {
    body: []const u8,
    content_type: []const u8,
    status: u16,
    last_modified_ns: i128 = 0,
};

/// Subdomains reserved by the system. Even if ~/hosted/sites/<x>/current
/// exists, these will never be served as static sites.
const RESERVED_SUBDOMAINS = [_][]const u8{
    "app", "www", "dashboard", "status", "api", "files", "admin",
};

/// Extract subdomain from a host like "blog.rofihosted.space". Returns null
/// if host doesn't match the apex, has no subdomain, or is a reserved name.
pub fn extractSubdomain(host: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, host, "." ++ APEX_DOMAIN)) return null;
    const sub = host[0 .. host.len - (APEX_DOMAIN.len + 1)];
    if (sub.len == 0) return null;
    pathsafe.validateSubdomain(sub) catch return null;
    for (RESERVED_SUBDOMAINS) |reserved| {
        if (std.mem.eql(u8, sub, reserved)) return null;
    }
    return sub;
}

fn mimeFromPath(p: []const u8) []const u8 {
    const ext_idx = std.mem.lastIndexOfScalar(u8, p, '.') orelse return "application/octet-stream";
    const ext = p[ext_idx..];
    if (std.mem.eql(u8, ext, ".html")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext, ".htm")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext, ".css")) return "text/css; charset=utf-8";
    if (std.mem.eql(u8, ext, ".js")) return "application/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".mjs")) return "application/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".json")) return "application/json; charset=utf-8";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".jpg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".webp")) return "image/webp";
    if (std.mem.eql(u8, ext, ".gif")) return "image/gif";
    if (std.mem.eql(u8, ext, ".ico")) return "image/x-icon";
    if (std.mem.eql(u8, ext, ".woff2")) return "font/woff2";
    if (std.mem.eql(u8, ext, ".woff")) return "font/woff";
    if (std.mem.eql(u8, ext, ".ttf")) return "font/ttf";
    if (std.mem.eql(u8, ext, ".txt")) return "text/plain; charset=utf-8";
    if (std.mem.eql(u8, ext, ".md")) return "text/markdown; charset=utf-8";
    if (std.mem.eql(u8, ext, ".xml")) return "application/xml; charset=utf-8";
    if (std.mem.eql(u8, ext, ".pdf")) return "application/pdf";
    if (std.mem.eql(u8, ext, ".wasm")) return "application/wasm";
    if (std.mem.eql(u8, ext, ".map")) return "application/json; charset=utf-8";
    return "application/octet-stream";
}

/// httpz handler: serve a request from a hosted site. Returns true if served,
/// false if the subdomain isn't a hosted site (caller should fall back to other routing).
pub fn tryServe(
    mgr: *Manager,
    host: []const u8,
    req_path: []const u8,
    res: *httpz.Response,
) !bool {
    const sub = extractSubdomain(host) orelse return false;
    const site = mgr.get(sub) orelse return false;
    const result = site.serve(res.arena, req_path) catch |err| switch (err) {
        error.NoCurrent => {
            res.status = 503;
            res.content_type = .TEXT;
            res.body = "site not deployed yet\n";
            return true;
        },
        error.EmptyPath, error.PathTooLong, error.NullByte, error.ControlChar, error.DotDotSegment, error.AbsolutePath, error.BackslashNotAllowed => {
            res.status = 400;
            res.content_type = .TEXT;
            res.body = "bad path\n";
            return true;
        },
        else => return err,
    };
    res.status = result.status;
    res.header("Content-Type", result.content_type);
    res.header("Cache-Control", "public, max-age=60");
    res.body = result.body;
    return true;
}

test "extractSubdomain happy path" {
    try std.testing.expectEqualStrings("blog", extractSubdomain("blog.rofihosted.space").?);
    try std.testing.expectEqualStrings("my-app", extractSubdomain("my-app.rofihosted.space").?);
}

test "extractSubdomain rejects invalid" {
    try std.testing.expect(extractSubdomain("rofihosted.space") == null);
    try std.testing.expect(extractSubdomain("evil.com") == null);
    try std.testing.expect(extractSubdomain("FOO.rofihosted.space") == null);
    try std.testing.expect(extractSubdomain("a.b.rofihosted.space") == null);
}

test "extractSubdomain blocks reserved" {
    try std.testing.expect(extractSubdomain("app.rofihosted.space") == null);
    try std.testing.expect(extractSubdomain("www.rofihosted.space") == null);
    try std.testing.expect(extractSubdomain("api.rofihosted.space") == null);
    try std.testing.expect(extractSubdomain("dashboard.rofihosted.space") == null);
    try std.testing.expect(extractSubdomain("status.rofihosted.space") == null);
    try std.testing.expect(extractSubdomain("files.rofihosted.space") == null);
}

test "mime guessing" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", mimeFromPath("/index.html"));
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", mimeFromPath("/app.js"));
    try std.testing.expectEqualStrings("image/png", mimeFromPath("/logo.png"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeFromPath("/blob"));
}
