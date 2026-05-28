//! Power monitor - poll termux-battery-status every 30s, fire alerts on
//! state transitions. Designed for the Sharp Aquos S40P deployment where
//! the device CANNOT survive without continuous charging (faulty charging
//! circuit -> bootloops on unplug). Operator's #1 alert: "charger came out".
//!
//! Public API:
//!   - PowerMon.init(allocator, tg_cfg, bus, panic_callback)
//!   - PowerMon.snapshot() returns the last reading + transition counters
//!   - PowerMon.run() spawned as a thread; loops forever
//!
//! Why a separate module: keeps main.zig clean and lets the dashboard hit
//! /api/system/power for the latest status without re-shelling out.

const std = @import("std");
const telegram = @import("telegram.zig");
const events = @import("events.zig");

pub const Status = enum {
    unknown,
    charging,
    full,
    discharging,
    not_charging,

    pub fn fromString(s: []const u8) Status {
        // termux-battery-status emits one of:
        //   CHARGING, DISCHARGING, NOT_CHARGING, FULL, UNKNOWN
        if (std.ascii.eqlIgnoreCase(s, "CHARGING")) return .charging;
        if (std.ascii.eqlIgnoreCase(s, "FULL")) return .full;
        if (std.ascii.eqlIgnoreCase(s, "DISCHARGING")) return .discharging;
        if (std.ascii.eqlIgnoreCase(s, "NOT_CHARGING")) return .not_charging;
        return .unknown;
    }

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .charging => "charging",
            .full => "full",
            .discharging => "discharging",
            .not_charging => "not_charging",
        };
    }

    /// Returns true when the device is plugged in (charging or full).
    pub fn isPlugged(self: Status) bool {
        return self == .charging or self == .full;
    }
};

pub const Reading = struct {
    percentage: i32 = -1, // -1 if termux-api unavailable
    status: Status = .unknown,
    raw: [32]u8 = [_]u8{0} ** 32, // raw status string for diagnostics
    last_check_unix: i64 = 0,
    available: bool = false, // true once first successful read
};

