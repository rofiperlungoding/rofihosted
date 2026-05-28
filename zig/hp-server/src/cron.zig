//! Per-project scheduled tasks. Operator defines:
//!   { name, project_id, schedule, command, enabled }
//! Schedule: simplified cron expression, only 'every Ns/Nm/Nh/Nd' OR a
//! 5-field standard "<min> <hour> <dom> <mon> <dow>" with '*' or numbers.
//!
//! Storage: ~/.hp-server-cron.jsonl, append + atomic rewrite on update.
//! Execution: a background loop wakes every minute, evaluates each enabled
//! task, spawns 'sh -c <command>' in the project's current dir with the
//! same env injection used by the supervisor (secrets + ROFI_*).
//!
//! This is the "AI automations / pipelines / cron" capability the operator
//! asked for. Examples:
//!   - "every 1h" command="curl -sX POST $ROFI_DB_PATH/digest"
//!   - "0 6 * * *" command="node scripts/daily-backup.js"
//!   - "every 15m" command="python3 scripts/scrape.py"
const std = @import("std");
const projects = @import("projects.zig");
const projsecrets = @import("projsecrets.zig");

const HOME = "/data/data/com.termux/files/home";
const PATH = HOME ++ "/.hp-server-cron.jsonl";

pub const Schedule = union(enum) {
    /// Run every N seconds. Used for short intervals.
    every_seconds: u64,
    /// Standard 5-field cron expression. We only support '*' and integer
    /// literals on each field (no ranges / steps / lists). Good enough.
    fields: Fields,

    pub const Fields = struct {
        minute: ?u8, // null = '*'
        hour: ?u8,
        dom: ?u8,
        month: ?u8,
        dow: ?u8,
    };
};

