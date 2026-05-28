//! Framework / runtime auto-detection. Given a working directory (a fresh
//! shallow clone or unpacked zip), infer:
//!   - runtime (static / node / python / bun / generic)
//!   - install_cmd, build_cmd, start_cmd
//!   - publish_dir for static-output frameworks
//!   - framework_hint string (free text shown to operator)
//!
//! Detection rules (priority order):
//!   1. `package.json` exists -> node-ish
//!      a. has script `dev` and `build` and dep `next` -> Next.js (backend)
//!      b. has script `build` and dep `vite` -> Vite SPA (static, dist/)
//!      c. has script `build` and dep `astro` -> Astro (static, dist/)
//!      d. has script `build` and dep one of [react-scripts] -> CRA (static, build/)
//!      e. has script `start` but no build -> plain Node server (backend)
//!      f. just a static index.html exists at root with package.json -> static
//!   2. `bun.lock` or `bun.lockb` -> bun runtime, prefer bun commands
//!   3. `Pipfile` or `pyproject.toml` or `requirements.txt` -> python (backend)
//!   4. plain `index.html` at root, no package.json -> static, no build
//!   5. fallback -> generic, prompt the operator
//!
//! All detection is best-effort. Operator can override on the wizard screen.

const std = @import("std");

pub const Suggestion = struct {
    runtime: []const u8, // "static" | "node" | "python" | "bun" | "generic"
    install_cmd: []const u8,
    build_cmd: []const u8,
    start_cmd: []const u8,
    publish_dir: []const u8,
    framework_hint: []const u8,
};

