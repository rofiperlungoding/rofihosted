#!/usr/bin/env node
// Dev UI preview server. Serves the rofihosted templates + assets locally
// so the operator can iterate on HTML/CSS/JS without rebuilding hp-server
// or waiting for self-update.sh.
//
// Run:
//   node scripts/dev-ui.mjs
//
// Then open:
//   http://localhost:5173/projects     (dashboard)
//   http://localhost:5173/             (public landing)
//   http://localhost:5173/login
//   http://localhost:5173/signup
//   http://localhost:5173/security     (and any other /<page>)

import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { resolve, extname, join } from "node:path";
import { fileURLToPath } from "node:url";

const PORT = process.env.PORT || 5173;
const ROOT = resolve(fileURLToPath(import.meta.url), "..", "..", "zig", "hp-server", "src", "templates");

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".woff2": "font/woff2",
  ".svg": "image/svg+xml",
};

const ROUTES = {
  "/": "public.html",
  "/login": "login.html",
  "/signup": "signup.html",
  "/signup/pending": "signup-pending.html",
  "/projects": "app-projects.html",
  "/security": "app-security.html",
  "/settings": "app-settings.html",
  "/files": "app-files.html",
  "/api": "app-api.html",
  "/status": "app-status.html",
  "/shell": "app-shell.html",
  "/admin/users": "app-admin-users.html",
  "/admin/invites": "app-admin-invites.html",
  "/dashboard": "dashboard.html",
  "/overview": "app-overview.html",
};

const NOW = Math.floor(Date.now() / 1000);

function mockProjects() {
  return [
    { id: "a1b2c3d4e5f60718", name: "my-vite-app", subdomain: "my-vite-app",
      repo_url: "https://github.com/you/my-vite-app", branch: "main", runtime: "static",
      install_cmd: "npm ci", build_cmd: "npm run build", start_cmd: "", publish_dir: "dist",
      webhook_secret: "deadbeef" + "0".repeat(56), port: 0, status: "running",
      owner_id: "u_admin", rss_limit_mb: 0, db_mode: "sqlite",
      created_at: NOW - 86400 * 7, updated_at: NOW - 3600, last_deploy_at: NOW - 3600 },
    { id: "b2c3d4e5f6071829", name: "my-api", subdomain: "my-api",
      repo_url: "https://github.com/you/my-api", branch: "main", runtime: "node",
      install_cmd: "npm ci", build_cmd: "", start_cmd: "node server.js", publish_dir: "",
      webhook_secret: "cafebabe" + "0".repeat(56), port: 3001, status: "running",
      owner_id: "u_admin", rss_limit_mb: 256, db_mode: "postgres",
      created_at: NOW - 86400 * 3, updated_at: NOW - 60, last_deploy_at: NOW - 60 },
    { id: "c3d4e5f607182930", name: "blog", subdomain: "blog",
      repo_url: "", branch: "main", runtime: "static",
      install_cmd: "", build_cmd: "", start_cmd: "", publish_dir: "",
      webhook_secret: "", port: 0, status: "stopped",
      owner_id: "u_admin", rss_limit_mb: 0, db_mode: "sqlite",
      created_at: NOW - 86400 * 30, updated_at: NOW - 86400 * 2, last_deploy_at: NOW - 86400 * 2 },
  ];
}

