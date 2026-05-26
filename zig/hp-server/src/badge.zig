//! Generate SVG status badges (shields.io-style) without external service.
const std = @import("std");

pub const Style = enum { up, down, unknown };

/// Render a 2-segment SVG badge: label | message.
pub fn render(allocator: std.mem.Allocator, label: []const u8, message: []const u8, style: Style) ![]u8 {
    // Approximate width based on chars (6.5px per char + 10px padding each side)
    const label_w: u32 = @intCast(label.len * 7 + 14);
    const msg_w: u32 = @intCast(message.len * 7 + 14);
    const total_w = label_w + msg_w;

    const right_color = switch (style) {
        .up => "#3fb950", // green
        .down => "#f85149", // red
        .unknown => "#8b949e", // gray
    };

    return std.fmt.allocPrint(allocator,
        \\<svg xmlns="http://www.w3.org/2000/svg" width="{d}" height="20" role="img" aria-label="{s}: {s}">
        \\  <linearGradient id="g" x2="0" y2="100%">
        \\    <stop offset="0" stop-color="#bbb" stop-opacity=".1"/>
        \\    <stop offset="1" stop-opacity=".1"/>
        \\  </linearGradient>
        \\  <clipPath id="r"><rect width="{d}" height="20" rx="3" fill="#fff"/></clipPath>
        \\  <g clip-path="url(#r)">
        \\    <rect width="{d}" height="20" fill="#555"/>
        \\    <rect x="{d}" width="{d}" height="20" fill="{s}"/>
        \\    <rect width="{d}" height="20" fill="url(#g)"/>
        \\  </g>
        \\  <g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11">
        \\    <text x="{d}" y="15" fill="#010101" fill-opacity=".3">{s}</text>
        \\    <text x="{d}" y="14">{s}</text>
        \\    <text x="{d}" y="15" fill="#010101" fill-opacity=".3">{s}</text>
        \\    <text x="{d}" y="14">{s}</text>
        \\  </g>
        \\</svg>
    , .{
        total_w,    label,         message,
        total_w,    label_w,       label_w,
        msg_w,      right_color,   total_w,
        label_w / 2, label,        label_w / 2, label,
        label_w + msg_w / 2, message, label_w + msg_w / 2, message,
    });
}
