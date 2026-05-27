//! Project deploy orchestrator. Given a project, this module:
//!   1. clones the repo (or pulls latest if already cloned) into ~/data/projects/<id>/repo/
//!   2. runs install_cmd and build_cmd in sequence with secrets injected as env vars
//!   3. for static runtimes: copies <repo>/<publish_dir>/. into a fresh
//!      releases/<UTC ts>/ folder and atomic-swaps `current` symlink
//!   4. captures stdout+stderr of every step into ~/data/projects/<id>/logs/build.log
//!   5. updates project status (cloning -> building -> running / failed)
//!
//! All runs in a detached background thread so the API call returns instantly.
//! Concurrency: per-project mutex (only one deploy in flight per project) via
//! the build_lock map in the orchestrator.
//!
//! Subprocess pattern: same as everything else in this codebase. We shell out
//! to `git`, then to `sh -c '<cmd>'` for install/build commands.
const std = @import("std");
const projects = @import("projects.zig");
const projsecrets = @import("projsecrets.zig");

const HOME = "/data/data/com.termux/files/home";

pub const StepKind = enum {
    clone,
    install,
    build,
    publish,

    pub fn label(self: StepKind) []const u8 {
        return switch (self) {
            .clone => "clone",
            .install => "install",
            .build => "build",
            .publish => "publish",
        };
    }
};

