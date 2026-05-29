//! Invite codes. Operator generates these, hands them out, friends use
//! them at /signup?invite=... to skip the approval queue.
//!
//! Format: RH-XXXX-XXXX (12 chars total, uppercase alphanumeric, dashes
//! for readability). Single-use by default, optional expiry.
//!
//! Persisted at ~/.hp-server-invites.jsonl.

const std = @import("std");

const PATH = "/data/data/com.termux/files/home/.hp-server-invites.jsonl";

pub const Invite = struct {
    code: []const u8,
    note: []const u8 = "",
    created_by: []const u8,
    created_at: i64,
    expires_at: i64 = 0, // 0 = no expiry
    max_uses: u32 = 1,
    uses: u32 = 0,
    last_used_by: ?[]const u8 = null,
    last_used_at: i64 = 0,

    pub fn isUsable(self: Invite) bool {
        if (self.uses >= self.max_uses) return false;
        if (self.expires_at != 0 and std.time.timestamp() > self.expires_at) return false;
        return true;
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    mutex: std.Thread.Mutex,
    invites: std.ArrayList(Invite),

    pub fn init(allocator: std.mem.Allocator) !*Manager {
        const m = try allocator.create(Manager);
        m.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .mutex = .{},
            .invites = std.ArrayList(Invite).init(allocator),
        };
        try m.loadFromDisk();
        return m;
    }

    fn loadFromDisk(self: *Manager) !void {
        const file = std.fs.openFileAbsolute(PATH, .{}) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer file.close();
        const data = try file.readToEndAlloc(self.allocator, 1 * 1024 * 1024);
        defer self.allocator.free(data);

        const arena = self.arena.allocator();
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
            defer parsed.deinit();
            const v = parsed.value;
            if (v != .object) continue;
            const obj = v.object;

            const code = obj.get("code") orelse continue;
            const created_by = obj.get("created_by") orelse continue;
            if (code != .string or created_by != .string) continue;

            var inv = Invite{
                .code = try arena.dupe(u8, code.string),
                .created_by = try arena.dupe(u8, created_by.string),
                .created_at = if (obj.get("created_at")) |x| (if (x == .integer) x.integer else 0) else 0,
            };
            if (obj.get("note")) |x| if (x == .string) {
                inv.note = try arena.dupe(u8, x.string);
            };
            if (obj.get("expires_at")) |x| if (x == .integer) {
                inv.expires_at = x.integer;
            };
            if (obj.get("max_uses")) |x| if (x == .integer) {
                inv.max_uses = @intCast(@max(x.integer, 0));
            };
            if (obj.get("uses")) |x| if (x == .integer) {
                inv.uses = @intCast(@max(x.integer, 0));
            };
            if (obj.get("last_used_by")) |x| if (x == .string) {
                inv.last_used_by = try arena.dupe(u8, x.string);
            };
            if (obj.get("last_used_at")) |x| if (x == .integer) {
                inv.last_used_at = x.integer;
            };

            try self.invites.append(inv);
        }
    }

    fn rewriteToDisk(self: *Manager) !void {
        const tmp = PATH ++ ".tmp";
        var f = try std.fs.createFileAbsolute(tmp, .{ .truncate = true, .mode = 0o600 });
        defer f.close();
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        for (self.invites.items) |inv| {
            buf.clearRetainingCapacity();
            const w = buf.writer();
            try w.writeAll("{\"code\":");
            try writeJsonString(w, inv.code);
            try w.writeAll(",\"created_by\":");
            try writeJsonString(w, inv.created_by);
            try w.print(",\"created_at\":{d},\"expires_at\":{d},\"max_uses\":{d},\"uses\":{d}", .{
                inv.created_at, inv.expires_at, inv.max_uses, inv.uses,
            });
            if (inv.note.len > 0) {
                try w.writeAll(",\"note\":");
                try writeJsonString(w, inv.note);
            }
            if (inv.last_used_by) |x| {
                try w.writeAll(",\"last_used_by\":");
                try writeJsonString(w, x);
            }
            if (inv.last_used_at != 0) {
                try w.print(",\"last_used_at\":{d}", .{inv.last_used_at});
            }
            try w.writeAll("}\n");
            try f.writeAll(buf.items);
        }
        try std.fs.renameAbsolute(tmp, PATH);
    }

    pub fn list(self: *Manager, allocator: std.mem.Allocator) ![]Invite {
        self.mutex.lock();
        defer self.mutex.unlock();
        return allocator.dupe(Invite, self.invites.items);
    }

    pub fn create(self: *Manager, created_by: []const u8, note: []const u8, expires_at: i64, max_uses: u32) !Invite {
        self.mutex.lock();
        defer self.mutex.unlock();

        const arena = self.arena.allocator();
        // Generate a 12-char readable code: RH-XXXX-XXXX
        const code = try generateCode(arena);

        const inv = Invite{
            .code = code,
            .note = try arena.dupe(u8, note),
            .created_by = try arena.dupe(u8, created_by),
            .created_at = std.time.timestamp(),
            .expires_at = expires_at,
            .max_uses = if (max_uses == 0) 1 else max_uses,
        };
        try self.invites.append(inv);
        try self.rewriteToDisk();
        return inv;
    }

    /// Lookup + atomically consume an invite. Returns the (already-consumed)
    /// invite on success. NotFound or AlreadyUsed errors otherwise.
    pub fn consume(self: *Manager, code: []const u8, used_by: []const u8) !Invite {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.invites.items, 0..) |inv, i| {
            if (!std.mem.eql(u8, inv.code, code)) continue;
            if (!inv.isUsable()) return error.AlreadyUsed;
            self.invites.items[i].uses += 1;
            self.invites.items[i].last_used_by = self.arena.allocator().dupe(u8, used_by) catch null;
            self.invites.items[i].last_used_at = std.time.timestamp();
            try self.rewriteToDisk();
            return self.invites.items[i];
        }
        return error.NotFound;
    }

    pub fn revoke(self: *Manager, code: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var found_at: ?usize = null;
        for (self.invites.items, 0..) |inv, i| {
            if (std.mem.eql(u8, inv.code, code)) {
                found_at = i;
                break;
            }
        }
        const i = found_at orelse return error.NotFound;
        _ = self.invites.orderedRemove(i);
        try self.rewriteToDisk();
    }
};

fn generateCode(arena: std.mem.Allocator) ![]const u8 {
    // RH-XXXX-XXXX, X is base32-ish (upper alpha + 2-9 to avoid 0/O 1/I).
    const ALPHA = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // 32 chars
    var bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    var out = try arena.alloc(u8, 12); // RH-XXXX-XXXX
    out[0] = 'R';
    out[1] = 'H';
    out[2] = '-';
    out[3] = ALPHA[bytes[0] % ALPHA.len];
    out[4] = ALPHA[bytes[1] % ALPHA.len];
    out[5] = ALPHA[bytes[2] % ALPHA.len];
    out[6] = ALPHA[bytes[3] % ALPHA.len];
    out[7] = '-';
    out[8] = ALPHA[bytes[4] % ALPHA.len];
    out[9] = ALPHA[bytes[5] % ALPHA.len];
    out[10] = ALPHA[bytes[6] % ALPHA.len];
    out[11] = ALPHA[bytes[7] % ALPHA.len];
    return out;
}

fn writeJsonString(w: anytype, s: []const u8) !void {
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
