//! Operator-defined rule engine. Single-user. Rules apply to incoming events
//! (visit, login_attempt, blocklist_change, anomaly_detected) and trigger
//! safe actions (block, log, increment counter).
//!
//! Rules are stored as JSONL at ~/.hp-server-rules.jsonl. Each rule has:
//!   { id, name, enabled, trigger, conditions: [...], actions: [...] }
//!
//! Conditions are ANDed. Each condition is { field, op, value }.
//!   field: ip | path | country | ua | classification | method | host | username | success
//!   op: eq | neq | contains | not_contains | starts_with | ends_with
//!   value: string (for success: "true" or "false")
//!
//! Actions are sequential. Each action is { type, ... }.
//!   { type: "block", reason: "...", ttl_seconds: 86400 }
//!   { type: "log", level: "info"|"warn", message: "..." }
//!   { type: "increment", counter: "name" }
//!
//! No regex (too expensive for hot path). No script execution. No mutations
//! that aren't bounded. Rule engine cannot crash the server.
const std = @import("std");
const security = @import("security.zig");
const paths = @import("paths.zig");

const FILE = ".hp-server-rules.jsonl";

pub const Trigger = enum {
    on_visit,
    on_login_attempt,
    on_blocklist_change,
    on_anomaly,

    pub fn fromString(s: []const u8) ?Trigger {
        if (std.mem.eql(u8, s, "on_visit")) return .on_visit;
        if (std.mem.eql(u8, s, "on_login_attempt")) return .on_login_attempt;
        if (std.mem.eql(u8, s, "on_blocklist_change")) return .on_blocklist_change;
        if (std.mem.eql(u8, s, "on_anomaly")) return .on_anomaly;
        return null;
    }
};

pub const Condition = struct {
    field: []const u8,
    op: []const u8,
    value: []const u8,
};

pub const Action = struct {
    type: []const u8,
    reason: []const u8 = "",
    ttl_seconds: i64 = 0,
    level: []const u8 = "",
    message: []const u8 = "",
    counter: []const u8 = "",
};

pub const Rule = struct {
    id: []const u8,
    name: []const u8,
    enabled: bool = true,
    trigger: []const u8,
    conditions: []const Condition = &.{},
    actions: []const Action = &.{},
    /// Lifetime stats (not persisted, recomputed on load)
    matches: u64 = 0,
};

/// Event payload. Fields are nullable to support all trigger types.
pub const Event = struct {
    ip: []const u8 = "",
    path: []const u8 = "",
    country: []const u8 = "",
    ua: []const u8 = "",
    classification: []const u8 = "",
    method: []const u8 = "",
    host: []const u8 = "",
    status: u16 = 0,
    username: []const u8 = "",
    success: bool = false,
};