pub const Orchestrator = struct {
    allocator: std.mem.Allocator,
    pepper: []const u8,
    projects_mgr: *projects.Manager,
    /// Map project_id -> in-flight flag. Prevents concurrent deploys of the same
    /// project (would corrupt the repo dir).
    in_flight: std.StringHashMap(void),
    in_flight_mutex: std.Thread.Mutex,

    pub fn init(
        allocator: std.mem.Allocator,
        pepper: []const u8,
        projects_mgr: *projects.Manager,
    ) !*Orchestrator {
        const o = try allocator.create(Orchestrator);
        o.* = .{
            .allocator = allocator,
            .pepper = pepper,
            .projects_mgr = projects_mgr,
            .in_flight = std.StringHashMap(void).init(allocator),
            .in_flight_mutex = .{},
        };
        return o;
    }

    fn tryClaim(self: *Orchestrator, project_id: []const u8) !bool {
        self.in_flight_mutex.lock();
        defer self.in_flight_mutex.unlock();
        if (self.in_flight.contains(project_id)) return false;
        const owned = try self.allocator.dupe(u8, project_id);
        try self.in_flight.put(owned, {});
        return true;
    }

    fn release(self: *Orchestrator, project_id: []const u8) void {
        self.in_flight_mutex.lock();
        defer self.in_flight_mutex.unlock();
        if (self.in_flight.fetchRemove(project_id)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Spawn a detached deploy thread. Returns immediately. Returns
    /// error.AlreadyInFlight if a deploy is already running for this project.
    pub fn deployAsync(self: *Orchestrator, project_id: []const u8) !void {
        if (!try self.tryClaim(project_id)) return error.AlreadyInFlight;
        const owned_id = try self.allocator.dupe(u8, project_id);
        const t = std.Thread.spawn(.{}, deployThread, .{ self, owned_id }) catch |err| {
            self.release(owned_id);
            self.allocator.free(owned_id);
            return err;
        };
        t.detach();
    }
};

fn deployThread(orch: *Orchestrator, project_id: []u8) void {
    defer {
        orch.release(project_id);
        orch.allocator.free(project_id);
    }
    deploy(orch, project_id) catch |err| {
        std.log.warn("deploy failed for {s}: {}", .{ project_id, err });
        _ = orch.projects_mgr.update(project_id, .{ .status = .failed }) catch {};
    };
}

const DeployContext = struct {
    orch: *Orchestrator,
    project: projects.Project,
    log_file: std.fs.File,
    work_dir: []const u8, // ~/data/projects/<id>
    repo_dir: []const u8, // <work>/repo
    releases_dir: []const u8, // <work>/releases
    new_release_dir: []const u8, // <releases>/<UTC ts>
    env_pairs: ?[][]u8 = null, // KEY=VALUE strings from the secrets vault

    fn writeLog(self: *DeployContext, s: []const u8) void {
        self.log_file.writeAll(s) catch {};
    }
    fn logHeader(self: *DeployContext, kind: StepKind) void {
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "\n=== {s} === [{d}]\n", .{ kind.label(), std.time.timestamp() }) catch return;
        self.log_file.writeAll(s) catch {};
    }
    fn logFooter(self: *DeployContext, kind: StepKind, ok: bool, exit_code: i32) void {
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(
            &buf,
            "=== {s} {s} (exit={d}) ===\n",
            .{ kind.label(), if (ok) "OK" else "FAILED", exit_code },
        ) catch return;
        self.log_file.writeAll(s) catch {};
    }
};

fn deploy(orch: *Orchestrator, project_id: []const u8) !void {
    const project = orch.projects_mgr.getById(project_id) orelse return error.NotFound;

    // Ensure the projects parent dir exists. It might have been removed by
    // an operator script between server start and now.
    std.fs.makeDirAbsolute(projects.PROJECTS_DIR) catch {};

    const work_dir = try std.fmt.allocPrint(orch.allocator, "{s}/data/projects/{s}", .{ HOME, project_id });
    defer orch.allocator.free(work_dir);
    std.fs.makeDirAbsolute(work_dir) catch {};

    const repo_dir = try std.fmt.allocPrint(orch.allocator, "{s}/repo", .{work_dir});
    defer orch.allocator.free(repo_dir);

    const releases_dir = try std.fmt.allocPrint(orch.allocator, "{s}/releases", .{work_dir});
    defer orch.allocator.free(releases_dir);
    std.fs.makeDirAbsolute(releases_dir) catch {};

    const logs_dir = try std.fmt.allocPrint(orch.allocator, "{s}/logs", .{work_dir});
    defer orch.allocator.free(logs_dir);
    std.fs.makeDirAbsolute(logs_dir) catch {};

    const log_path = try std.fmt.allocPrint(orch.allocator, "{s}/build.log", .{logs_dir});
    defer orch.allocator.free(log_path);
    var log_file = try std.fs.createFileAbsolute(log_path, .{ .truncate = true, .mode = 0o600 });
    defer log_file.close();

    var ts_buf: [32]u8 = undefined;
    const ts_slice = try std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()});
    const new_release_dir = try std.fmt.allocPrint(orch.allocator, "{s}/{s}", .{ releases_dir, ts_slice });
    defer orch.allocator.free(new_release_dir);

    // Decrypt and prepare env pairs once. We free at the end.
    const empty_env: [][]u8 = &.{};
    const env_pairs: [][]u8 = projsecrets.Vault.loadAsEnvPairs(orch.allocator, orch.pepper, project_id) catch empty_env;
    defer {
        for (env_pairs) |p| orch.allocator.free(p);
        if (env_pairs.len > 0) orch.allocator.free(env_pairs);
    }

    var ctx = DeployContext{
        .orch = orch,
        .project = project,
        .log_file = log_file,
        .work_dir = work_dir,
        .repo_dir = repo_dir,
        .releases_dir = releases_dir,
        .new_release_dir = new_release_dir,
        .env_pairs = env_pairs,
    };

    {
        var hdr: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&hdr, "rofihosted deploy: project={s} repo={s} branch={s}\n", .{
            project.id, project.repo_url, project.branch,
        }) catch "rofihosted deploy\n";
        ctx.writeLog(s);
    }

    // ---- 1. clone or pull ----
    _ = try orch.projects_mgr.update(project_id, .{ .status = .cloning });
    if (project.repo_url.len > 0) {
        try runClone(&ctx);
    } else {
        ctx.logHeader(.clone);
        ctx.writeLog("(no repo_url, skipping clone; expecting source already present in repo/)\n");
        ctx.logFooter(.clone, true, 0);
    }

    // ---- 2. install ----
    _ = try orch.projects_mgr.update(project_id, .{ .status = .building });
    if (project.install_cmd.len > 0) {
        try runShellStep(&ctx, .install, project.install_cmd);
    } else {
        ctx.logHeader(.install);
        ctx.writeLog("(empty install_cmd, skipped)\n");
        ctx.logFooter(.install, true, 0);
    }

    // ---- 3. build ----
    if (project.build_cmd.len > 0) {
        try runShellStep(&ctx, .build, project.build_cmd);
    } else {
        ctx.logHeader(.build);
        ctx.writeLog("(empty build_cmd, skipped)\n");
        ctx.logFooter(.build, true, 0);
    }

    // ---- 4. publish (static only for now) ----
    if (project.runtime == .static) {
        try publishStatic(&ctx);
        _ = try orch.projects_mgr.update(project_id, .{
            .status = .running,
            .last_deploy_at = std.time.timestamp(),
        });
    } else {
        // Phase C will hook the supervisor here. For now, leave status as
        // "stopped" so the operator knows the build succeeded but nothing
        // is serving HTTP yet.
        _ = try orch.projects_mgr.update(project_id, .{
            .status = .stopped,
            .last_deploy_at = std.time.timestamp(),
        });
        ctx.logHeader(.publish);
        ctx.writeLog("(non-static runtime; supervisor wiring is Phase C, current build artifacts left in repo/)\n");
        ctx.logFooter(.publish, true, 0);
    }
}