pub const PowerMon = struct {
    allocator: std.mem.Allocator,
    tg_cfg: telegram.Config,
    bus: ?*events.Bus,

    mutex: std.Thread.Mutex = .{},
    last: Reading = .{},
    transitions_unplug: u32 = 0,
    transitions_replug: u32 = 0,
    last_alert_unix: i64 = 0,

    /// Optional callback invoked on charger-disconnect. Use this to flush
    /// caches / sync filesystems before potential power loss.
    panic_cb: ?*const fn () void = null,

    pub fn init(
        allocator: std.mem.Allocator,
        tg_cfg: telegram.Config,
        bus: ?*events.Bus,
    ) PowerMon {
        return .{
            .allocator = allocator,
            .tg_cfg = tg_cfg,
            .bus = bus,
        };
    }

    pub fn snapshot(self: *PowerMon) Reading {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.last;
    }

    pub fn snapshotCounters(self: *PowerMon) struct { unplug: u32, replug: u32 } {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ .unplug = self.transitions_unplug, .replug = self.transitions_replug };
    }

    pub fn run(self: *PowerMon) void {
        // Initial 5s wait so the rest of the system finishes booting.
        std.Thread.sleep(5 * std.time.ns_per_s);
        while (true) {
            const reading = pollOnce(self.allocator);
            self.handle(reading);
            std.Thread.sleep(30 * std.time.ns_per_s);
        }
    }

    fn handle(self: *PowerMon, fresh: Reading) void {
        self.mutex.lock();
        const prev = self.last;
        self.last = fresh;
        // Detect transitions (only once we have a reliable previous reading)
        var unplugged_now = false;
        var replugged_now = false;
        if (prev.available and fresh.available) {
            if (prev.status.isPlugged() and !fresh.status.isPlugged()) {
                self.transitions_unplug += 1;
                unplugged_now = true;
            } else if (!prev.status.isPlugged() and fresh.status.isPlugged()) {
                self.transitions_replug += 1;
                replugged_now = true;
            }
        }
        self.mutex.unlock();

        if (unplugged_now) {
            std.log.warn("powermon: charger disconnected ({d}%, {s})", .{ fresh.percentage, fresh.status.label() });
            self.notify(true, fresh);
            // Best-effort sync: flush filesystem buffers so any in-flight writes
            // hit storage before potential bootloop.
            std.Thread.sleep(50 * std.time.ns_per_ms);
            forceSync(self.allocator);
            if (self.panic_cb) |cb| cb();
            if (self.bus) |b| b.publish(.tunnel_health, .{ .source = "powermon", .reason = "charger_off" }); // reuse existing event for now
        } else if (replugged_now) {
            std.log.info("powermon: charger reconnected ({d}%, {s})", .{ fresh.percentage, fresh.status.label() });
            self.notify(false, fresh);
        }
    }

    fn notify(self: *PowerMon, unplugged: bool, r: Reading) void {
        // Rate limit: at most one alert every 60s so we don't flood Telegram
        // when someone wiggles the cable.
        const now = std.time.timestamp();
        self.mutex.lock();
        const since_last = now - self.last_alert_unix;
        if (since_last < 60) {
            self.mutex.unlock();
            return;
        }
        self.last_alert_unix = now;
        self.mutex.unlock();

        if (!self.tg_cfg.enabled()) return;
        var buf: [256]u8 = undefined;
        const msg = if (unplugged)
            std.fmt.bufPrint(
                &buf,
                "[CHARGER OFF] hp-server lost AC power ({d}%, {s}). Device may bootloop. Reconnect charger ASAP.",
                .{ r.percentage, r.status.label() },
            ) catch return
        else
            std.fmt.bufPrint(
                &buf,
                "[CHARGER ON] AC power restored ({d}%, {s}).",
                .{ r.percentage, r.status.label() },
            ) catch return;
        telegram.send(self.allocator, self.tg_cfg, msg);
    }
};

/// Run termux-battery-status once and parse the JSON. Returns Reading with
/// `available=false` if the binary isn't installed.
fn pollOnce(allocator: std.mem.Allocator) Reading {
    var r = Reading{ .last_check_unix = std.time.timestamp() };
    var argv = [_][]const u8{ "sh", "-c", "command -v termux-battery-status >/dev/null && termux-battery-status 2>/dev/null" };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return r;
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    if (child.stdout) |so| n = so.readAll(&buf) catch 0;
    _ = child.wait() catch {};
    if (n == 0) return r;
    const body = buf[0..n];

    // Tiny ad-hoc JSON peek (avoid full parser, the shape is fixed).
    if (std.mem.indexOf(u8, body, "\"percentage\"")) |i| {
        var j = i + "\"percentage\"".len;
        while (j < body.len and (body[j] == ':' or body[j] == ' ')) : (j += 1) {}
        var end = j;
        while (end < body.len and (body[end] >= '0' and body[end] <= '9')) : (end += 1) {}
        if (end > j) r.percentage = std.fmt.parseInt(i32, body[j..end], 10) catch -1;
    }
    if (std.mem.indexOf(u8, body, "\"status\"")) |i| {
        var j = i + "\"status\"".len;
        while (j < body.len and (body[j] == ':' or body[j] == ' ')) : (j += 1) {}
        if (j < body.len and body[j] == '"') {
            j += 1;
            const end = std.mem.indexOfScalarPos(u8, body, j, '"') orelse j;
            const status_str = body[j..end];
            const take = @min(status_str.len, r.raw.len);
            @memcpy(r.raw[0..take], status_str[0..take]);
            r.status = Status.fromString(status_str);
        }
    }
    r.available = true;
    return r;
}

/// Force a filesystem sync so the kernel flushes writeback to UFS before the
/// device potentially loses power.
fn forceSync(allocator: std.mem.Allocator) void {
    var argv = [_][]const u8{ "sh", "-c", "sync" };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;
    _ = child.wait() catch {};
}
