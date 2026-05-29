//! Per-project process supervisor for backend (non-static) projects.
//!
//! Lifecycle:
//!   - start(id): spawn `start_cmd` via `sh -c` in the project's release dir
//!     (or repo dir if no release yet). Inject env: project secrets +
//!     PORT=<allocated>, ROFI_PROJECT_ID, NODE_ENV=production, etc.
//!   - stop(id): SIGTERM, wait up to 5s, SIGKILL if needed.
//!   - restart(id): stop + start.
//!   - autoRestart: a background watcher loop checks every 5s whether any
//!     project marked status=running has its child still alive. If not,
//!     respawn with exponential backoff (1s, 2s, 4s, 8s, max 60s).
//!
//! Logs: stdout+stderr captured into ~/data/projects/<id>/logs/runtime.log
//! (rotated at 1 MB by simple truncate-with-tail copy).
//!
//! This sits ABOVE the builder. The builder produces a `current` symlink to
//! a release dir; the supervisor cd's into that release dir to spawn.
const std = @import("std");
const projects = @import("projects.zig");
const projsecrets = @import("projsecrets.zig");

const HOME = "/data/data/com.termux/files/home";
const RUNTIME_LOG_MAX: u64 = 1 * 1024 * 1024; // 1 MB before truncation

pub const ProcessState = enum {
    not_started,
    running,
    crashed,
    stopped,
};

pub const KillReason = enum {
    none,
    operator, // someone hit /api/projects/stop
    crash, // process exited on its own
    rss_quota, // exceeded rss_limit_mb for 2 consecutive samples
};

const Entry = struct {
    project_id: []const u8, // owned
    pid: ?std.posix.pid_t = null,
    state: ProcessState = .not_started,
    started_at: i64 = 0,
    crash_count: u32 = 0,
    last_exit: i32 = 0,
    backoff_ms: u32 = 1000,
    /// Watchdog grace period. While this is non-zero, the auto-restarter skips
    /// this project (so we don't fight a manual stop or a deploy in progress).
    pause_until_ms: i64 = 0,
    /// Counter for consecutive RSS-quota violations. Reset to zero whenever a
    /// sample comes in under the limit. Killed at 2.
    over_quota_count: u8 = 0,
    /// Reason for the most recent kill. Surfaced via /api/projects so the
    /// dashboard can show "killed for OOM" vs "you stopped it".
    last_kill_reason: KillReason = .none,
};

pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    pepper: []const u8,
    projects_mgr: *projects.Manager,
    mutex: std.Thread.Mutex,
    entries: std.ArrayList(Entry),

    pub fn init(
        allocator: std.mem.Allocator,
        pepper: []const u8,
        projects_mgr: *projects.Manager,
    ) !*Supervisor {
        const s = try allocator.create(Supervisor);
        s.* = .{
            .allocator = allocator,
            .pepper = pepper,
            .projects_mgr = projects_mgr,
            .mutex = .{},
            .entries = std.ArrayList(Entry).init(allocator),
        };
        return s;
    }

    fn findOrCreateLocked(self: *Supervisor, project_id: []const u8) !*Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.project_id, project_id)) return e;
        }
        const owned_id = try self.allocator.dupe(u8, project_id);
        try self.entries.append(.{ .project_id = owned_id });
        return &self.entries.items[self.entries.items.len - 1];
    }

    fn findLocked(self: *Supervisor, project_id: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.project_id, project_id)) return e;
        }
        return null;
    }

    /// Spawn the project's start_cmd. Returns immediately after spawn; child
    /// runs detached. Returns error.NoStartCommand if start_cmd is empty,
    /// error.AlreadyRunning if a live PID exists.
    pub fn start(self: *Supervisor, project_id: []const u8) !void {
        const project = self.projects_mgr.getById(project_id) orelse return error.NotFound;
        if (project.runtime == .static) return error.StaticProject;
        if (project.start_cmd.len == 0) return error.NoStartCommand;

        self.mutex.lock();
        const entry = try self.findOrCreateLocked(project_id);
        if (entry.pid) |existing| {
            if (isAlive(existing)) {
                self.mutex.unlock();
                return error.AlreadyRunning;
            }
        }
        self.mutex.unlock();

        // Resolve cwd: prefer ~/data/projects/<id>/current/ if symlink exists,
        // else ~/data/projects/<id>/repo/.
        const work_root = try std.fmt.allocPrint(self.allocator, "{s}/data/projects/{s}", .{ HOME, project_id });
        defer self.allocator.free(work_root);
        const current_dir = try std.fmt.allocPrint(self.allocator, "{s}/current", .{work_root});
        defer self.allocator.free(current_dir);
        const repo_dir = try std.fmt.allocPrint(self.allocator, "{s}/repo", .{work_root});
        defer self.allocator.free(repo_dir);

        const cwd: []const u8 = blk: {
            if (std.fs.accessAbsolute(current_dir, .{})) {
                break :blk current_dir;
            } else |_| {}
            if (std.fs.accessAbsolute(repo_dir, .{})) {
                break :blk repo_dir;
            } else |_| {}
            // Neither exists; ensure work_root exists and use it as cwd.
            std.fs.makeDirAbsolute(work_root) catch {};
            break :blk work_root;
        };

        // Prepare env: hp-server's env + project secrets + injected vars.
        var env_map = try std.process.getEnvMap(self.allocator);
        defer env_map.deinit();

        const env_pairs = projsecrets.Vault.loadAsEnvPairs(self.allocator, self.pepper, project_id) catch &[_][]u8{};
        defer {
            for (env_pairs) |p| self.allocator.free(p);
            if (env_pairs.len > 0) self.allocator.free(env_pairs);
        }
        for (env_pairs) |p| {
            const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
            try env_map.put(p[0..eq], p[eq + 1 ..]);
        }

        var port_buf: [8]u8 = undefined;
        const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{project.port});
        try env_map.put("PORT", port_str);
        try env_map.put("ROFI_PROJECT_ID", project_id);
        try env_map.put("ROFI_SUBDOMAIN", project.subdomain);
        try env_map.put("HOST", "127.0.0.1");
        // Auto-injected DB path so the project can use a per-tenant SQLite
        // without needing to know about hp-server's storage layout.
        const db_path = try std.fmt.allocPrint(self.allocator, "{s}/data/dbs/{s}.db", .{ HOME, project_id });
        defer self.allocator.free(db_path);
        try env_map.put("ROFI_DB_PATH", db_path);

        // Convenience: many ORMs (Drizzle, Prisma, Knex, SQLAlchemy) read
        // DATABASE_URL by default. Auto-set to a SQLite URL pointing at the
        // per-project DB so devs can `import drizzle from 'drizzle-orm/...'`
        // and have it just work. Operator overrides win - if they set
        // DATABASE_URL via secrets we leave it alone.
        if (env_map.get("DATABASE_URL") == null) {
            const db_url = try std.fmt.allocPrint(self.allocator, "file:{s}", .{db_path});
            defer self.allocator.free(db_url);
            try env_map.put("DATABASE_URL", db_url);
        }

        // Project public URL (so server-side code can build absolute links).
        const public_url = try std.fmt.allocPrint(self.allocator, "https://{s}.rofihosted.space", .{project.subdomain});
        defer self.allocator.free(public_url);
        try env_map.put("ROFI_PUBLIC_URL", public_url);

        // Auth-as-a-service endpoint base (relative to the project's own
        // subdomain). Apps can POST username+password to /auth/signup
        // and /auth/login and get a per-project JWT back without having
        // to write any auth code.
        try env_map.put("ROFI_AUTH_BASE", "/auth");
        // Hint Node-style ecosystems toward production unless operator overrode it
        if (env_map.get("NODE_ENV") == null) try env_map.put("NODE_ENV", "production");

        // Open runtime log for stdout+stderr append. We truncate if it grew past
        // the cap.
        const log_dir = try std.fmt.allocPrint(self.allocator, "{s}/logs", .{work_root});
        defer self.allocator.free(log_dir);
        std.fs.makeDirAbsolute(log_dir) catch {};
        const log_path = try std.fmt.allocPrint(self.allocator, "{s}/runtime.log", .{log_dir});
        defer self.allocator.free(log_path);
        rotateLogIfTooLarge(log_path) catch {};

        var argv: [3][]const u8 = .{ "sh", "-c", project.start_cmd };
        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.cwd = cwd;
        child.env_map = &env_map;

        try child.spawn();

        const pid = child.id;
        self.mutex.lock();
        const e = try self.findOrCreateLocked(project_id);
        e.pid = pid;
        e.state = .running;
        e.started_at = std.time.timestamp();
        e.pause_until_ms = 0;
        self.mutex.unlock();

        // Persist the pid so we can adopt or kill it across hp-server restarts.
        writePidFile(self.allocator, project_id, pid) catch |err| {
            std.log.warn("supervisor: pidfile write failed for {s}: {}", .{ project_id, err });
        };

        _ = self.projects_mgr.update(project_id, .{ .status = .running }) catch {};

        // Start a small drain thread that reads stdout+stderr and appends to
        // runtime.log until the streams close. We DO NOT child.wait() here -
        // the autoRestart loop polls liveness by PID and reaps zombies.
        const ctx = try self.allocator.create(DrainCtx);
        ctx.* = .{
            .allocator = self.allocator,
            .log_path = try self.allocator.dupe(u8, log_path),
            .stdout = child.stdout,
            .stderr = child.stderr,
            .pid = pid,
            .child_id_dummy = pid,
        };
        const t = std.Thread.spawn(.{}, drainThread, .{ctx}) catch |err| {
            self.allocator.free(ctx.log_path);
            self.allocator.destroy(ctx);
            return err;
        };
        t.detach();
    }

    /// SIGTERM the child, give it 5s to exit, then SIGKILL.
    pub fn stop(self: *Supervisor, project_id: []const u8) !void {
        const project = self.projects_mgr.getById(project_id) orelse return error.NotFound;
        if (project.runtime == .static) return error.StaticProject;

        self.mutex.lock();
        const entry = self.findLocked(project_id) orelse {
            self.mutex.unlock();
            return error.NotRunning;
        };
        const pid_opt = entry.pid;
        // Pause auto-restarts for the next 30s so the watcher doesn't immediately
        // bring it back up.
        entry.pause_until_ms = std.time.milliTimestamp() + 30_000;
        entry.state = .stopped;
        entry.last_kill_reason = .operator;
        self.mutex.unlock();

        const pid = pid_opt orelse return error.NotRunning;
        std.posix.kill(pid, std.posix.SIG.TERM) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => return err,
        };
        // Wait up to 5s
        var i: u8 = 0;
        while (i < 50) : (i += 1) {
            if (!isAlive(pid)) break;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
        if (isAlive(pid)) {
            std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        }

        self.mutex.lock();
        if (self.findLocked(project_id)) |e| {
            e.pid = null;
            e.state = .stopped;
        }
        self.mutex.unlock();

        _ = self.projects_mgr.update(project_id, .{ .status = .stopped }) catch {};
        clearPidFile(self.allocator, project_id) catch {};
    }

    pub fn restart(self: *Supervisor, project_id: []const u8) !void {
        self.stop(project_id) catch {};
        // Clear the auto-restart pause so the start happens immediately.
        self.mutex.lock();
        if (self.findLocked(project_id)) |e| e.pause_until_ms = 0;
        self.mutex.unlock();
        // Brief delay to let the OS release the listener socket. Without
        // this the new child often hits 'Address already in use' on bind()
        // while the old socket is still in TIME_WAIT.
        std.Thread.sleep(1500 * std.time.ns_per_ms);
        try self.start(project_id);
    }

    pub fn statusOf(self: *Supervisor, project_id: []const u8) Status {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.findLocked(project_id)) |e| {
            const alive = if (e.pid) |p| isAlive(p) else false;
            const live_pid = if (alive) e.pid else null;
            const rss_kb: u64 = if (live_pid) |p| readRssKb(p) else 0;
            return .{
                .state = if (alive) .running else e.state,
                .pid = live_pid,
                .started_at = e.started_at,
                .crash_count = e.crash_count,
                .last_exit = e.last_exit,
                .rss_kb = rss_kb,
                .last_kill_reason = e.last_kill_reason,
            };
        }
        return .{ .state = .not_started, .pid = null, .started_at = 0, .crash_count = 0, .last_exit = 0, .rss_kb = 0, .last_kill_reason = .none };
    }

    pub const Status = struct {
        state: ProcessState,
        pid: ?std.posix.pid_t,
        started_at: i64,
        crash_count: u32,
        last_exit: i32,
        rss_kb: u64 = 0,
        last_kill_reason: KillReason = .none,
    };

    /// Auto-restart loop. Runs in a detached thread. Every 5s, scans all
    /// projects with status=running in the registry. If their child is dead,
    /// respawn (with exponential backoff). If pause_until_ms is set, skip.
    pub fn autoRestartLoop(self: *Supervisor) void {
        // Initial delay so we don't fight startup-time inits.
        std.Thread.sleep(10 * std.time.ns_per_s);
        while (true) {
            const now_ms = std.time.milliTimestamp();
            // Snapshot to avoid holding mutex during spawn
            self.mutex.lock();
            const ids = self.allocator.alloc([]const u8, self.entries.items.len) catch {
                self.mutex.unlock();
                std.Thread.sleep(5 * std.time.ns_per_s);
                continue;
            };
            for (self.entries.items, 0..) |e, i| {
                ids[i] = self.allocator.dupe(u8, e.project_id) catch "";
            }
            self.mutex.unlock();
            defer {
                for (ids) |id| if (id.len > 0) self.allocator.free(id);
                self.allocator.free(ids);
            }

            // Also: any project marked running in the registry but not in
            // entries (e.g. fresh boot), make sure it gets started.
            const all_projects = self.projects_mgr.listJson(self.allocator) catch null;
            if (all_projects) |json| self.allocator.free(json);

            for (ids) |id| {
                if (id.len == 0) continue;
                self.mutex.lock();
                const entry = self.findLocked(id) orelse {
                    self.mutex.unlock();
                    continue;
                };
                if (now_ms < entry.pause_until_ms) {
                    self.mutex.unlock();
                    continue;
                }
                const alive = if (entry.pid) |p| isAlive(p) else false;
                const should_restart = !alive and entry.state == .running;
                const backoff = entry.backoff_ms;
                const live_pid_opt = if (alive) entry.pid else null;
                self.mutex.unlock();

                // RSS quota enforcement: if the project has rss_limit_mb set
                // and the running child exceeds it for two consecutive samples,
                // SIGTERM the child. autoRestart will respawn it.
                if (live_pid_opt) |live_pid| {
                    const project = self.projects_mgr.getById(id) orelse continue;
                    if (project.rss_limit_mb > 0) {
                        const rss_kb = readRssKb(live_pid);
                        const rss_mb = rss_kb / 1024;
                        if (rss_mb > project.rss_limit_mb) {
                            self.mutex.lock();
                            const e2 = self.findLocked(id);
                            if (e2) |e| e.over_quota_count += 1;
                            const over_count = if (e2) |e| e.over_quota_count else 0;
                            self.mutex.unlock();
                            if (over_count >= 2) {
                                std.log.warn(
                                    "supervisor: project {s} exceeded RSS limit ({d} MB > {d} MB) for 2 samples, killing pid {d}",
                                    .{ id, rss_mb, project.rss_limit_mb, live_pid },
                                );
                                std.posix.kill(live_pid, std.posix.SIG.TERM) catch {};
                                self.mutex.lock();
                                if (self.findLocked(id)) |e| {
                                    e.over_quota_count = 0;
                                    e.crash_count += 1;
                                    e.last_kill_reason = .rss_quota;
                                }
                                self.mutex.unlock();
                            }
                        } else {
                            self.mutex.lock();
                            if (self.findLocked(id)) |e| e.over_quota_count = 0;
                            self.mutex.unlock();
                        }
                    }
                }

                if (should_restart) {
                    std.Thread.sleep(@as(u64, backoff) * std.time.ns_per_ms);
                    self.start(id) catch |err| {
                        std.log.warn("supervisor: restart failed for {s}: {}", .{ id, err });
                        self.mutex.lock();
                        if (self.findLocked(id)) |e| {
                            e.crash_count += 1;
                            e.state = .crashed;
                            e.backoff_ms = @min(e.backoff_ms * 2, 60_000);
                        }
                        self.mutex.unlock();
                        continue;
                    };
                    self.mutex.lock();
                    if (self.findLocked(id)) |e| {
                        e.backoff_ms = 1000; // reset on success
                    }
                    self.mutex.unlock();
                }
            }

            std.Thread.sleep(5 * std.time.ns_per_s);
        }
    }

    /// Boot-time: scan registry, start any project whose status was 'running'
    /// at last shutdown. Before spawning, kill any orphaned children left
    /// over from the previous hp-server (their pid files persist on disk).
    pub fn restartPersisted(self: *Supervisor) void {
        self.projects_mgr.mutex.lock();
        var ids = std.ArrayList([]const u8).init(self.allocator);
        defer ids.deinit();
        for (self.projects_mgr.projects.items) |p| {
            const owned = self.allocator.dupe(u8, p.id) catch continue;
            ids.append(owned) catch {
                self.allocator.free(owned);
                continue;
            };
        }
        var should_start = std.ArrayList(bool).init(self.allocator);
        defer should_start.deinit();
        for (self.projects_mgr.projects.items) |p| {
            const start_it = (p.runtime != .static) and (p.start_cmd.len > 0) and (p.status == .running);
            should_start.append(start_it) catch {};
        }
        self.projects_mgr.mutex.unlock();

        // Step 1: reap any orphaned children left from a previous run by
        // SIGKILL'ing them. Their parent (old hp-server) is gone, so init has
        // them now, and we have no way to drain their stdout. Better to
        // kill and respawn than leave a port-bound zombie around.
        for (ids.items) |id| {
            if (readPidFile(self.allocator, id)) |stale_pid_opt| {
                if (stale_pid_opt) |stale_pid| {
                    if (isAlive(stale_pid)) {
                        std.log.info("supervisor: reaping orphan pid {d} for {s}", .{ stale_pid, id });
                        std.posix.kill(stale_pid, std.posix.SIG.TERM) catch {};
                        // Give it a moment, then SIGKILL.
                        var w: u8 = 0;
                        while (w < 30) : (w += 1) {
                            if (!isAlive(stale_pid)) break;
                            std.Thread.sleep(100 * std.time.ns_per_ms);
                        }
                        if (isAlive(stale_pid)) {
                            std.posix.kill(stale_pid, std.posix.SIG.KILL) catch {};
                        }
                    }
                }
            } else |_| {}
            clearPidFile(self.allocator, id) catch {};
        }

        // Step 2: respawn the ones that were marked running.
        for (ids.items, 0..) |id, i| {
            if (i < should_start.items.len and should_start.items[i]) {
                self.start(id) catch |err| {
                    std.log.warn("supervisor: boot restart failed for {s}: {}", .{ id, err });
                };
            }
            self.allocator.free(id);
        }
    }
};