const API_MOCKS = {
  "/api/me": () => ({ username: "mrofid", user_id: "u_admin", role: "admin", status: "active",
    legacy: true, max_projects: 0, max_rss_mb: 0 }),
  "/api/users": () => ({ ok: true, users: [
    { id: "u_admin", username: "mrofid", email: "rofi@example.com", role: "admin", status: "active",
      created_at: NOW - 86400 * 60, last_login_at: NOW - 3600 },
    { id: "u_alice", username: "alice", email: "alice@example.com", role: "tenant", status: "active",
      created_at: NOW - 86400 * 7, last_login_at: NOW - 7200 },
    { id: "u_bob", username: "bob", email: "bob@example.com", role: "tenant", status: "pending",
      signup_reason: "Building a side project. Want to try self-hosting from a phone.",
      created_at: NOW - 3600 * 5 },
  ] }),
  "/api/projects": () => ({ ok: true, projects: mockProjects() }),
  "/api/stats": () => ({ ok: true,
    process: { rss_kb: 32048, vsz_kb: 156432, threads: 14, open_fds: 42, uptime_seconds: 12345 },
    memory: {
      percent: 36.8,
      total_kb: 7754000, used_kb: 2854000, available_kb: 4900000,
      free_kb: 1200000, cached_kb: 2400000,
      swap_total_kb: 4000000, swap_used_kb: 800000, swap_free_kb: 3200000,
    },
    capabilities: {
      meminfo: true, self_proc: true, global_cpu: false,
      loadavg: false, global_uptime: true, net_stats: false,
    } }),
  "/api/host": () => ({ ok: true,
    battery_percent: 90, battery_status: "charging", battery_temp_c: 28.4, battery_voltage_mv: 4180,
    is_plugged: true,
    wifi_ssid: "rofi-home-2.4", wifi_ip: "192.168.100.69",
    wifi_signal_dbm: -52, wifi_link_speed_mbps: 144 }),
  "/api/tunnel": () => ({ ok: true,
    cloudflared_tunnel_ha_connections: 4,
    cloudflared_tunnel_request_errors: 0,
    cloudflared_tunnel_total_requests: 18372,
    edges: ["sin01", "sin02", "kul01", "hkg03"],
    response_codes: { "200": 17890, "302": 240, "404": 158, "403": 84 } }),
  "/api/tunnel/health": () => ({ ok: true, state: "healthy", since_unix: NOW - 1800 }),
  "/api/visits": () => ({ ok: true, visits: [
    { ts: NOW - 12, ip: "203.0.113.42", country: "ID", host: "app.rofihosted.space",
      method: "GET", path: "/projects", status: 200, ua: "Mozilla/5.0", classification: "self" },
    { ts: NOW - 28, ip: "198.51.100.5", country: "US", host: "rofihosted.space",
      method: "GET", path: "/", status: 200, ua: "Mozilla/5.0", classification: "unknown" },
    { ts: NOW - 47, ip: "192.0.2.99", country: "CN", host: "app.rofihosted.space",
      method: "GET", path: "/.env", status: 403, ua: "curl/7.81", classification: "scanner" },
  ] }),
  "/api/uptime": () => ({ ok: true, targets: [
    { name: "self", url: "http://127.0.0.1:8080/health", up: true, latency_ms: 1, last_check: NOW - 5 },
    { name: "1.1.1.1", url: "https://1.1.1.1", up: true, latency_ms: 24, last_check: NOW - 30 },
  ] }),
  "/api/security": () => ({ ok: true,
    summary: { total_visits_24h: 12453, scanner_hits_24h: 287, blocked_24h: 12, failed_logins_24h: 3 },
    blocklist: [{ ip: "192.0.2.99", reason: "auto: scanner threshold", blocked_at: NOW - 3600, expires_at: NOW + 86400 }],
    top_ips: [
      { ip: "203.0.113.42", count: 4521, country: "ID", classification: "self" },
      { ip: "198.51.100.5", count: 312, country: "US", classification: "unknown" },
    ],
    digest: { ts: NOW - 7200, summary: "Quiet day. 287 scanner hits, all stopped at the firewall." } }),
  "/api/audit": () => ({ ok: true, entries: [
    { timestamp: NOW - 600, actor: "mrofid", action: "project_autodeploy", target: "a1b2c3d4e5f60718",
      detail: "https://github.com/you/my-vite-app", ok: true },
    { timestamp: NOW - 1800, actor: "mrofid", action: "project_create", target: "blog", detail: "", ok: true },
  ] }),
  "/v1/public/stats": () => ({ ok: true, projects: 3, projects_running: 2, requests_24h: 12453,
    uptime_seconds: 12345, uptime_days: 0, total_users: 2, version_short: "dev-ui", battery_percent: 90 }),
  "/v1/system/recovery": () => ({ ok: true, boot_script_present: true, watchdog_script_present: true,
    watchdog_running: true, cloudflared_running: true, boot_log_recent_unix: NOW - 300,
    uptime_seconds: 12345, projects_running: 2, projects_total: 3 }),
  "/api/dbcache/stats": () => ({ ok: true, rows: 70234, last_sync_unix: NOW - 60, last_sync_duration_ms: 142 }),
  "/api/dbpool/stats": () => ({ ok: true, workers: 3, free: 2, total_queries: 5821, errors: 0, respawns: 0, avg_latency_ms: 1.8 }),
  "/api/apikeys": () => ({ ok: true, keys: [{ id: "k_abc", name: "kiro-access", scopes: ["admin"], created_at: NOW - 86400 }] }),
  "/api/webhooks": () => ({ ok: true, webhooks: [] }),
  "/api/rules": () => ({ ok: true, rules: [], counters: {} }),
  "/api/honeypot": () => ({ ok: true, enabled: false }),
  "/api/geoblock": () => ({ ok: true, enabled: false, allowlist: [] }),
  "/api/hosted/list": () => ({ ok: true, sites: [] }),
  "/api/hosted/stats": () => ({ ok: true, sites: {} }),
};

