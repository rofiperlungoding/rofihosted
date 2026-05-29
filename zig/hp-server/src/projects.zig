//! Project registry. Each project is a deployable unit with:
//!   - subdomain (claimed exclusively by this project)
//!   - source (git repo URL or local path)
//!   - runtime (static / node / python / bun / generic)
//!   - install/build/start commands
//!   - allocated port (for backend types)
//!   - encrypted secrets bag (env vars surfaced at process spawn time)
//!   - lifecycle state (created / building / running / stopped / failed)
//!
//! Storage:
//!   ~/.hp-server-projects.jsonl  - one record per line, append + atomic rewrite on update
//!   ~/data/projects/<id>/        - working tree, secrets, logs, build artifacts
//!     repo/                      - git clone or unpacked archive
//!     releases/<UTC ts>/         - one folder per successful build
//!     current -> releases/<ts>   - atomic symlink to active build
//!     secrets.bin                - AES-256-GCM encrypted env vars (mode 600)
//!     logs/{build,runtime}.log
//!
//! Subdomain claims are validated on create/update: each subdomain can map to
//! exactly one project. The hosted.zig router checks the project registry
//! first, falling back to the legacy ~/hosted/sites/<sub>/current/ path.

const std = @import("std");
const pathsafe = @import("pathsafe.zig");

pub const PROJECTS_PATH = "/data/data/com.termux/files/home/.hp-server-projects.jsonl";
pub const PROJECTS_DIR = "/data/data/com.termux/files/home/data/projects";

pub const Runtime = enum {
    static,
    node,
    python,
    bun,
    generic, // operator-supplied start_cmd, no runtime-specific magic

    pub fn fromString(s: []const u8) ?Runtime {
        if (std.mem.eql(u8, s, "static")) return .static;
        if (std.mem.eql(u8, s, "node")) return .node;
        if (std.mem.eql(u8, s, "python")) return .python;
        if (std.mem.eql(u8, s, "bun")) return .bun;
        if (std.mem.eql(u8, s, "generic")) return .generic;
        return null;
    }
    pub fn toString(self: Runtime) []const u8 {
        return @tagName(self);
    }
    pub fn isStatic(self: Runtime) bool {
        return self == .static;
    }
};

pub const Status = enum {
    created,
    cloning,
    building,
    running,
    stopped,
    failed,

    pub fn toString(self: Status) []const u8 {
        return @tagName(self);
    }
    pub fn fromString(s: []const u8) ?Status {
        if (std.mem.eql(u8, s, "created")) return .created;
        if (std.mem.eql(u8, s, "cloning")) return .cloning;
        if (std.mem.eql(u8, s, "building")) return .building;
        if (std.mem.eql(u8, s, "running")) return .running;
        if (std.mem.eql(u8, s, "stopped")) return .stopped;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        return null;
    }
};

pub const Project = struct {
    id: []const u8, // 16 hex chars, immutable
    name: []const u8, // human-friendly, mutable
    subdomain: []const u8, // [a-z0-9-], 1-63 chars
    repo_url: []const u8, // empty if local-only
    branch: []const u8, // default "main"
    runtime: Runtime,
    install_cmd: []const u8,
    build_cmd: []const u8,
    start_cmd: []const u8, // ignored for static
    publish_dir: []const u8, // sub-path of repo where static output lives ("" = repo root)
    webhook_secret: []const u8, // hex string used to HMAC-verify GitHub push webhooks
    port: u16, // 0 for static
    status: Status,
    /// Who owns this project. Either a user id (`u_<hex16>`) or empty
    /// string for legacy projects created before multi-tenancy. Tenants
    /// can only see + manage projects they own; admins see everything.
    owner_id: []const u8 = "",
    /// Maximum resident memory (MB) allowed for this project's process. The
    /// supervisor polls /proc/<pid>/status and SIGTERMs the child if it
    /// exceeds this for two consecutive samples. 0 = no limit.
    rss_limit_mb: u32 = 0,
    created_at: i64,
    updated_at: i64,
    last_deploy_at: i64,
};

pub const Error = error{
    InvalidSubdomain,
    InvalidName,
    InvalidRuntime,
    SubdomainTaken,
    PortExhausted,
    NotFound,
    InvalidJson,
    OutOfMemory,
};

pub const PORT_RANGE_LO: u16 = 3000;
pub const PORT_RANGE_HI: u16 = 3999;