fn runClone(ctx: *DeployContext) !void {
    ctx.logHeader(.clone);

    const repo_exists = blk: {
        var d = std.fs.openDirAbsolute(ctx.repo_dir, .{}) catch break :blk false;
        d.close();
        break :blk true;
    };

    var argv: []const []const u8 = undefined;
    if (repo_exists) {
        // git -C <repo> fetch + checkout + reset --hard origin/<branch>. Idempotent.
        // We use a small shell script so we can chain commands in one process.
        const cmd = try std.fmt.allocPrint(
            ctx.orch.allocator,
            "set -e; cd {s}; git fetch --depth=1 origin {s}; git reset --hard origin/{s}",
            .{ ctx.repo_dir, ctx.project.branch, ctx.project.branch },
        );
        defer ctx.orch.allocator.free(cmd);
        try runViaSh(ctx, .clone, cmd);
        return;
    }

    argv = &.{
        "git",                "clone",            "--depth=1",
        "--branch",           ctx.project.branch, "--single-branch",
        ctx.project.repo_url, ctx.repo_dir,
    };
    try runArgv(ctx, .clone, argv, null);
}

fn runShellStep(ctx: *DeployContext, kind: StepKind, cmd: []const u8) !void {
    ctx.logHeader(kind);
    try runViaSh(ctx, kind, cmd);
}

fn runViaSh(ctx: *DeployContext, kind: StepKind, cmd: []const u8) !void {
    const argv: []const []const u8 = &.{ "sh", "-c", cmd };
    try runArgv(ctx, kind, argv, ctx.repo_dir);
}

fn runArgv(ctx: *DeployContext, kind: StepKind, argv: []const []const u8, cwd: ?[]const u8) !void {
    var child = std.process.Child.init(argv, ctx.orch.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (cwd) |c| child.cwd = c;

    // Inherit hp-server's env vars, then add the project-specific ones from
    // the encrypted vault. We pass an explicit env_map so child only sees
    // approved variables (PATH, HOME, etc inherited; secrets from vault).
    var env_map = try std.process.getEnvMap(ctx.orch.allocator);
    defer env_map.deinit();
    if (ctx.env_pairs) |pairs| {
        for (pairs) |p| {
            const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
            const key = p[0..eq];
            const value = p[eq + 1 ..];
            env_map.put(key, value) catch {};
        }
    }
    child.env_map = &env_map;

    child.spawn() catch |err| {
        ctx.writeLog("spawn failed\n");
        ctx.logFooter(kind, false, -1);
        return err;
    };

    // Drain stdout and stderr into the log file, line by line.
    if (child.stdout) |stdout| try drainTo(stdout, ctx.log_file);
    if (child.stderr) |stderr| try drainTo(stderr, ctx.log_file);

    const term = try child.wait();
    const exit_code: i32 = switch (term) {
        .Exited => |c| @intCast(c),
        else => -1,
    };
    const ok = exit_code == 0;
    ctx.logFooter(kind, ok, exit_code);
    if (!ok) return error.StepFailed;
}

fn drainTo(stream: anytype, out: std.fs.File) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&buf) catch break;
        if (n == 0) break;
        out.writeAll(buf[0..n]) catch {};
        if (buf[0..n].len == 0) break;
    }
}