pub const Task = struct {
    id: []const u8,
    name: []const u8,
    project_id: []const u8,
    schedule_str: []const u8, // raw text the operator typed
    command: []const u8,
    enabled: bool,
    last_run_at: i64 = 0,
    last_exit: i32 = 0,
    runs: u64 = 0,
    failures: u64 = 0,
    /// Computed schedule, parsed at load time. If parse fails, .every_seconds = 0
    /// and we don't fire.
    schedule: Schedule = .{ .every_seconds = 0 },
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    pepper: []const u8,
    projects_mgr: *projects.Manager,
    mutex: std.Thread.Mutex,
    tasks: std.ArrayList(Task),
    arena_state: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, pepper: []const u8, projects_mgr: *projects.Manager) !*Manager {
        const m = try allocator.create(Manager);
        m.* = .{
            .allocator = allocator,
            .pepper = pepper,
            .projects_mgr = projects_mgr,
            .mutex = .{},
            .tasks = std.ArrayList(Task).init(allocator),
            .arena_state = std.heap.ArenaAllocator.init(allocator),
        };
        try m.loadFromDisk();
        return m;
    }

    fn loadFromDisk(self: *Manager) !void {
        const file = std.fs.openFileAbsolute(PATH, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();
        const data = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(data);

        var lines = std.mem.tokenizeScalar(u8, data, '\n');
        const arena = self.arena_state.allocator();
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const Wire = struct {
                id: []const u8,
                name: []const u8,
                project_id: []const u8,
                schedule: []const u8,
                command: []const u8,
                enabled: bool = true,
                last_run_at: i64 = 0,
                last_exit: i32 = 0,
                runs: u64 = 0,
                failures: u64 = 0,
            };
            const parsed = std.json.parseFromSlice(Wire, self.allocator, line, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            }) catch continue;
            defer parsed.deinit();
            const w = parsed.value;
            const sched = parseSchedule(w.schedule) catch Schedule{ .every_seconds = 0 };
            try self.tasks.append(.{
                .id = try arena.dupe(u8, w.id),
                .name = try arena.dupe(u8, w.name),
                .project_id = try arena.dupe(u8, w.project_id),
                .schedule_str = try arena.dupe(u8, w.schedule),
                .command = try arena.dupe(u8, w.command),
                .enabled = w.enabled,
                .last_run_at = w.last_run_at,
                .last_exit = w.last_exit,
                .runs = w.runs,
                .failures = w.failures,
                .schedule = sched,
            });
        }
    }

    fn rewriteToDisk(self: *Manager) !void {
        const tmp = PATH ++ ".tmp";
        var f = try std.fs.createFileAbsolute(tmp, .{ .truncate = true, .mode = 0o600 });
        defer f.close();
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        for (self.tasks.items) |t| {
            buf.clearRetainingCapacity();
            const w = buf.writer();
            try w.writeAll("{\"id\":\"");
            try w.writeAll(t.id);
            try w.writeAll("\",\"name\":\"");
            try writeJsonStr(w, t.name);
            try w.writeAll(",\"project_id\":\"");
            try w.writeAll(t.project_id);
            try w.writeAll("\",\"schedule\":\"");
            try writeJsonStr(w, t.schedule_str);
            try w.writeAll(",\"command\":\"");
            try writeJsonStr(w, t.command);
            try w.print(
                ",\"enabled\":{s},\"last_run_at\":{d},\"last_exit\":{d},\"runs\":{d},\"failures\":{d}}}\n",
                .{
                    if (t.enabled) "true" else "false",
                    t.last_run_at,
                    t.last_exit,
                    t.runs,
                    t.failures,
                },
            );
            try f.writeAll(buf.items);
        }
        try std.fs.renameAbsolute(tmp, PATH);
    }

    pub fn create(
        self: *Manager,
        name: []const u8,
        project_id: []const u8,
        schedule_str: []const u8,
        command: []const u8,
    ) !Task {
        if (name.len == 0 or name.len > 64) return error.InvalidName;
        if (command.len == 0 or command.len > 4096) return error.InvalidCommand;
        if (self.projects_mgr.getById(project_id) == null) return error.ProjectNotFound;

        const schedule = try parseSchedule(schedule_str);

        var id_bytes: [8]u8 = undefined;
        std.crypto.random.bytes(&id_bytes);
        var id_hex: [16]u8 = undefined;
        const cs = "0123456789abcdef";
        for (id_bytes, 0..) |b, i| {
            id_hex[i * 2] = cs[b >> 4];
            id_hex[i * 2 + 1] = cs[b & 0xf];
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        const arena = self.arena_state.allocator();
        const task = Task{
            .id = try arena.dupe(u8, &id_hex),
            .name = try arena.dupe(u8, name),
            .project_id = try arena.dupe(u8, project_id),
            .schedule_str = try arena.dupe(u8, schedule_str),
            .command = try arena.dupe(u8, command),
            .enabled = true,
            .schedule = schedule,
        };
        try self.tasks.append(task);
        try self.rewriteToDisk();
        return task;
    }

    pub fn delete(self: *Manager, id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.tasks.items, 0..) |t, i| {
            if (std.mem.eql(u8, t.id, id)) {
                _ = self.tasks.orderedRemove(i);
                try self.rewriteToDisk();
                return;
            }
        }
        return error.NotFound;
    }

    pub fn toggle(self: *Manager, id: []const u8, enabled: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.tasks.items) |*t| {
            if (std.mem.eql(u8, t.id, id)) {
                t.enabled = enabled;
                try self.rewriteToDisk();
                return;
            }
        }
        return error.NotFound;
    }

    pub fn listForProject(self: *Manager, allocator: std.mem.Allocator, project_id: []const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out = std.ArrayList(u8).init(allocator);
        const w = out.writer();
        try w.writeAll("{\"ok\":true,\"tasks\":[");
        var first = true;
        for (self.tasks.items) |t| {
            if (!std.mem.eql(u8, t.project_id, project_id)) continue;
            if (!first) try w.writeAll(",");
            first = false;
            try w.writeAll("{\"id\":\"");
            try w.writeAll(t.id);
            try w.writeAll("\",\"name\":\"");
            try writeJsonStr(w, t.name);
            try w.writeAll(",\"schedule\":\"");
            try writeJsonStr(w, t.schedule_str);
            try w.writeAll(",\"command\":\"");
            try writeJsonStr(w, t.command);
            try w.print(
                ",\"enabled\":{s},\"last_run_at\":{d},\"last_exit\":{d},\"runs\":{d},\"failures\":{d}}}",
                .{
                    if (t.enabled) "true" else "false",
                    t.last_run_at,
                    t.last_exit,
                    t.runs,
                    t.failures,
                },
            );
        }
        try w.writeAll("]}");
        return out.toOwnedSlice();
    }

    fn shouldFire(self: *Manager, t: *const Task, now: i64, now_minute: u8, now_hour: u8, now_dom: u8, now_month: u8, now_dow: u8) bool {
        _ = self;
        if (!t.enabled) return false;
        switch (t.schedule) {
            .every_seconds => |s| {
                if (s == 0) return false;
                return @as(u64, @intCast(now - t.last_run_at)) >= s;
            },
            .fields => |f| {
                // Match minute boundary. We get called once per minute by the loop.
                if (t.last_run_at == now) return false;
                if (now - t.last_run_at < 50) return false; // dedupe within same minute
                if (f.minute) |v| if (v != now_minute) return false;
                if (f.hour) |v| if (v != now_hour) return false;
                if (f.dom) |v| if (v != now_dom) return false;
                if (f.month) |v| if (v != now_month) return false;
                if (f.dow) |v| if (v != now_dow) return false;
                return true;
            },
        }
    }

    pub fn loop(self: *Manager) void {
        // Initial small delay so we don't fire stale tasks at boot
        std.Thread.sleep(20 * std.time.ns_per_s);
        while (true) {
            const now = std.time.timestamp();
            const epoch_seconds = @as(u64, @intCast(now));
            const days_since_epoch: u64 = epoch_seconds / 86400;
            const seconds_in_day: u64 = epoch_seconds % 86400;
            const minute: u8 = @intCast((seconds_in_day / 60) % 60);
            const hour: u8 = @intCast(seconds_in_day / 3600);
            const dow: u8 = @intCast((days_since_epoch + 4) % 7); // 1970-01-01 was a Thursday (=4)
            // Compute date (year/month/day) crudely - good enough for cron matching.
            const ymd = unixToYmd(epoch_seconds);
            const month: u8 = ymd.month;
            const dom: u8 = ymd.day;

            // Snapshot ids to fire to avoid holding mutex during shell exec.
            self.mutex.lock();
            var to_fire = std.ArrayList([]u8).init(self.allocator);
            for (self.tasks.items) |*t| {
                if (self.shouldFire(t, now, minute, hour, dom, month, dow)) {
                    const id = self.allocator.dupe(u8, t.id) catch continue;
                    to_fire.append(id) catch {
                        self.allocator.free(id);
                        continue;
                    };
                }
            }
            self.mutex.unlock();

            for (to_fire.items) |id| {
                self.runOnce(id) catch |err| {
                    std.log.warn("cron task {s} failed: {}", .{ id, err });
                };
                self.allocator.free(id);
            }
            to_fire.deinit();

            std.Thread.sleep(30 * std.time.ns_per_s); // tick every 30s
        }
    }

    /// Public hook for the operator's "Run now" button.
    pub fn runOnce(self: *Manager, task_id: []const u8) !void {
        // Snapshot the task fields we need.
        self.mutex.lock();
        var found: ?Task = null;
        for (self.tasks.items) |t| {
            if (std.mem.eql(u8, t.id, task_id)) {
                found = t;
                break;
            }
        }
        self.mutex.unlock();
        const task = found orelse return error.NotFound;
        const project = self.projects_mgr.getById(task.project_id) orelse return error.ProjectNotFound;

        const work_root = try std.fmt.allocPrint(self.allocator, "{s}/data/projects/{s}", .{ HOME, task.project_id });
        defer self.allocator.free(work_root);
        const current_dir = try std.fmt.allocPrint(self.allocator, "{s}/current", .{work_root});
        defer self.allocator.free(current_dir);
        const repo_dir = try std.fmt.allocPrint(self.allocator, "{s}/repo", .{work_root});
        defer self.allocator.free(repo_dir);

        const cwd: []const u8 = blk: {
            std.fs.accessAbsolute(current_dir, .{}) catch {
                std.fs.accessAbsolute(repo_dir, .{}) catch {
                    // Neither current/ nor repo/ exists yet (e.g. project never deployed).
                    // Make sure the work_root itself exists and use it as cwd.
                    std.fs.makeDirAbsolute(work_root) catch {};
                    break :blk work_root;
                };
                break :blk repo_dir;
            };
            break :blk current_dir;
        };

        const log_dir = try std.fmt.allocPrint(self.allocator, "{s}/logs", .{work_root});
        defer self.allocator.free(log_dir);
        std.fs.makeDirAbsolute(log_dir) catch {};
        const log_path = try std.fmt.allocPrint(self.allocator, "{s}/cron.log", .{log_dir});
        defer self.allocator.free(log_path);

        var log_file = std.fs.createFileAbsolute(log_path, .{ .truncate = false, .mode = 0o600 }) catch return;
        defer log_file.close();
        log_file.seekFromEnd(0) catch {};
        var hdr: [256]u8 = undefined;
        const hdr_msg = std.fmt.bufPrint(&hdr, "\n=== cron {s} '{s}' [{d}] ===\n", .{ task.id, task.name, std.time.timestamp() }) catch "\n=== cron ===\n";
        log_file.writeAll(hdr_msg) catch {};

        // Build env
        var env_map = try std.process.getEnvMap(self.allocator);
        defer env_map.deinit();
        const env_pairs = projsecrets.Vault.loadAsEnvPairs(self.allocator, self.pepper, task.project_id) catch &[_][]u8{};
        defer {
            for (env_pairs) |p| self.allocator.free(p);
            if (env_pairs.len > 0) self.allocator.free(env_pairs);
        }
        for (env_pairs) |p| {
            const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
            try env_map.put(p[0..eq], p[eq + 1 ..]);
        }
        const db_path = try std.fmt.allocPrint(self.allocator, "{s}/data/dbs/{s}.db", .{ HOME, task.project_id });
        defer self.allocator.free(db_path);
        try env_map.put("ROFI_DB_PATH", db_path);
        try env_map.put("ROFI_PROJECT_ID", task.project_id);
        try env_map.put("ROFI_SUBDOMAIN", project.subdomain);

        var argv: [3][]const u8 = .{ "sh", "-c", task.command };
        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.cwd = cwd;
        child.env_map = &env_map;

        try child.spawn();
        if (child.stdout) |so| drainTo(so, log_file);
        if (child.stderr) |se| drainTo(se, log_file);
        const term = try child.wait();
        const exit_code: i32 = switch (term) {
            .Exited => |c| @intCast(c),
            else => -1,
        };

        var foot: [128]u8 = undefined;
        const foot_msg = std.fmt.bufPrint(&foot, "=== exit={d} ===\n", .{exit_code}) catch "=== exit ===\n";
        log_file.writeAll(foot_msg) catch {};

        self.mutex.lock();
        for (self.tasks.items) |*t| {
            if (std.mem.eql(u8, t.id, task_id)) {
                t.last_run_at = std.time.timestamp();
                t.last_exit = exit_code;
                t.runs += 1;
                if (exit_code != 0) t.failures += 1;
                break;
            }
        }
        self.rewriteToDisk() catch {};
        self.mutex.unlock();
    }
};