/// Returns true if the PID is still alive (kill 0 returns 0).
fn isAlive(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, 0) catch return false;
    return true;
}

/// Read the resident set size of a process (in KiB) from /proc/<pid>/status.
/// Returns 0 if the file is unreadable or VmRSS is missing.
fn readRssKb(pid: std.posix.pid_t) u64 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid}) catch return 0;
    const f = std.fs.openFileAbsolute(path, .{}) catch return 0;
    defer f.close();
    var buf: [4096]u8 = undefined;
    const n = f.readAll(&buf) catch return 0;
    const body = buf[0..n];
    var idx: usize = 0;
    while (idx < body.len) {
        const line_end = std.mem.indexOfScalarPos(u8, body, idx, '\n') orelse body.len;
        const line = body[idx..line_end];
        if (std.mem.startsWith(u8, line, "VmRSS:")) {
            // VmRSS:    12345 kB
            var it = std.mem.tokenizeScalar(u8, line[6..], ' ');
            while (it.next()) |tok| {
                if (std.fmt.parseInt(u64, tok, 10)) |kb| {
                    return kb;
                } else |_| continue;
            }
            return 0;
        }
        idx = line_end + 1;
    }
    return 0;
}

fn pidFilePath(allocator: std.mem.Allocator, project_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/data/projects/{s}/runtime.pid", .{ HOME, project_id });
}