/// Inspect `dir` and return a Suggestion. All strings are owned by `arena` so
/// the caller doesn't need to free piece by piece.
pub fn detect(arena: std.mem.Allocator, dir: []const u8) !Suggestion {
    const has_pkg_json = fileExists(arena, dir, "package.json") catch false;
    const has_pkg_lock = fileExists(arena, dir, "package-lock.json") catch false;
    const has_yarn_lock = fileExists(arena, dir, "yarn.lock") catch false;
    const has_pnpm_lock = fileExists(arena, dir, "pnpm-lock.yaml") catch false;
    const has_bun_lock = fileExists(arena, dir, "bun.lockb") catch (fileExists(arena, dir, "bun.lock") catch false);
    const has_index_html = fileExists(arena, dir, "index.html") catch false;
    const has_pipfile = fileExists(arena, dir, "Pipfile") catch false;
    const has_pyproject = fileExists(arena, dir, "pyproject.toml") catch false;
    const has_requirements = fileExists(arena, dir, "requirements.txt") catch false;
    const has_app_py = fileExists(arena, dir, "app.py") catch (fileExists(arena, dir, "main.py") catch false);

    if (has_pkg_json) {
        const empty_pkg: []const u8 = "";
        const pkg: []const u8 = readFileTo(arena, dir, "package.json", 256 * 1024) catch empty_pkg;
        const has_next = std.mem.indexOf(u8, pkg, "\"next\"") != null;
        const has_vite = std.mem.indexOf(u8, pkg, "\"vite\"") != null;
        const has_astro = std.mem.indexOf(u8, pkg, "\"astro\"") != null;
        const has_cra = std.mem.indexOf(u8, pkg, "\"react-scripts\"") != null;
        const has_remix = std.mem.indexOf(u8, pkg, "\"@remix-run/dev\"") != null;
        const has_sveltekit = std.mem.indexOf(u8, pkg, "\"@sveltejs/kit\"") != null;
        const has_nuxt = std.mem.indexOf(u8, pkg, "\"nuxt\"") != null;
        const has_express = std.mem.indexOf(u8, pkg, "\"express\"") != null;
        const has_fastify = std.mem.indexOf(u8, pkg, "\"fastify\"") != null;
        const has_hono = std.mem.indexOf(u8, pkg, "\"hono\"") != null;
        const has_build_script = std.mem.indexOf(u8, pkg, "\"build\":") != null;
        const has_start_script = std.mem.indexOf(u8, pkg, "\"start\":") != null;

        // Pick package manager
        const installer = if (has_bun_lock) "bun install" else if (has_pnpm_lock) "pnpm install --frozen-lockfile" else if (has_yarn_lock) "yarn install --frozen-lockfile" else if (has_pkg_lock) "npm ci" else "npm install";
        const runner_prefix = if (has_bun_lock) "bun run " else if (has_pnpm_lock) "pnpm " else if (has_yarn_lock) "yarn " else "npm run ";
        const direct_runner = if (has_bun_lock) "bun" else "node";
        const runtime = if (has_bun_lock) "bun" else "node";

        const build_cmd = try std.fmt.allocPrint(arena, "{s}build", .{runner_prefix});

        if (has_next) {
            return .{
                .runtime = runtime,
                .install_cmd = try arena.dupe(u8, installer),
                .build_cmd = build_cmd,
                .start_cmd = try std.fmt.allocPrint(arena, "{s}start -- -p $PORT", .{runner_prefix}),
                .publish_dir = "",
                .framework_hint = "Next.js (backend, listens on $PORT)",
            };
        }
        if (has_nuxt) {
            return .{
                .runtime = runtime,
                .install_cmd = try arena.dupe(u8, installer),
                .build_cmd = build_cmd,
                .start_cmd = try std.fmt.allocPrint(arena, "{s} .output/server/index.mjs", .{direct_runner}),
                .publish_dir = "",
                .framework_hint = "Nuxt (backend SSR)",
            };
        }
        if (has_remix) {
            return .{
                .runtime = runtime,
                .install_cmd = try arena.dupe(u8, installer),
                .build_cmd = build_cmd,
                .start_cmd = try std.fmt.allocPrint(arena, "{s}start", .{runner_prefix}),
                .publish_dir = "",
                .framework_hint = "Remix (backend)",
            };
        }
        if (has_sveltekit) {
            return .{
                .runtime = runtime,
                .install_cmd = try arena.dupe(u8, installer),
                .build_cmd = build_cmd,
                .start_cmd = try std.fmt.allocPrint(arena, "{s} build", .{direct_runner}),
                .publish_dir = "",
                .framework_hint = "SvelteKit (backend by default; switch to static adapter for static)",
            };
        }
        if (has_vite) {
            return .{
                .runtime = "static",
                .install_cmd = try arena.dupe(u8, installer),
                .build_cmd = build_cmd,
                .start_cmd = "",
                .publish_dir = "dist",
                .framework_hint = "Vite (static, publishes dist/)",
            };
        }
        if (has_astro) {
            return .{
                .runtime = "static",
                .install_cmd = try arena.dupe(u8, installer),
                .build_cmd = build_cmd,
                .start_cmd = "",
                .publish_dir = "dist",
                .framework_hint = "Astro (static, publishes dist/)",
            };
        }
        if (has_cra) {
            return .{
                .runtime = "static",
                .install_cmd = try arena.dupe(u8, installer),
                .build_cmd = build_cmd,
                .start_cmd = "",
                .publish_dir = "build",
                .framework_hint = "Create React App (static, publishes build/)",
            };
        }
        // Express / Fastify / Hono / generic Node server
        if (has_express or has_fastify or has_hono or has_start_script) {
            return .{
                .runtime = runtime,
                .install_cmd = try arena.dupe(u8, installer),
                .build_cmd = if (has_build_script) build_cmd else "",
                .start_cmd = if (has_start_script)
                    try std.fmt.allocPrint(arena, "{s}start", .{runner_prefix})
                else
                    try std.fmt.allocPrint(arena, "{s} index.js", .{direct_runner}),
                .publish_dir = "",
                .framework_hint = "Node server (listens on $PORT)",
            };
        }
        // Has package.json but no obvious framework. If there is also an index.html,
        // assume static + maybe-build.
        if (has_index_html) {
            return .{
                .runtime = "static",
                .install_cmd = try arena.dupe(u8, installer),
                .build_cmd = if (has_build_script) build_cmd else "",
                .start_cmd = "",
                .publish_dir = "",
                .framework_hint = "Generic JS project with index.html",
            };
        }
        // Otherwise, generic Node project; let the operator fill in the start command.
        return .{
            .runtime = runtime,
            .install_cmd = try arena.dupe(u8, installer),
            .build_cmd = if (has_build_script) build_cmd else "",
            .start_cmd = if (has_start_script) try std.fmt.allocPrint(arena, "{s}start", .{runner_prefix}) else "",
            .publish_dir = "",
            .framework_hint = "Node project (no obvious framework detected)",
        };
    }

    if (has_pipfile or has_pyproject or has_requirements) {
        const installer: []const u8 = if (has_pipfile)
            "pip install --user pipenv && pipenv install --deploy"
        else if (has_pyproject)
            "pip install --user -e ."
        else
            "pip install --user -r requirements.txt";

        // Try to guess the framework from the entry file
        const empty: []const u8 = "";
        const app_py_content: []const u8 = readFileTo(arena, dir, "app.py", 32 * 1024) catch empty;
        const main_py_content: []const u8 = readFileTo(arena, dir, "main.py", 32 * 1024) catch empty;
        const has_flask = app_py_content.len > 0 and std.mem.indexOf(u8, app_py_content, "Flask") != null;
        const has_fastapi = std.mem.indexOf(u8, main_py_content, "FastAPI") != null or std.mem.indexOf(u8, app_py_content, "FastAPI") != null;

        const start_cmd: []const u8 = if (has_fastapi)
            "uvicorn main:app --host 127.0.0.1 --port $PORT"
        else if (has_flask)
            "python3 app.py"
        else if (has_app_py)
            "python3 app.py"
        else
            "python3 main.py";

        const hint: []const u8 = if (has_fastapi) "FastAPI (uvicorn on $PORT)" else if (has_flask) "Flask (app.py on $PORT)" else "Python project (listens on $PORT)";

        return .{
            .runtime = "python",
            .install_cmd = try arena.dupe(u8, installer),
            .build_cmd = "",
            .start_cmd = try arena.dupe(u8, start_cmd),
            .publish_dir = "",
            .framework_hint = hint,
        };
    }

    // Static-only: index.html at root, no build steps
    if (has_index_html) {
        return .{
            .runtime = "static",
            .install_cmd = "",
            .build_cmd = "",
            .start_cmd = "",
            .publish_dir = "",
            .framework_hint = "Plain static site (index.html at repo root)",
        };
    }

    // Generic fallback
    return .{
        .runtime = "generic",
        .install_cmd = "",
        .build_cmd = "",
        .start_cmd = "",
        .publish_dir = "",
        .framework_hint = "Couldn't auto-detect; fill in commands manually",
    };
}