/// Parse "every Ns/Nm/Nh/Nd" or "<min> <hour> <dom> <mon> <dow>".
pub fn parseSchedule(s: []const u8) !Schedule {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidSchedule;

    if (std.mem.startsWith(u8, trimmed, "every ")) {
        var rest = std.mem.trim(u8, trimmed[6..], " ");
        const unit_idx = blk: {
            var i: usize = 0;
            while (i < rest.len) : (i += 1) {
                if (rest[i] < '0' or rest[i] > '9') break :blk i;
            }
            break :blk rest.len;
        };
        if (unit_idx == 0 or unit_idx == rest.len) return error.InvalidSchedule;
        const num = try std.fmt.parseInt(u64, rest[0..unit_idx], 10);
        const unit = std.mem.trim(u8, rest[unit_idx..], " ");
        const seconds: u64 = blk2: {
            if (std.mem.eql(u8, unit, "s") or std.mem.eql(u8, unit, "sec") or std.mem.eql(u8, unit, "seconds")) break :blk2 num;
            if (std.mem.eql(u8, unit, "m") or std.mem.eql(u8, unit, "min") or std.mem.eql(u8, unit, "minutes")) break :blk2 num * 60;
            if (std.mem.eql(u8, unit, "h") or std.mem.eql(u8, unit, "hour") or std.mem.eql(u8, unit, "hours")) break :blk2 num * 3600;
            if (std.mem.eql(u8, unit, "d") or std.mem.eql(u8, unit, "day") or std.mem.eql(u8, unit, "days")) break :blk2 num * 86400;
            return error.InvalidSchedule;
        };
        if (seconds < 30) return error.InvalidSchedule; // floor at 30s
        return .{ .every_seconds = seconds };
    }

    // Try 5-field cron
    var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
    const min_s = it.next() orelse return error.InvalidSchedule;
    const hour_s = it.next() orelse return error.InvalidSchedule;
    const dom_s = it.next() orelse return error.InvalidSchedule;
    const mon_s = it.next() orelse return error.InvalidSchedule;
    const dow_s = it.next() orelse return error.InvalidSchedule;
    if (it.next() != null) return error.InvalidSchedule;

    return .{ .fields = .{
        .minute = try parseField(min_s, 0, 59),
        .hour = try parseField(hour_s, 0, 23),
        .dom = try parseField(dom_s, 1, 31),
        .month = try parseField(mon_s, 1, 12),
        .dow = try parseField(dow_s, 0, 6),
    } };
}