pub const Engine = struct {
    mutex: std.Thread.Mutex,
    rules: std.ArrayList(Rule),
    /// Counters from "increment" actions
    counters: std.StringHashMap(u64),
    allocator: std.mem.Allocator,
    /// Reference to the blocklist for "block" actions
    blocklist: *security.Blocklist,

    pub fn init(allocator: std.mem.Allocator, blocklist: *security.Blocklist) !*Engine {
        const e = try allocator.create(Engine);
        e.* = .{
            .mutex = .{},
            .rules = std.ArrayList(Rule).init(allocator),
            .counters = std.StringHashMap(u64).init(allocator),
            .allocator = allocator,
            .blocklist = blocklist,
        };
        e.loadFromFile() catch {};
        return e;
    }

    /// Evaluate event against all enabled rules with matching trigger.
    /// Side-effects: blocklist mutations, counter bumps, log lines.
    pub fn dispatch(self: *Engine, trigger: Trigger, ev: Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const trig_str = @tagName(trigger);
        for (self.rules.items) |*rule| {
            if (!rule.enabled) continue;
            if (!std.mem.eql(u8, rule.trigger, trig_str)) continue;
            if (!self.evaluateConditionsLocked(rule.conditions, ev)) continue;
            rule.matches += 1;
            self.executeActionsLocked(rule.*, ev);
        }
    }

    fn fieldValue(field: []const u8, ev: Event) ?[]const u8 {
        if (std.mem.eql(u8, field, "ip")) return ev.ip;
        if (std.mem.eql(u8, field, "path")) return ev.path;
        if (std.mem.eql(u8, field, "country")) return ev.country;
        if (std.mem.eql(u8, field, "ua")) return ev.ua;
        if (std.mem.eql(u8, field, "classification")) return ev.classification;
        if (std.mem.eql(u8, field, "method")) return ev.method;
        if (std.mem.eql(u8, field, "host")) return ev.host;
        if (std.mem.eql(u8, field, "username")) return ev.username;
        if (std.mem.eql(u8, field, "success")) return if (ev.success) "true" else "false";
        return null;
    }

    fn evaluateConditionsLocked(_: *Engine, conds: []const Condition, ev: Event) bool {
        for (conds) |c| {
            const fv_opt = fieldValue(c.field, ev);
            if (fv_opt == null) return false; // unknown field = no match
            const fv = fv_opt.?;
            const op = c.op;
            const v = c.value;
            const matched: bool = blk: {
                if (std.mem.eql(u8, op, "eq")) break :blk std.mem.eql(u8, fv, v);
                if (std.mem.eql(u8, op, "neq")) break :blk !std.mem.eql(u8, fv, v);
                if (std.mem.eql(u8, op, "contains")) break :blk std.mem.indexOf(u8, fv, v) != null;
                if (std.mem.eql(u8, op, "not_contains")) break :blk std.mem.indexOf(u8, fv, v) == null;
                if (std.mem.eql(u8, op, "starts_with")) break :blk std.mem.startsWith(u8, fv, v);
                if (std.mem.eql(u8, op, "ends_with")) break :blk std.mem.endsWith(u8, fv, v);
                break :blk false;
            };
            if (!matched) return false;
        }
        return true;
    }

    fn executeActionsLocked(self: *Engine, rule: Rule, ev: Event) void {
        for (rule.actions) |a| {
            if (std.mem.eql(u8, a.type, "block")) {
                if (ev.ip.len == 0 or std.mem.eql(u8, ev.ip, "local")) continue;
                const ttl = if (a.ttl_seconds > 0) a.ttl_seconds else 24 * 60 * 60;
                var reason_buf: [256]u8 = undefined;
                const reason = std.fmt.bufPrint(&reason_buf, "rule[{s}]: {s}", .{
                    rule.id,
                    if (a.reason.len > 0) a.reason else "matched",
                }) catch "rule";
                self.blocklist.block(ev.ip, reason, ttl) catch |err| {
                    std.log.warn("rule {s}: block failed: {}", .{ rule.id, err });
                };
                std.log.info("rule {s}: blocked {s} ttl={d}s", .{ rule.id, ev.ip, ttl });
            } else if (std.mem.eql(u8, a.type, "log")) {
                if (std.mem.eql(u8, a.level, "warn")) {
                    std.log.warn("rule[{s}]: {s}", .{ rule.id, a.message });
                } else {
                    std.log.info("rule[{s}]: {s}", .{ rule.id, a.message });
                }
            } else if (std.mem.eql(u8, a.type, "increment")) {
                const counter_name = if (a.counter.len > 0) a.counter else rule.id;
                const gop = self.counters.getOrPut(counter_name) catch continue;
                if (!gop.found_existing) {
                    const dup = self.allocator.dupe(u8, counter_name) catch continue;
                    gop.key_ptr.* = dup;
                    gop.value_ptr.* = 0;
                }
                gop.value_ptr.* += 1;
            }
        }
    }

    pub fn snapshot(self: *Engine, allocator: std.mem.Allocator) ![]Rule {
        self.mutex.lock();
        defer self.mutex.unlock();
        const out = try allocator.alloc(Rule, self.rules.items.len);
        for (self.rules.items, 0..) |r, i| out[i] = r;
        return out;
    }

    pub fn snapshotCounters(self: *Engine, allocator: std.mem.Allocator) ![]CounterEntry {
        self.mutex.lock();
        defer self.mutex.unlock();
        const out = try allocator.alloc(CounterEntry, self.counters.count());
        var i: usize = 0;
        var it = self.counters.iterator();
        while (it.next()) |e| : (i += 1) {
            out[i] = .{ .name = e.key_ptr.*, .value = e.value_ptr.* };
        }
        return out;
    }

    pub const CounterEntry = struct { name: []const u8, value: u64 };

    /// Replace the rule set entirely. Caller passes a JSON array of rule objects.
    /// Validates each rule before persisting. Rejects rules with unknown trigger.
    pub fn replaceFromJson(self: *Engine, json_array: []const u8) !void {
        // Parse using a temporary arena so we own the strings until persistence
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const parsed = std.json.parseFromSlice([]Rule, a, json_array, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return error.InvalidJson;

        // Validate triggers
        for (parsed.value) |r| {
            if (Trigger.fromString(r.trigger) == null) return error.UnknownTrigger;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        // Free old rules
        for (self.rules.items) |r| self.freeRuleLocked(r);
        self.rules.clearRetainingCapacity();

        // Deep-copy parsed rules into the engine's allocator
        for (parsed.value) |r| {
            const copied = try self.dupeRuleLocked(r);
            try self.rules.append(copied);
        }
        try self.persistLocked();
    }

    fn dupeRuleLocked(self: *Engine, src: Rule) !Rule {
        const conds = try self.allocator.alloc(Condition, src.conditions.len);
        errdefer self.allocator.free(conds);
        for (src.conditions, 0..) |c, i| {
            conds[i] = .{
                .field = try self.allocator.dupe(u8, c.field),
                .op = try self.allocator.dupe(u8, c.op),
                .value = try self.allocator.dupe(u8, c.value),
            };
        }
        const actions = try self.allocator.alloc(Action, src.actions.len);
        errdefer self.allocator.free(actions);
        for (src.actions, 0..) |a, i| {
            actions[i] = .{
                .type = try self.allocator.dupe(u8, a.type),
                .reason = try self.allocator.dupe(u8, a.reason),
                .ttl_seconds = a.ttl_seconds,
                .level = try self.allocator.dupe(u8, a.level),
                .message = try self.allocator.dupe(u8, a.message),
                .counter = try self.allocator.dupe(u8, a.counter),
            };
        }
        return .{
            .id = try self.allocator.dupe(u8, src.id),
            .name = try self.allocator.dupe(u8, src.name),
            .enabled = src.enabled,
            .trigger = try self.allocator.dupe(u8, src.trigger),
            .conditions = conds,
            .actions = actions,
            .matches = 0,
        };
    }

    fn freeRuleLocked(self: *Engine, r: Rule) void {
        self.allocator.free(r.id);
        self.allocator.free(r.name);
        self.allocator.free(r.trigger);
        for (r.conditions) |c| {
            self.allocator.free(c.field);
            self.allocator.free(c.op);
            self.allocator.free(c.value);
        }
        self.allocator.free(r.conditions);
        for (r.actions) |a| {
            self.allocator.free(a.type);
            self.allocator.free(a.reason);
            self.allocator.free(a.level);
            self.allocator.free(a.message);
            self.allocator.free(a.counter);
        }
        self.allocator.free(r.actions);
    }

    fn loadFromFile(self: *Engine) !void {
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const PATH = paths.join(&pbuf, FILE);
        const file = std.fs.openFileAbsolute(PATH, .{}) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer file.close();
        const data = try file.readToEndAlloc(self.allocator, 256 * 1024);
        defer self.allocator.free(data);

        // File is one JSON array per write (we always rewrite the whole thing).
        const trimmed = std.mem.trim(u8, data, " \t\r\n");
        if (trimmed.len == 0) return;
        // If it starts with '[', it's an array. If it starts with '{', it's
        // legacy line-by-line - read each line as a rule.
        if (trimmed[0] == '[') {
            try self.replaceFromJson(trimmed);
        } else {
            // Legacy: one rule per line
            var lines = std.mem.tokenizeScalar(u8, trimmed, '\n');
            self.mutex.lock();
            defer self.mutex.unlock();
            while (lines.next()) |line| {
                const ln = std.mem.trim(u8, line, " \t\r");
                if (ln.len == 0) continue;
                const parsed = std.json.parseFromSlice(Rule, self.allocator, ln, .{
                    .ignore_unknown_fields = true,
                    .allocate = .alloc_always,
                }) catch continue;
                defer parsed.deinit();
                const dup = self.dupeRuleLocked(parsed.value) catch continue;
                self.rules.append(dup) catch continue;
            }
        }
    }

    fn persistLocked(self: *Engine) !void {
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        var tbuf: [std.fs.max_path_bytes]u8 = undefined;
        const real_path = paths.join(&pbuf, FILE);
        const tmp = paths.join(&tbuf, FILE ++ ".tmp");
        {
            const file = try std.fs.createFileAbsolute(tmp, .{ .truncate = true, .mode = 0o600 });
            defer file.close();
            try std.json.stringify(self.rules.items, .{ .whitespace = .indent_2 }, file.writer());
            try file.writer().writeByte('\n');
        }
        try std.fs.renameAbsolute(tmp, real_path);
    }
};