fn publishStatic(ctx: *DeployContext) !void {
    ctx.logHeader(.publish);

    // Choose source dir: <repo>/<publish_dir> if set, else <repo>
    const src_dir = if (ctx.project.publish_dir.len > 0)
        try std.fmt.allocPrint(ctx.orch.allocator, "{s}/{s}", .{ ctx.repo_dir, ctx.project.publish_dir })
    else
        try ctx.orch.allocator.dupe(u8, ctx.repo_dir);
    defer ctx.orch.allocator.free(src_dir);

    // Confirm src exists
    var sd = std.fs.openDirAbsolute(src_dir, .{}) catch {
        ctx.writeLog("publish_dir not found\n");
        ctx.logFooter(.publish, false, -1);
        return error.PublishDirMissing;
    };
    sd.close();

    std.fs.makeDirAbsolute(ctx.new_release_dir) catch {};

    // Use cp -a to preserve perms and recursively copy. cp is in Termux PATH.
    const cmd = try std.fmt.allocPrint(
        ctx.orch.allocator,
        "set -e; cp -a {s}/. {s}/",
        .{ src_dir, ctx.new_release_dir },
    );
    defer ctx.orch.allocator.free(cmd);
    try runViaSh(ctx, .publish, cmd);

    // Atomic symlink swap: ~/data/projects/<id>/current -> releases/<ts>
    const current_link = try std.fmt.allocPrint(ctx.orch.allocator, "{s}/current", .{ctx.work_dir});
    defer ctx.orch.allocator.free(current_link);

    // Use ln -sfn for atomic replacement (-n treats existing symlink-to-dir as a file)
    const link_cmd = try std.fmt.allocPrint(
        ctx.orch.allocator,
        "ln -sfn {s} {s}",
        .{ ctx.new_release_dir, current_link },
    );
    defer ctx.orch.allocator.free(link_cmd);
    var link_argv: [3][]const u8 = .{ "sh", "-c", link_cmd };
    try runArgv(ctx, .publish, &link_argv, null);

    // Prune old releases (keep last 5).
    const prune_cmd = try std.fmt.allocPrint(
        ctx.orch.allocator,
        "ls -1t {s} | tail -n +6 | xargs -I {{}} rm -rf {s}/{{}}",
        .{ ctx.releases_dir, ctx.releases_dir },
    );
    defer ctx.orch.allocator.free(prune_cmd);
    var prune_argv: [3][]const u8 = .{ "sh", "-c", prune_cmd };
    runArgv(ctx, .publish, &prune_argv, null) catch {};
}

/// Verify a GitHub-style HMAC-SHA256 signature: header is
/// "sha256=<64 hex chars>". Returns true if it matches HMAC over `body`
/// with the project's webhook_secret.
pub fn verifyGithubSignature(secret: []const u8, signature_header: []const u8, body: []const u8) bool {
    const prefix = "sha256=";
    if (signature_header.len != prefix.len + 64) return false;
    if (!std.mem.startsWith(u8, signature_header, prefix)) return false;

    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, body, secret);

    // Convert mac to hex for constant-time compare against the header bytes.
    const cs = "0123456789abcdef";
    var got_hex: [64]u8 = undefined;
    for (mac, 0..) |b, i| {
        got_hex[i * 2] = cs[b >> 4];
        got_hex[i * 2 + 1] = cs[b & 0xf];
    }
    var sig_lower: [64]u8 = undefined;
    for (signature_header[prefix.len..], 0..) |c, i| {
        sig_lower[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return std.crypto.utils.timingSafeEql([64]u8, got_hex, sig_lower);
}

/// Tail the last N bytes of the build log. Returns owned slice. Caller frees.
pub fn tailLog(allocator: std.mem.Allocator, project_id: []const u8, max_bytes: usize) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/data/projects/{s}/logs/build.log", .{ HOME, project_id });
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return try allocator.dupe(u8, ""),
        else => return err,
    };
    defer file.close();
    const stat = try file.stat();
    const start: u64 = if (stat.size > max_bytes) stat.size - max_bytes else 0;
    try file.seekTo(start);
    const remaining = stat.size - start;
    const buf = try allocator.alloc(u8, remaining);
    const n = try file.readAll(buf);
    return buf[0..n];
}

test "verifyGithubSignature accepts valid hmac" {
    const secret = "deadbeef";
    const body = "{\"ref\":\"refs/heads/main\"}";
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, body, secret);
    var hex: [64]u8 = undefined;
    const cs = "0123456789abcdef";
    for (mac, 0..) |b, i| {
        hex[i * 2] = cs[b >> 4];
        hex[i * 2 + 1] = cs[b & 0xf];
    }
    var header: [71]u8 = undefined;
    @memcpy(header[0..7], "sha256=");
    @memcpy(header[7..71], &hex);
    try std.testing.expect(verifyGithubSignature(secret, &header, body));
    // Tampered body
    try std.testing.expect(!verifyGithubSignature(secret, &header, "{\"ref\":\"x\"}"));
    // Wrong secret
    try std.testing.expect(!verifyGithubSignature("wrong", &header, body));
}
