//! Model Context Protocol (MCP) server.
//!
//! Implements the streamable-HTTP transport in stateless mode. Every request
//! is a single POST to /mcp; every response is a single JSON body. We skip
//! the SSE upgrade path (no server-initiated notifications, no streaming
//! output) because every tool call here is a finite synchronous operation
//! that returns within a few seconds.
//!
//! Auth: Authorization: Bearer <api_key>, where the key has the `admin`
//! scope. Same admin keys that work for /v1/system/* are used for /mcp.
//!
//! The tool surface is intentionally close to the existing /v1 and /api
//! endpoints. We don't reimplement business logic - mcp.zig is a thin
//! adapter that converts MCP tools/call requests into calls into the
//! existing managers, then formats the result as MCP content.
//!
//! See: https://modelcontextprotocol.io/specification

const std = @import("std");

pub const PROTOCOL_VERSION = "2025-06-18";
pub const SERVER_NAME = "rofihosted-mcp";
pub const SERVER_VERSION = "1.0.0";

/// Represents one tool that the MCP server exposes.
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// JSON schema string describing the input arguments. Inlined as raw
    /// JSON to avoid building schema objects in code.
    input_schema: []const u8,
};

/// All tools exported by the rofihosted MCP server. The ordering here
/// determines the order shown to the LLM client.
pub const TOOLS = [_]Tool{
    // ---- system ----
    .{
        .name = "get_system_info",
        .description = "Get phone hardware metrics: battery percentage, charger state, free RAM, free disk, uptime, kernel version. Useful when the user asks 'how is the phone doing'.",
        .input_schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "get_version",
        .description = "Get the running hp-server SHA, the latest GitHub commit SHA, when the binary was built, and whether an update is available.",
        .input_schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "trigger_update",
        .description = "Trigger a self-update: git pull from main, rebuild hp-server, SIGTERM the running process so the watchdog respawns the new binary. Returns the operation result. The phone is briefly unreachable (~10s) during the swap.",
        .input_schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "exec_shell",
        .description = "Run an arbitrary shell command on the phone via /api/system/exec. Use sparingly. Output capped at 256KB. Default timeout 60s, max 300s. Requires admin scope.",
        .input_schema =
        \\{"type":"object","properties":{"cmd":{"type":"string","description":"Shell command to run, will be passed to sh -c"},"timeout_ms":{"type":"integer","description":"Timeout in ms, default 60000, max 300000"},"cwd":{"type":"string","description":"Working directory, defaults to home"}},"required":["cmd"],"additionalProperties":false}
        ,
    },

    // ---- projects ----
    .{
        .name = "list_projects",
        .description = "List all deployed projects (id, name, subdomain, runtime, status, RSS limit, last deploy time, repo URL).",
        .input_schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "get_project_status",
        .description = "Get live runtime status for a single project: PID, RSS bytes, port, uptime since last spawn, last kill reason, restart count.",
        .input_schema =
        \\{"type":"object","properties":{"id":{"type":"string","description":"16-hex project ID"}},"required":["id"],"additionalProperties":false}
        ,
    },
    .{
        .name = "start_project",
        .description = "Start a backend project (spawn its start_command process). For static projects, flips status to running.",
        .input_schema =
        \\{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}
        ,
    },
    .{
        .name = "stop_project",
        .description = "Stop a running project (SIGTERM with 5s grace then SIGKILL for backends, status flip for static).",
        .input_schema =
        \\{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}
        ,
    },
    .{
        .name = "restart_project",
        .description = "Restart a project (stop then start with 1.5s grace for TIME_WAIT). Useful after secret changes.",
        .input_schema =
        \\{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}
        ,
    },
    .{
        .name = "deploy_project",
        .description = "Trigger a fresh deploy: git clone + install + build + publish + atomic symlink swap. Async, returns immediately. Tail with read_build_log.",
        .input_schema =
        \\{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}
        ,
    },
    .{
        .name = "read_build_log",
        .description = "Read the tail of a project's build.log (~/data/projects/<id>/logs/build.log). Useful right after deploy_project.",
        .input_schema =
        \\{"type":"object","properties":{"id":{"type":"string"},"lines":{"type":"integer","description":"Number of trailing lines to return, default 200, max 2000"}},"required":["id"],"additionalProperties":false}
        ,
    },
    .{
        .name = "read_runtime_log",
        .description = "Read the tail of a project's runtime.log (stdout+stderr from the running process). Useful for debugging crashes.",
        .input_schema =
        \\{"type":"object","properties":{"id":{"type":"string"},"lines":{"type":"integer","description":"Default 200, max 2000"}},"required":["id"],"additionalProperties":false}
        ,
    },

    // ---- secrets ----
    .{
        .name = "list_secrets",
        .description = "List secret KEYS for a project (values are never returned by this tool).",
        .input_schema =
        \\{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"],"additionalProperties":false}
        ,
    },
    .{
        .name = "set_secret",
        .description = "Set or update a secret in a project's encrypted vault. Value is AES-256-GCM-encrypted at rest. Project must be restarted for changes to take effect.",
        .input_schema =
        \\{"type":"object","properties":{"project_id":{"type":"string"},"key":{"type":"string","description":"Env var name, e.g. DATABASE_URL"},"value":{"type":"string"}},"required":["project_id","key","value"],"additionalProperties":false}
        ,
    },
    .{
        .name = "delete_secret",
        .description = "Remove a secret from a project's vault.",
        .input_schema =
        \\{"type":"object","properties":{"project_id":{"type":"string"},"key":{"type":"string"}},"required":["project_id","key"],"additionalProperties":false}
        ,
    },

    // ---- database ----
    .{
        .name = "query_db",
        .description = "Run a read-only SQL query against a project's SQLite database (~/data/dbs/<project_id>.db). SELECT only - INSERT/UPDATE/DELETE/DDL are rejected at the server.",
        .input_schema =
        \\{"type":"object","properties":{"project_id":{"type":"string"},"sql":{"type":"string","description":"SELECT statement"}},"required":["project_id","sql"],"additionalProperties":false}
        ,
    },
    .{
        .name = "exec_db",
        .description = "Run a write SQL statement (INSERT, UPDATE, DELETE, CREATE TABLE, etc) against a project's SQLite database. Use with care.",
        .input_schema =
        \\{"type":"object","properties":{"project_id":{"type":"string"},"sql":{"type":"string"}},"required":["project_id","sql"],"additionalProperties":false}
        ,
    },
    .{
        .name = "list_tables",
        .description = "List tables in a project's SQLite database with column counts.",
        .input_schema =
        \\{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"],"additionalProperties":false}
        ,
    },

    // ---- security & observability ----
    .{
        .name = "list_blocked_ips",
        .description = "List currently-blocked IPs with their ban reason, blocked_at timestamp, and expiry.",
        .input_schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "block_ip",
        .description = "Manually add an IP to the blocklist. Permanent unless ttl_seconds is provided.",
        .input_schema =
        \\{"type":"object","properties":{"ip":{"type":"string"},"reason":{"type":"string","description":"Free-text annotation"},"ttl_seconds":{"type":"integer","description":"Auto-expire after N seconds; omit for permanent"}},"required":["ip"],"additionalProperties":false}
        ,
    },
    .{
        .name = "unblock_ip",
        .description = "Remove an IP from the blocklist.",
        .input_schema =
        \\{"type":"object","properties":{"ip":{"type":"string"}},"required":["ip"],"additionalProperties":false}
        ,
    },
    .{
        .name = "search_audit",
        .description = "Search the operator audit log (~/data/audit.jsonl). Returns the last `limit` entries matching the optional filter.",
        .input_schema =
        \\{"type":"object","properties":{"limit":{"type":"integer","description":"Max entries, default 50, max 500"},"action_contains":{"type":"string","description":"Filter by action substring, e.g. 'project_'"}},"additionalProperties":false}
        ,
    },
    .{
        .name = "list_recent_visits",
        .description = "Return the most recent N visits with classification, IP, country, path, status. Sourced from the dbcache (visits table).",
        .input_schema =
        \\{"type":"object","properties":{"limit":{"type":"integer","description":"Default 50, max 500"},"classification":{"type":"string","description":"Filter by self/scanner/bot/unknown/blocked"}},"additionalProperties":false}
        ,
    },

    // ---- backups ----
    .{
        .name = "list_backups",
        .description = "List local and R2 backup tarballs with their size and timestamp.",
        .input_schema =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
    },
    .{
        .name = "trigger_backup",
        .description = "Trigger an immediate backup. Target 'local' writes to ~/backups/. Target 'r2' also pushes to Cloudflare R2.",
        .input_schema =
        \\{"type":"object","properties":{"target":{"type":"string","enum":["local","r2"],"description":"local or r2"}},"required":["target"],"additionalProperties":false}
        ,
    },

    // ---- developer experience (Phase 3) ----
    .{
        .name = "auto_deploy",
        .description = "One-click deploy from a public Git repo URL. Server analyzes the repo (AI-augmented when available, deterministic fallback otherwise), derives a subdomain, creates the project, and starts the build. Returns the project_id plus an SSE log_stream URL the caller can subscribe to for live progress.",
        .input_schema =
        \\{"type":"object","properties":{"repo_url":{"type":"string","description":"https://... git URL, no inline credentials"},"branch":{"type":"string","description":"Default branch name; if it does not exist the server falls back to the repo's actual default"},"subdomain_hint":{"type":"string","description":"Preferred subdomain; sanitized + suffixed if necessary"}},"required":["repo_url"],"additionalProperties":false}
        ,
    },
    .{
        .name = "tail_build_log",
        .description = "Read the most recent N lines of a project's build.log and report whether the build has reached a terminal state. Sets complete=true when the tail contains '=== build complete', '=== published', or '=== build failed'.",
        .input_schema =
        \\{"type":"object","properties":{"project_id":{"type":"string"},"max_lines":{"type":"integer","description":"Default 200, max 2000"}},"required":["project_id"],"additionalProperties":false}
        ,
    },
    .{
        .name = "get_db_url",
        .description = "Return the project's effective DATABASE_URL. For db_mode=sqlite the auto-injected file URI is returned. For db_mode=postgres the secret is read from the vault and returned masked (postgres://***:***@host:port/dbname); the raw value is never exposed via this tool.",
        .input_schema =
        \\{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"],"additionalProperties":false}
        ,
    },
    .{
        .name = "set_db_url",
        .description = "Set or clear a project's DATABASE_URL secret and flip db_mode accordingly. A non-empty postgres:// or postgresql:// URL stores the secret and sets db_mode=postgres. An empty or null value clears the secret and reverts to db_mode=sqlite (auto-injected SQLite). The project must be restarted for the change to take effect.",
        .input_schema =
        \\{"type":"object","properties":{"project_id":{"type":"string"},"url":{"type":["string","null"],"description":"postgres URL or empty/null to clear"}},"required":["project_id"],"additionalProperties":false}
        ,
    },
};

/// Build the JSON-RPC `initialize` response body. The caller wraps this
/// into a complete `{"jsonrpc":"2.0","id":...,"result":...}` envelope.
pub fn writeInitializeResult(w: anytype) !void {
    try w.print(
        \\{{"protocolVersion":"{s}","capabilities":{{"tools":{{"listChanged":false}}}},"serverInfo":{{"name":"{s}","version":"{s}"}},"instructions":"rofihosted-mcp exposes tools for managing a self-hosted PaaS running on a phone. Use list_projects to discover what's deployed, get_system_info for hardware health, and the project lifecycle tools (start/stop/restart/deploy) to operate them. Database tools (query_db/exec_db) operate on per-project SQLite databases."}}
    , .{ PROTOCOL_VERSION, SERVER_NAME, SERVER_VERSION });
}

/// Build the JSON-RPC `tools/list` response body.
pub fn writeToolsList(w: anytype) !void {
    try w.writeAll("{\"tools\":[");
    for (TOOLS, 0..) |t, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try writeJsonString(w, t.name);
        try w.writeAll(",\"description\":");
        try writeJsonString(w, t.description);
        try w.writeAll(",\"inputSchema\":");
        try w.writeAll(t.input_schema);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

/// Format a JSON-RPC error envelope. Code follows the JSON-RPC spec
/// (-32700..-32603 for parse/invalid/internal errors, -32000..-32099 for
/// application errors).
pub fn writeError(w: anytype, id_json: []const u8, code: i32, message: []const u8) !void {
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":", .{ id_json, code });
    try writeJsonString(w, message);
    try w.writeAll("}}");
}

/// Format a JSON-RPC success envelope. The result is passed as raw JSON.
pub fn writeResult(w: anytype, id_json: []const u8, result_json: []const u8) !void {
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, result_json });
}

/// Format an MCP `tools/call` result containing a single text block.
/// `content_text` is the human-readable output; if it's already JSON, the
/// LLM client will still treat it as text but parse it on its side.
pub fn writeToolResultText(w: anytype, id_json: []const u8, content_text: []const u8, is_error: bool) !void {
    try w.print(
        \\{{"jsonrpc":"2.0","id":{s},"result":{{"content":[{{"type":"text","text":
    , .{id_json});
    try writeJsonString(w, content_text);
    try w.print("}}],\"isError\":{s}}}}}", .{if (is_error) "true" else "false"});
}

/// Escape a string for JSON output. Handles backslash, quotes, control
/// chars; emits BMP escapes for non-printable ASCII below 0x20. Bytes
/// >= 0x80 are passed through verbatim (we assume UTF-8 sources).
pub fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0C => try w.writeAll("\\f"),
            0x00...0x07, 0x0B, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}