fn parseField(s: []const u8, lo: u8, hi: u8) !?u8 {
    if (s.len == 1 and s[0] == '*') return null;
    const n = std.fmt.parseInt(u8, s, 10) catch return error.InvalidSchedule;
    if (n < lo or n > hi) return error.InvalidSchedule;
    return n;
}

fn drainTo(stream: anytype, out: std.fs.File) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&buf) catch return;
        if (n == 0) return;
        out.writeAll(buf[0..n]) catch return;
    }
}

const Ymd = struct { year: u16, month: u8, day: u8 };

fn unixToYmd(epoch: u64) Ymd {
    // Algorithm from "Howard Hinnant's days_from_civil" inverse.
    // Good for dates 1970 onwards.
    var days: i64 = @intCast(epoch / 86400);
    days += 719468; // shift to 0000-03-01
    const era: i64 = @divFloor(days, 146097);
    const doe: u32 = @intCast(days - era * 146097);
    const yoe: u32 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u32 = (5 * doy + 2) / 153;
    const d: u32 = doy - (153 * mp + 2) / 5 + 1;
    const m: u32 = if (mp < 10) mp + 3 else mp - 9;
    const y_final: i64 = if (m <= 2) y + 1 else y;
    return .{
        .year = @intCast(y_final),
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

fn writeJsonStr(w: anytype, s: []const u8) !void {
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

test "parseSchedule every" {
    const a = try parseSchedule("every 30s");
    try std.testing.expectEqual(@as(u64, 30), a.every_seconds);
    const b = try parseSchedule("every 5m");
    try std.testing.expectEqual(@as(u64, 300), b.every_seconds);
    const c = try parseSchedule("every 2h");
    try std.testing.expectEqual(@as(u64, 7200), c.every_seconds);
    try std.testing.expectError(error.InvalidSchedule, parseSchedule("every 10s"));
}

test "parseSchedule cron fields" {
    const a = try parseSchedule("0 6 * * *");
    try std.testing.expectEqual(@as(u8, 0), a.fields.minute.?);
    try std.testing.expectEqual(@as(u8, 6), a.fields.hour.?);
    try std.testing.expect(a.fields.dom == null);
    try std.testing.expect(a.fields.month == null);
    try std.testing.expect(a.fields.dow == null);
    try std.testing.expectError(error.InvalidSchedule, parseSchedule("60 * * * *"));
}