function handleSSE(req, res, kind = "stream") {
  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no",
  });
  res.write(": dev-ui mock\n\n");
  if (kind === "log") {
    const lines = [
      "[clone] git clone --depth=1 https://github.com/you/my-vite-app",
      "[install] npm ci",
      "added 234 packages in 8s",
      "[build] npm run build",
      "vite v5.0.0 building...",
      "build successful in 4.2s",
      "[publish] cp -a dist /releases/2026-05-31T08-00-00",
      "[publish] symlink swap: current -> 2026-05-31T08-00-00",
      "=== build complete",
      "=== published",
    ];
    let i = 0;
    const id = setInterval(() => {
      if (i >= lines.length) {
        res.write("event: end\ndata: done\n\n");
        clearInterval(id);
        res.end();
        return;
      }
      res.write(`data: ${lines[i]}\n\n`);
      i++;
    }, 600);
    req.on("close", () => clearInterval(id));
  } else {
    const id = setInterval(() => res.write(`: heartbeat\n\n`), 5000);
    req.on("close", () => clearInterval(id));
  }
}

function rewriteHtml(buf) {
  return buf.toString("utf8")
    .replace(/https:\/\/rofihosted\.space\//g, "/")
    .replace(/https:\/\/app\.rofihosted\.space\//g, "/");
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const pathname = url.pathname;

  if (pathname === "/health") { res.end("ok\n"); return; }

  if (pathname === "/api/stream") return handleSSE(req, res, "stream");
  if (pathname === "/api/projects/log-stream") return handleSSE(req, res, "log");

  if (API_MOCKS[pathname]) {
    res.setHeader("Content-Type", "application/json; charset=utf-8");
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.end(JSON.stringify(API_MOCKS[pathname]()));
    return;
  }

  if (pathname.startsWith("/api/") || pathname.startsWith("/v1/")) {
    res.setHeader("Content-Type", "application/json; charset=utf-8");
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.end(JSON.stringify({ ok: true, mock: true, path: pathname }));
    return;
  }

  let assetName = null;
  if (pathname === "/theme.css") assetName = "theme.css";
  else if (pathname === "/theme.js") assetName = "theme.js";
  else if (pathname === "/app.css") assetName = "app.css";
  else if (pathname === "/app.js") assetName = "app.js";
  else if (pathname === "/icons.css") assetName = "icons.css";
  else if (pathname === "/fonts/Simple-Line-Icons.woff2") assetName = "Simple-Line-Icons.woff2";

  if (assetName) {
    try {
      const fpath = join(ROOT, assetName);
      const buf = await readFile(fpath);
      res.setHeader("Content-Type", MIME[extname(assetName)] || "application/octet-stream");
      res.setHeader("Cache-Control", "no-store");
      res.end(buf);
    } catch (e) {
      res.statusCode = 404;
      res.end("asset not found: " + assetName);
    }
    return;
  }

  let template = ROUTES[pathname];
  if (!template) {
    const slug = pathname.slice(1).split("/")[0];
    if (slug) {
      const candidate = `app-${slug}.html`;
      try {
        await stat(join(ROOT, candidate));
        template = candidate;
      } catch {}
    }
  }
  if (!template) template = "404.html";

  try {
    const fpath = join(ROOT, template);
    const buf = await readFile(fpath);
    const html = rewriteHtml(buf);
    res.setHeader("Content-Type", "text/html; charset=utf-8");
    res.setHeader("Cache-Control", "no-store");
    res.end(html);
  } catch (e) {
    res.statusCode = 500;
    res.end("template error: " + e.message);
  }
});

server.listen(PORT, () => {
  console.log(``);
  console.log(`rofihosted dev UI preview running at:`);
  console.log(`  http://localhost:${PORT}/             (public landing)`);
  console.log(`  http://localhost:${PORT}/projects     (dashboard, with mock data)`);
  console.log(`  http://localhost:${PORT}/security`);
  console.log(`  http://localhost:${PORT}/settings`);
  console.log(`  http://localhost:${PORT}/login`);
  console.log(`  http://localhost:${PORT}/signup`);
  console.log(``);
  console.log(`Templates served from: ${ROOT}`);
  console.log(`API requests are mocked. Edit any .html / .css / .js file and reload.`);
  console.log(``);
  console.log(`Ctrl+C to stop.`);
});