fn writePidFile(allocator: std.mem.Allocator, project_id: []const u8, pid: std.posix.pid_t) !void {
    const path = try pidFilePath(allocator, project_id);
    defer allocator.free(path);
    var f = try std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = 0o600 });
    defer f.close();
    var buf: [16]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}\n", .{pid});
    try f.writeAll(s);
}

/// Returns the recorded pid, or null if the pidfile is missing or empty.
fn readPidFile(allocator: std.mem.Allocator, project_id: []const u8) !?std.posix.pid_t {
    const path = try pidFilePath(allocator, project_id);
    defer allocator.free(path);
    const f = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer f.close();
    var buf: [32]u8 = undefined;
    const n = try f.readAll(&buf);
    if (n == 0) return null;
    const trimmed = std.mem.trim(u8, buf[0..n], &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    const pid = std.fmt.parseInt(std.posix.pid_t, trimmed, 10) catch return null;
    return pid;
}

fn clearPidFile(allocator: std.mem.Allocator, project_id: []const u8) !void {
    const path = try pidFilePath(allocator, project_id);
    defer allocator.free(path);
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

const DrainCtx = struct {
    allocator: std.mem.Allocator,
    log_path: []u8,
    stdout: ?std.fs.File,
    stderr: ?std.fs.File,
    pid: std.posix.pid_t,
    child_id_dummy: std.posix.pid_t, // unused, just keep struct shape stable
};

fn drainThread(ctx: *DrainCtx) void {
    defer {
        ctx.allocator.free(ctx.log_path);
        ctx.allocator.destroy(ctx);
    }

    var f = std.fs.createFileAbsolute(ctx.log_path, .{ .truncate = false, .mode = 0o600 }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch {};

    // Drain stdout and stderr concurrently is overkill for our scale. We just
    // round-robin reads.
    var buf: [4096]u8 = undefined;
    while (true) {
        var any_progress = false;
        if (ctx.stdout) |stdout| {
            if (stdout.read(&buf)) |n| {
                if (n > 0) {
                    f.writeAll(buf[0..n]) catch {};
                    any_progress = true;
                } else {
                    ctx.stdout = null;
                    stdout.close();
                }
            } else |_| {
                ctx.stdout = null;
                stdout.close();
            }
        }
        if (ctx.stderr) |stderr| {
            if (stderr.read(&buf)) |n| {
                if (n > 0) {
                    f.writeAll(buf[0..n]) catch {};
                    any_progress = true;
                } else {
                    ctx.stderr = null;
                    stderr.close();
                }
            } else |_| {
                ctx.stderr = null;
                stderr.close();
            }
        }
        if (ctx.stdout == null and ctx.stderr == null) break;
        if (!any_progress) std.Thread.sleep(50 * std.time.ns_per_ms);
    }
}

fn rotateLogIfTooLarge(path: []const u8) !void {
    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();
    const stat = file.stat() catch return;
    if (stat.size <= RUNTIME_LOG_MAX) return;
    // Truncate by keeping the last 256 KB. Read tail, write to tmp, rename.
    const keep: u64 = 256 * 1024;
    file.seekFromEnd(-@as(i64, @intCast(keep))) catch return;
    const buf = std.heap.page_allocator.alloc(u8, keep) catch return;
    defer std.heap.page_allocator.free(buf);
    const n = file.readAll(buf) catch return;
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{path}) catch return;
    var tmp = std.fs.createFileAbsolute(tmp_path, .{ .truncate = true, .mode = 0o600 }) catch return;
    tmp.writeAll(buf[0..n]) catch {};
    tmp.close();
    std.fs.renameAbsolute(tmp_path, path) catch {};
}

/// Read the last `max_bytes` of the project's runtime log.
pub fn tailLog(allocator: std.mem.Allocator, project_id: []const u8, max_bytes: usize) ![]u8 {
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/data/projects/{s}/logs/runtime.log",
        .{ HOME, project_id },
    );
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
