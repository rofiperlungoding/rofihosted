//! Telegram notifier - spawn `curl` to send messages (Zig http client has DNS issues).
//! Reads TG_BOT_TOKEN and TG_CHAT_ID from env. Silently skips if not set.
const std = @import("std");

pub const Config = struct {
    token: ?[]const u8,
    chat_id: ?[]const u8,

    pub fn fromEnv(allocator: std.mem.Allocator) Config {
        const token = std.process.getEnvVarOwned(allocator, "TG_BOT_TOKEN") catch null;
        const chat = std.process.getEnvVarOwned(allocator, "TG_CHAT_ID") catch null;
        return .{ .token = token, .chat_id = chat };
    }

    pub fn enabled(self: Config) bool {
        return self.token != null and self.chat_id != null;
    }
};

/// Fire-and-forget send. Spawns curl as detached child.
pub fn send(allocator: std.mem.Allocator, cfg: Config, text: []const u8) void {
    if (!cfg.enabled()) return;

    const url = std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendMessage", .{cfg.token.?}) catch return;
    defer allocator.free(url);

    // URL-encode the text (basic)
    const encoded = urlEncode(allocator, text) catch return;
    defer allocator.free(encoded);

    const data = std.fmt.allocPrint(allocator, "chat_id={s}&text={s}&parse_mode=Markdown", .{ cfg.chat_id.?, encoded }) catch return;
    defer allocator.free(data);

    var child = std.process.Child.init(&.{ "curl", "-s", "-o", "/dev/null", "-X", "POST", "-d", data, url }, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;
    // Don't wait - fire and forget
    _ = child.wait() catch {};
}

fn urlEncode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(c);
        } else if (c == ' ') {
            try out.append('+');
        } else {
            try out.writer().print("%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice();
}