pub const Manager = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    projects: std.ArrayList(Project),
    arena_state: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) !*Manager {
        const m = try allocator.create(Manager);
        m.* = .{
            .allocator = allocator,
            .mutex = .{},
            .projects = std.ArrayList(Project).init(allocator),
            .arena_state = std.heap.ArenaAllocator.init(allocator),
        };
        std.fs.makeDirAbsolute(PROJECTS_DIR) catch {};
        try m.loadFromDisk();
        return m;
    }

    pub fn deinit(self: *Manager) void {
        self.projects.deinit();
        self.arena_state.deinit();
    }

    fn loadFromDisk(self: *Manager) !void {
        const file = std.fs.openFileAbsolute(PROJECTS_PATH, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();
        const data = try file.readToEndAlloc(self.allocator, 4 * 1024 * 1024);
        defer self.allocator.free(data);

        var lines = std.mem.tokenizeScalar(u8, data, '\n');
        const arena = self.arena_state.allocator();
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const Wire = struct {
                id: []const u8,
                name: []const u8,
                subdomain: []const u8,
                repo_url: []const u8 = "",
                branch: []const u8 = "main",
                runtime: []const u8 = "static",
                install_cmd: []const u8 = "",
                build_cmd: []const u8 = "",
                start_cmd: []const u8 = "",
                publish_dir: []const u8 = "",
                webhook_secret: []const u8 = "",
                port: u16 = 0,
                status: []const u8 = "created",
                owner_id: []const u8 = "",
                created_at: i64 = 0,
                updated_at: i64 = 0,
                last_deploy_at: i64 = 0,
                rss_limit_mb: u32 = 0,
                deleted: bool = false,
            };
            const parsed = std.json.parseFromSlice(Wire, self.allocator, line, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            }) catch continue;
            defer parsed.deinit();
            const w = parsed.value;
            if (w.deleted) continue;
            const rt = Runtime.fromString(w.runtime) orelse Runtime.generic;
            const st = Status.fromString(w.status) orelse Status.created;
            try self.projects.append(.{
                .id = try arena.dupe(u8, w.id),
                .name = try arena.dupe(u8, w.name),
                .subdomain = try arena.dupe(u8, w.subdomain),
                .repo_url = try arena.dupe(u8, w.repo_url),
                .branch = try arena.dupe(u8, w.branch),
                .runtime = rt,
                .install_cmd = try arena.dupe(u8, w.install_cmd),
                .build_cmd = try arena.dupe(u8, w.build_cmd),
                .start_cmd = try arena.dupe(u8, w.start_cmd),
                .publish_dir = try arena.dupe(u8, w.publish_dir),
                .webhook_secret = try arena.dupe(u8, w.webhook_secret),
                .port = w.port,
                .status = st,
                .owner_id = try arena.dupe(u8, w.owner_id),
                .rss_limit_mb = w.rss_limit_mb,
                .created_at = w.created_at,
                .updated_at = w.updated_at,
                .last_deploy_at = w.last_deploy_at,
            });
        }
    }

    fn rewriteToDisk(self: *Manager) !void {
        const tmp = PROJECTS_PATH ++ ".tmp";
        var f = try std.fs.createFileAbsolute(tmp, .{ .truncate = true, .mode = 0o600 });
        defer f.close();
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        for (self.projects.items) |p| {
            buf.clearRetainingCapacity();
            try writeProject(buf.writer(), p);
            try buf.append('\n');
            try f.writeAll(buf.items);
        }
        try std.fs.renameAbsolute(tmp, PROJECTS_PATH);
    }

    /// Reserve a free port in [PORT_RANGE_LO, PORT_RANGE_HI] not used by any
    /// non-static project. Caller holds mutex.
    fn pickPortLocked(self: *Manager) !u16 {
        var taken = std.AutoHashMap(u16, void).init(self.allocator);
        defer taken.deinit();
        for (self.projects.items) |p| {
            if (p.port != 0) try taken.put(p.port, {});
        }
        var port: u16 = PORT_RANGE_LO;
        while (port <= PORT_RANGE_HI) : (port += 1) {
            if (!taken.contains(port)) return port;
        }
        return error.PortExhausted;
    }

    pub const CreateInput = struct {
        name: []const u8,
        subdomain: []const u8,
        repo_url: []const u8 = "",
        branch: []const u8 = "main",
        runtime: Runtime,
        install_cmd: []const u8 = "",
        build_cmd: []const u8 = "",
        start_cmd: []const u8 = "",
        publish_dir: []const u8 = "",
        rss_limit_mb: u32 = 0,
        owner_id: []const u8 = "",
    };

    pub fn create(self: *Manager, input: CreateInput) !Project {
        // Validation
        if (input.name.len == 0 or input.name.len > 64) return error.InvalidName;
        try pathsafe.validateSubdomain(input.subdomain);

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.projects.items) |p| {
            if (std.mem.eql(u8, p.subdomain, input.subdomain)) return error.SubdomainTaken;
        }

        const port: u16 = if (input.runtime.isStatic()) 0 else try self.pickPortLocked();

        var id_bytes: [8]u8 = undefined;
        std.crypto.random.bytes(&id_bytes);
        var id_hex: [16]u8 = undefined;
        const cs = "0123456789abcdef";
        for (id_bytes, 0..) |b, i| {
            id_hex[i * 2] = cs[b >> 4];
            id_hex[i * 2 + 1] = cs[b & 0xf];
        }

        // Generate a per-project webhook secret (random, hex). The operator copies
        // this into their GitHub repo settings as the secret for the push webhook.
        var secret_bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&secret_bytes);
        var secret_hex: [64]u8 = undefined;
        for (secret_bytes, 0..) |b, i| {
            secret_hex[i * 2] = cs[b >> 4];
            secret_hex[i * 2 + 1] = cs[b & 0xf];
        }

        const arena = self.arena_state.allocator();
        const now = std.time.timestamp();
        const project = Project{
            .id = try arena.dupe(u8, &id_hex),
            .name = try arena.dupe(u8, input.name),
            .subdomain = try arena.dupe(u8, input.subdomain),
            .repo_url = try arena.dupe(u8, input.repo_url),
            .branch = try arena.dupe(u8, input.branch),
            .runtime = input.runtime,
            .install_cmd = try arena.dupe(u8, input.install_cmd),
            .build_cmd = try arena.dupe(u8, input.build_cmd),
            .start_cmd = try arena.dupe(u8, input.start_cmd),
            .publish_dir = try arena.dupe(u8, input.publish_dir),
            .webhook_secret = try arena.dupe(u8, &secret_hex),
            .port = port,
            .status = .created,
            .owner_id = try arena.dupe(u8, input.owner_id),
            .rss_limit_mb = input.rss_limit_mb,
            .created_at = now,
            .updated_at = now,
            .last_deploy_at = 0,
        };
        try self.projects.append(project);
        try self.rewriteToDisk();

        // Pre-create the project working dir so secrets vault has a place to live.
        const proj_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ PROJECTS_DIR, project.id });
        defer self.allocator.free(proj_dir);
        std.fs.makeDirAbsolute(proj_dir) catch {};
        const logs_dir = try std.fmt.allocPrint(self.allocator, "{s}/logs", .{proj_dir});
        defer self.allocator.free(logs_dir);
        std.fs.makeDirAbsolute(logs_dir) catch {};

        return project;
    }

    pub const UpdateInput = struct {
        name: ?[]const u8 = null,
        repo_url: ?[]const u8 = null,
        branch: ?[]const u8 = null,
        install_cmd: ?[]const u8 = null,
        build_cmd: ?[]const u8 = null,
        start_cmd: ?[]const u8 = null,
        publish_dir: ?[]const u8 = null,
        status: ?Status = null,
        last_deploy_at: ?i64 = null,
        rss_limit_mb: ?u32 = null,
    };

    pub fn update(self: *Manager, id: []const u8, input: UpdateInput) !Project {
        self.mutex.lock();
        defer self.mutex.unlock();
        const arena = self.arena_state.allocator();
        for (self.projects.items) |*p| {
            if (std.mem.eql(u8, p.id, id)) {
                if (input.name) |v| {
                    if (v.len == 0 or v.len > 64) return error.InvalidName;
                    p.name = try arena.dupe(u8, v);
                }
                if (input.repo_url) |v| p.repo_url = try arena.dupe(u8, v);
                if (input.branch) |v| p.branch = try arena.dupe(u8, v);
                if (input.install_cmd) |v| p.install_cmd = try arena.dupe(u8, v);
                if (input.build_cmd) |v| p.build_cmd = try arena.dupe(u8, v);
                if (input.start_cmd) |v| p.start_cmd = try arena.dupe(u8, v);
                if (input.publish_dir) |v| p.publish_dir = try arena.dupe(u8, v);
                if (input.status) |v| p.status = v;
                if (input.last_deploy_at) |v| p.last_deploy_at = v;
                if (input.rss_limit_mb) |v| p.rss_limit_mb = v;
                p.updated_at = std.time.timestamp();
                try self.rewriteToDisk();
                return p.*;
            }
        }
        return error.NotFound;
    }

    pub fn delete(self: *Manager, id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.projects.items, 0..) |p, i| {
            if (std.mem.eql(u8, p.id, id)) {
                _ = self.projects.orderedRemove(i);
                try self.rewriteToDisk();
                return;
            }
        }
        return error.NotFound;
    }

    pub fn getById(self: *Manager, id: []const u8) ?Project {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.projects.items) |p| {
            if (std.mem.eql(u8, p.id, id)) return p;
        }
        return null;
    }

    pub fn getBySubdomain(self: *Manager, subdomain: []const u8) ?Project {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.projects.items) |p| {
            if (std.mem.eql(u8, p.subdomain, subdomain)) return p;
        }
        return null;
    }

    pub fn listJson(self: *Manager, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out = std.ArrayList(u8).init(allocator);
        const w = out.writer();
        try w.writeAll("{\"ok\":true,\"projects\":[");
        for (self.projects.items, 0..) |p, i| {
            if (i > 0) try w.writeByte(',');
            try writeProject(w, p);
        }
        try w.writeAll("]}");
        return out.toOwnedSlice();
    }

    /// Snapshot the current project list for callers that need to filter
    /// or process them in code rather than dumping JSON.
    pub fn listSnapshot(self: *Manager, allocator: std.mem.Allocator) ![]Project {
        self.mutex.lock();
        defer self.mutex.unlock();
        return allocator.dupe(Project, self.projects.items);
    }

    /// Reassign ownership of a project. Used by admins for transfers and by
    /// the migration flow to claim legacy (owner_id == "") projects.
    pub fn setOwner(self: *Manager, id: []const u8, new_owner_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const arena = self.arena_state.allocator();
        for (self.projects.items) |*p| {
            if (std.mem.eql(u8, p.id, id)) {
                p.owner_id = try arena.dupe(u8, new_owner_id);
                p.updated_at = std.time.timestamp();
                try self.rewriteToDisk();
                return;
            }
        }
        return error.NotFound;
    }

    pub fn workingDir(allocator: std.mem.Allocator, id: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ PROJECTS_DIR, id });
    }
};