fn fileExists(arena: std.mem.Allocator, dir: []const u8, name: []const u8) !bool {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn readFileTo(arena: std.mem.Allocator, dir: []const u8, name: []const u8, max: usize) ![]const u8 {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
    const f = std.fs.openFileAbsolute(path, .{}) catch return error.FileNotFound;
    defer f.close();
    return try f.readToEndAlloc(arena, max);
}

/// Suggest a sanitized subdomain from a project name (or repo URL tail).
/// Returns a slice owned by `arena`.
pub fn suggestSubdomain(arena: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = try arena.alloc(u8, raw.len + 1);
    var len: usize = 0;
    var prev_dash = false;
    for (raw) |c| {
        const lc = if (c >= 'A' and c <= 'Z') c + 32 else c;
        const is_alnum = (lc >= 'a' and lc <= 'z') or (lc >= '0' and lc <= '9');
        if (is_alnum) {
            out[len] = lc;
            len += 1;
            prev_dash = false;
        } else if (lc == '-' or lc == '_' or lc == ' ' or lc == '.' or lc == '/') {
            if (!prev_dash and len > 0) {
                out[len] = '-';
                len += 1;
                prev_dash = true;
            }
        }
    }
    // Trim trailing dash
    while (len > 0 and out[len - 1] == '-') len -= 1;
    if (len == 0) {
        out[0] = 'p';
        len = 1;
    }
    if (len > 63) len = 63;
    return out[0..len];
}

/// Extract the trailing path component of a Git URL.
/// "https://github.com/foo/bar" -> "bar"
/// "https://github.com/foo/bar.git" -> "bar"
/// "git@github.com:foo/bar.git" -> "bar"
pub fn nameFromRepo(arena: std.mem.Allocator, url: []const u8) ![]u8 {
    var name: []const u8 = url;
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name = name[i + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, name, ':')) |i| name = name[i + 1 ..];
    if (std.mem.endsWith(u8, name, ".git")) name = name[0 .. name.len - 4];
    if (name.len == 0) return try arena.dupe(u8, "project");
    return try arena.dupe(u8, name);
}

test "suggestSubdomain" {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();
    try std.testing.expectEqualStrings("my-blog", try suggestSubdomain(a, "My Blog"));
    fba.reset();
    try std.testing.expectEqualStrings("foo-bar", try suggestSubdomain(a, "foo_bar"));
    fba.reset();
    try std.testing.expectEqualStrings("hello-world", try suggestSubdomain(a, "Hello.World!"));
    fba.reset();
    try std.testing.expectEqualStrings("p", try suggestSubdomain(a, "!@#$"));
}

test "nameFromRepo" {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();
    try std.testing.expectEqualStrings("bar", try nameFromRepo(a, "https://github.com/foo/bar"));
    fba.reset();
    try std.testing.expectEqualStrings("bar", try nameFromRepo(a, "https://github.com/foo/bar.git"));
    fba.reset();
    try std.testing.expectEqualStrings("bar", try nameFromRepo(a, "git@github.com:foo/bar.git"));
}