/// Public alias of writeProject for callers in main.zig that need to
/// emit a single project's JSON body (e.g. filtered list responses).
pub fn writeProjectJson(w: anytype, p: Project) !void {
    return writeProject(w, p);
}

fn writeProject(w: anytype, p: Project) !void {
    try w.writeAll("{\"id\":\"");
    try w.writeAll(p.id);
    try w.writeAll("\",\"name\":\"");
    try writeJsonStr(w, p.name);
    try w.writeAll(",\"subdomain\":\"");
    try writeJsonStr(w, p.subdomain);
    try w.writeAll(",\"repo_url\":\"");
    try writeJsonStr(w, p.repo_url);
    try w.writeAll(",\"branch\":\"");
    try writeJsonStr(w, p.branch);
    try w.print(
        ",\"runtime\":\"{s}\",\"install_cmd\":\"",
        .{p.runtime.toString()},
    );
    try writeJsonStr(w, p.install_cmd);
    try w.writeAll(",\"build_cmd\":\"");
    try writeJsonStr(w, p.build_cmd);
    try w.writeAll(",\"start_cmd\":\"");
    try writeJsonStr(w, p.start_cmd);
    try w.writeAll(",\"publish_dir\":\"");
    try writeJsonStr(w, p.publish_dir);
    try w.writeAll(",\"webhook_secret\":\"");
    try writeJsonStr(w, p.webhook_secret);
    try w.writeAll(",\"owner_id\":\"");
    try writeJsonStr(w, p.owner_id);
    try w.print(
        ",\"port\":{d},\"status\":\"{s}\",\"created_at\":{d},\"updated_at\":{d},\"last_deploy_at\":{d},\"rss_limit_mb\":{d}}}",
        .{ p.port, p.status.toString(), p.created_at, p.updated_at, p.last_deploy_at, p.rss_limit_mb },
    );
}

fn writeJsonStr(w: anytype, s: []const u8) !void {
    // Caller has emitted opening `"`. We emit content and closing `"`.
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

test "Runtime roundtrip" {
    try std.testing.expect(Runtime.fromString("static") == .static);
    try std.testing.expect(Runtime.fromString("node") == .node);
    try std.testing.expect(Runtime.fromString("nope") == null);
    try std.testing.expectEqualStrings("python", Runtime.python.toString());
}
