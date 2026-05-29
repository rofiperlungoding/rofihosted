#!/usr/bin/env node
// rh - rofihosted command line interface.
//
// Talks to https://app.rofihosted.space using an API key (admin scope).
// Configure once with `rh login` (interactive) or by setting env vars:
//   ROFIHOSTED_API_KEY    your X-API-Key value
//   ROFIHOSTED_BASE       optional override (default https://app.rofihosted.space)
//
// Commands:
//   rh login              prompt for and save API key to ~/.rofihosted/config.json
//   rh whoami             show key name and id
//   rh status             show hp-server vitals (battery, mem, uptime, version)
//   rh update             pull latest commit and rebuild on the phone
//   rh power              show charger status
//   rh backup [--r2]      trigger a backup (local or local+R2)
//   rh deploy <dir> <sub> upload a directory as a static project
//                         creates the project if subdomain not yet claimed
//   rh logs <subdomain>   tail recent build + runtime logs
//   rh ls                 list all projects with status

import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import readline from 'node:readline/promises';
import { stdin as input, stdout as output } from 'node:process';
import { createReadStream } from 'node:fs';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileP = promisify(execFile);

const CONFIG_DIR = path.join(os.homedir(), '.rofihosted');
const CONFIG_PATH = path.join(CONFIG_DIR, 'config.json');
const DEFAULT_BASE = 'https://app.rofihosted.space';

async function loadConfig() {
  try {
    const raw = await fs.readFile(CONFIG_PATH, 'utf8');
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

async function saveConfig(cfg) {
  await fs.mkdir(CONFIG_DIR, { recursive: true });
  await fs.writeFile(CONFIG_PATH, JSON.stringify(cfg, null, 2), { mode: 0o600 });
}

function getCreds(cfg) {
  const apiKey = process.env.ROFIHOSTED_API_KEY || cfg.api_key;
  const base = process.env.ROFIHOSTED_BASE || cfg.base || DEFAULT_BASE;
  return { apiKey, base };
}

function fail(msg, code = 1) {
  console.error(`rh: ${msg}`);
  process.exit(code);
}

function ok(msg) {
  console.log(`OK ${msg}`);
}

async function api(base, apiKey, path, opts = {}) {
  const headers = { 'X-API-Key': apiKey, ...(opts.headers || {}) };
  const res = await fetch(`${base}${path}`, { ...opts, headers });
  const text = await res.text();
  let body;
  try { body = JSON.parse(text); } catch { body = { raw: text }; }
  if (!res.ok && res.status !== 200) {
    const err = body.err || `HTTP ${res.status}`;
    throw new Error(`${path}: ${err}`);
  }
  return body;
}

// ---- commands ----

async function cmdLogin() {
  const rl = readline.createInterface({ input, output });
  console.log(`Configure rofihosted CLI.`);
  console.log(`Get an admin-scoped API key from https://app.rofihosted.space/security`);
  console.log(`(Click "New API key", check the admin scope, copy the value.)`);
  console.log();
  const apiKey = (await rl.question('API key: ')).trim();
  const baseRaw = (await rl.question(`Base URL [${DEFAULT_BASE}]: `)).trim();
  const base = baseRaw || DEFAULT_BASE;
  rl.close();
  if (!apiKey) fail('empty API key');

  // Verify by calling /v1/whoami
  try {
    const me = await api(base, apiKey, '/v1/whoami');
    if (!me.ok) throw new Error(me.err || 'verify failed');
    await saveConfig({ api_key: apiKey, base });
    ok(`saved ${CONFIG_PATH} (key="${me.name}")`);
  } catch (e) {
    fail(`could not verify: ${e.message}`);
  }
}

async function cmdWhoami({ base, apiKey }) {
  const j = await api(base, apiKey, '/v1/whoami');
  console.log(JSON.stringify(j, null, 2));
}

async function cmdStatus({ base, apiKey }) {
  const [info, power, version] = await Promise.all([
    api(base, apiKey, '/v1/system/info'),
    api(base, apiKey, '/v1/system/power'),
    api(base, apiKey, '/v1/system/version'),
  ]);
  const memUsedMb = Math.round((info.mem_total_kb - info.mem_avail_kb) / 1024);
  const memTotalMb = Math.round(info.mem_total_kb / 1024);
  const days = Math.floor(info.system_uptime_s / 86400);
  const hours = Math.floor((info.system_uptime_s % 86400) / 3600);
  console.log();
  console.log(`hp-server status`);
  console.log(`  version    ${version.local_sha} ${version.up_to_date ? '(up to date)' : `(behind ${version.remote_sha})`}`);
  console.log(`  binary     built ${new Date(version.binary_built_unix * 1000).toLocaleString()}`);
  console.log(`  battery    ${power.percentage}% ${power.status}${power.is_plugged ? '' : ' [WARN: charger off]'}`);
  console.log(`  memory     ${memUsedMb} / ${memTotalMb} MB`);
  console.log(`  disk       ${(info.disk_free_mb / 1024).toFixed(1)} / ${(info.disk_total_mb / 1024).toFixed(1)} GB free`);
  console.log(`  uptime     ${days}d ${hours}h`);
  console.log();
}

async function cmdUpdate({ base, apiKey }) {
  console.log(`Triggering /v1/system/update on ${base}...`);
  console.log(`(this can take 30-90s for full rebuilds; Cloudflare may 524 mid-build but the phone keeps working)`);
  try {
    const j = await api(base, apiKey, '/v1/system/update', { method: 'POST', signal: AbortSignal.timeout(240000) });
    if (j.reason === 'already_up_to_date') {
      ok(`already at ${j.head}`);
    } else if (j.status === 'no_restart_needed') {
      ok(`updated ${j.before} -> ${j.after} (no restart, scripts only)`);
    } else if (j.ok) {
      ok(`updated ${j.before} -> ${j.after} (hp-server is restarting)`);
    } else {
      fail(j.err || 'update failed');
    }
  } catch (e) {
    // Cloudflare 524 (origin timeout) and aborted/closed connections are
    // common when rebuild takes >100s. The phone keeps working in the
    // background, so verify by polling /v1/system/version until either
    // (a) version moves forward, or (b) we time out at 4 minutes.
    const isTimeout = e.message.includes('524') ||
                      e.message.includes('terminated') ||
                      e.message.includes('aborted') ||
                      e.message.includes('TimeoutError') ||
                      e.message.includes('UND_ERR');
    if (isTimeout) {
      console.log(`Connection lost mid-build (this is normal). Polling for new version...`);
      // Read the starting version once for comparison
      let startSha = '';
      try {
        const v = await api(base, apiKey, '/v1/system/version');
        startSha = v.local_sha || '';
      } catch {}
      for (let i = 0; i < 48; i++) {  // 4 minutes
        await new Promise(r => setTimeout(r, 5000));
        try {
          const v = await api(base, apiKey, '/v1/system/version');
          if (v.ok && v.local_sha && v.local_sha !== startSha) {
            ok(`updated to ${v.local_sha}: ${v.local_subject}`);
            return;
          }
          // Also accept if the binary mtime is fresh (within last 3 min)
          const ageS = Math.floor(Date.now() / 1000) - (v.binary_built_unix || 0);
          if (v.ok && ageS < 180) {
            ok(`updated, binary built ${ageS}s ago at ${v.local_sha}`);
            return;
          }
        } catch {}
      }
      fail('hp-server did not advance within 4 minutes');
    } else {
      fail(e.message);
    }
  }
}

async function cmdPower({ base, apiKey }) {
  const j = await api(base, apiKey, '/v1/system/power');
  console.log(JSON.stringify(j, null, 2));
}

async function cmdBackup({ base, apiKey }, args) {
  const r2 = args.includes('--r2');
  const target = r2 ? 'r2' : 'local';
  console.log(`Triggering /v1/system/backup?target=${target}...`);
  const j = await api(base, apiKey, `/v1/system/backup?target=${target}`, { method: 'POST' });
  console.log(JSON.stringify(j, null, 2));
}

// ---- deploy: zip a dir, claim subdomain if needed, upload ----

async function makeZip(dir) {
  // Use system 'zip' or 'tar' to build a zipfile in temp.
  const tmpZip = path.join(os.tmpdir(), `rh-deploy-${Date.now()}.zip`);
  // Try `zip -r` first, fall back to `7z`, fall back to PowerShell's
  // Compress-Archive (built in on Windows).
  try {
    await execFileP('zip', ['-rq', tmpZip, '.'], { cwd: dir });
    return tmpZip;
  } catch {}
  try {
    await execFileP('7z', ['a', '-tzip', tmpZip, `${dir}/*`]);
    return tmpZip;
  } catch {}
  if (process.platform === 'win32') {
    try {
      // Compress-Archive resolves cwd via the current shell, so pass an
      // absolute path.
      const absDir = path.resolve(dir);
      await execFileP('powershell', [
        '-NoProfile',
        '-Command',
        `Compress-Archive -Path '${absDir}\\*' -DestinationPath '${tmpZip}' -Force`,
      ]);
      return tmpZip;
    } catch (e) {
      fail(`PowerShell Compress-Archive failed: ${e.message}`);
    }
  }
  fail(`cannot build zip: install 'zip' (linux/mac) or '7z' (windows)`);
}

async function detectRuntime(dir) {
  // Quick heuristics. Mirrors zig/hp-server/src/detect.zig but lighter.
  // Returns { runtime, install_cmd, build_cmd, start_cmd, publish_dir, hint }.
  const has = async (p) => !!(await fs.stat(path.join(dir, p)).catch(() => null));

  if (await has('package.json')) {
    const pkgRaw = await fs.readFile(path.join(dir, 'package.json'), 'utf8');
    let pkg = {};
    try { pkg = JSON.parse(pkgRaw); } catch {}
    const deps = { ...(pkg.dependencies || {}), ...(pkg.devDependencies || {}) };
    const scripts = pkg.scripts || {};
    const installer = (await has('pnpm-lock.yaml')) ? 'pnpm install --frozen-lockfile'
      : (await has('yarn.lock')) ? 'yarn install --frozen-lockfile'
      : (await has('bun.lockb')) ? 'bun install'
      : 'npm ci';
    const runner = (await has('bun.lockb')) ? 'bun run' : (await has('pnpm-lock.yaml')) ? 'pnpm' : (await has('yarn.lock')) ? 'yarn' : 'npm run';

    // SPA frameworks - static output
    if (deps['vite'] || deps['@vitejs/plugin-react']) {
      return {
        runtime: 'static',
        install_cmd: installer,
        build_cmd: `${runner} build`,
        start_cmd: '',
        publish_dir: 'dist',
        hint: 'Vite (build to dist/)',
      };
    }
    if (deps['astro']) {
      return { runtime: 'static', install_cmd: installer, build_cmd: `${runner} build`, start_cmd: '', publish_dir: 'dist', hint: 'Astro' };
    }
    if (deps['react-scripts']) {
      return { runtime: 'static', install_cmd: installer, build_cmd: `${runner} build`, start_cmd: '', publish_dir: 'build', hint: 'Create React App' };
    }
    // SSR / Node servers
    if (deps['next']) {
      return { runtime: 'node', install_cmd: installer, build_cmd: `${runner} build`, start_cmd: `${runner} start`, publish_dir: '', hint: 'Next.js' };
    }
    if (deps['express'] || deps['fastify'] || deps['hono'] || deps['koa']) {
      return {
        runtime: 'node',
        install_cmd: installer,
        build_cmd: scripts.build ? `${runner} build` : '',
        start_cmd: scripts.start ? `${runner} start` : 'node index.js',
        publish_dir: '',
        hint: 'Node server (Express/Fastify/Hono)',
      };
    }
    if (scripts.start) {
      return {
        runtime: 'node',
        install_cmd: installer,
        build_cmd: scripts.build ? `${runner} build` : '',
        start_cmd: `${runner} start`,
        publish_dir: '',
        hint: 'generic Node project (npm start)',
      };
    }
    // Plain index.html with package.json
    if (await has('index.html')) {
      return { runtime: 'static', install_cmd: installer, build_cmd: scripts.build ? `${runner} build` : '', start_cmd: '', publish_dir: '', hint: 'static index.html' };
    }
    return { runtime: 'node', install_cmd: installer, build_cmd: '', start_cmd: '', publish_dir: '', hint: 'generic Node, please set start_cmd' };
  }

  if (await has('requirements.txt') || await has('pyproject.toml') || await has('Pipfile')) {
    const installer = (await has('Pipfile')) ? 'pipenv install'
      : (await has('pyproject.toml')) ? 'pip install --user -e .'
      : 'pip install --user -r requirements.txt';
    let start = 'python3 main.py';
    if (await has('app.py')) start = 'python3 app.py';
    if (await has('main.py') && !(await has('app.py'))) start = 'python3 main.py';
    return { runtime: 'python', install_cmd: installer, build_cmd: '', start_cmd: start, publish_dir: '', hint: 'Python (PORT env var injected)' };
  }

  if (await has('index.html')) {
    return { runtime: 'static', install_cmd: '', build_cmd: '', start_cmd: '', publish_dir: '', hint: 'plain HTML' };
  }

  return { runtime: 'static', install_cmd: '', build_cmd: '', start_cmd: '', publish_dir: '', hint: 'unknown, default to static' };
}

async function cmdDeploy({ base, apiKey }, args) {
  // Parse args: rh deploy <dir> <sub> [--detect|--static]
  const positional = args.filter(a => !a.startsWith('--'));
  const flags = args.filter(a => a.startsWith('--'));
  const [dir, sub] = positional;
  if (!dir || !sub) fail('usage: rh deploy <directory> <subdomain> [--detect|--static]');

  const stat = await fs.stat(dir).catch(() => null);
  if (!stat || !stat.isDirectory()) fail(`not a directory: ${dir}`);

  // Default to detection if neither flag given
  const forceStatic = flags.includes('--static');
  const detected = await detectRuntime(dir);
  if (!forceStatic) {
    console.log(`Detected: ${detected.hint} (runtime=${detected.runtime})`);
  } else {
    detected.runtime = 'static';
    detected.install_cmd = '';
    detected.build_cmd = '';
    detected.start_cmd = '';
    detected.publish_dir = '';
  }

  // Look up project by subdomain
  const list = await api(base, apiKey, '/v1/projects');
  let project = (list.projects || []).find(p => p.subdomain === sub);

  if (!project) {
    console.log(`Creating new ${detected.runtime} project '${sub}'...`);
    const fd = new URLSearchParams();
    fd.set('name', sub);
    fd.set('subdomain', sub);
    fd.set('runtime', detected.runtime);
    if (detected.install_cmd) fd.set('install_cmd', detected.install_cmd);
    if (detected.build_cmd) fd.set('build_cmd', detected.build_cmd);
    if (detected.start_cmd) fd.set('start_cmd', detected.start_cmd);
    if (detected.publish_dir) fd.set('publish_dir', detected.publish_dir);
    const created = await api(base, apiKey, '/v1/projects/create', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: fd.toString(),
    });
    if (!created.ok) fail(`create failed: ${created.err}`);
    project = { id: created.id, subdomain: sub, runtime: detected.runtime };
    ok(`created project ${created.id}`);
  } else {
    console.log(`Using existing project ${project.id} (${project.runtime})`);
  }

  // For non-static projects we need a real build pipeline. The /v1/projects/upload
  // endpoint only works for static (it skips install + build). Bail with a hint.
  if (project.runtime !== 'static') {
    console.log();
    console.log(`This project is ${project.runtime}, not static.`);
    console.log(`'rh deploy' over zip-upload only handles static sites.`);
    console.log(`For ${project.runtime} projects, push your code to a git repo and trigger /v1/projects/deploy:`);
    console.log(`  rh deploy-from-repo <subdomain>          # to be implemented`);
    console.log();
    console.log(`Or set repo_url + branch via the dashboard, then click Redeploy.`);
    fail('non-static deploy not supported via zip upload');
  }

  console.log(`Zipping ${dir}...`);
  const zipPath = await makeZip(dir);
  const zipBuf = await fs.readFile(zipPath);
  await fs.unlink(zipPath).catch(() => {});

  console.log(`Uploading ${(zipBuf.length / 1024).toFixed(1)} KB to /v1/projects/upload?id=${project.id}...`);
  const res = await fetch(`${base}/v1/projects/upload?id=${project.id}`, {
    method: 'POST',
    headers: {
      'X-API-Key': apiKey,
      'Content-Type': 'application/zip',
    },
    body: zipBuf,
  });
  const j = await res.json();
  if (!j.ok) fail(`upload failed: ${j.err || JSON.stringify(j)}`);
  ok(`deployed: https://${sub}.rofihosted.space`);
}

async function cmdLs({ base, apiKey }) {
  const j = await api(base, apiKey, '/v1/projects');
  if (!j.ok) fail(j.err || 'list failed');
  const projects = j.projects || [];
  if (projects.length === 0) {
    console.log('No projects yet.');
    return;
  }
  console.log();
  // Pad columns
  const w = (s, n) => String(s).padEnd(n);
  console.log(`${w('ID', 18)}${w('SUBDOMAIN', 24)}${w('RUNTIME', 10)}${w('STATUS', 12)}NAME`);
  console.log('-'.repeat(80));
  for (const p of projects) {
    console.log(`${w(p.id.slice(0, 16), 18)}${w(p.subdomain, 24)}${w(p.runtime, 10)}${w(p.status, 12)}${p.name}`);
  }
  console.log();
}

async function cmdLogs({ base, apiKey }, [sub]) {
  if (!sub) fail('usage: rh logs <subdomain>');
  const list = await api(base, apiKey, '/v1/projects');
  const project = (list.projects || []).find(p => p.subdomain === sub);
  if (!project) fail(`no project with subdomain '${sub}'`);

  console.log(`=== build log ===`);
  const build = await api(base, apiKey, `/v1/projects/logs?id=${project.id}`);
  console.log(build.log || '(empty)');
  console.log();
  console.log(`=== runtime log ===`);
  const runtime = await api(base, apiKey, `/v1/projects/runtime-logs?id=${project.id}`);
  console.log(runtime.log || '(empty)');
}

// ---- new commands: secrets, sql, lifecycle, exec, blocklist, mcp ----

async function findProject(base, apiKey, sub) {
  const list = await api(base, apiKey, '/v1/projects');
  const project = (list.projects || []).find(p => p.subdomain === sub || p.id === sub);
  if (!project) fail(`no project matches '${sub}' (by subdomain or id)`);
  return project;
}

function form(obj) {
  const fd = new URLSearchParams();
  for (const [k, v] of Object.entries(obj)) {
    if (v !== undefined && v !== null) fd.set(k, String(v));
  }
  return {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: fd.toString(),
  };
}

async function cmdSecret({ base, apiKey }, args) {
  const [action, sub, key, ...rest] = args;
  if (!action || !['set', 'get', 'list', 'ls', 'rm', 'delete'].includes(action)) {
    fail('usage: rh secret <set|get|list|rm> <subdomain> [key] [value]');
  }
  if (!sub) fail('subdomain required');
  const project = await findProject(base, apiKey, sub);

  if (action === 'list' || action === 'ls') {
    const j = await api(base, apiKey, `/api/projects/secrets/list?id=${project.id}`);
    if (!j.ok) fail(j.err || 'list failed');
    const keys = j.keys || [];
    if (keys.length === 0) {
      console.log('(empty)');
      return;
    }
    console.log(`${keys.length} secret(s):`);
    for (const k of keys) console.log(`  ${k}`);
    return;
  }

  if (!key) fail(`key required for ${action}`);

  if (action === 'set') {
    let value = rest.join(' ');
    if (!value) {
      // Read from stdin if value not given on cli
      const rl = readline.createInterface({ input, output, terminal: false });
      value = (await rl.question(`${key}=`)).trim();
      rl.close();
    }
    if (!value) fail('empty value');
    const j = await api(base, apiKey, '/api/projects/secrets/set', {
      method: 'POST',
      ...form({ project_id: project.id, key, value }),
    });
    if (!j.ok) fail(j.err || 'set failed');
    ok(`set ${key} on ${project.subdomain} (restart project for env to apply)`);
    return;
  }

  if (action === 'rm' || action === 'delete') {
    const j = await api(base, apiKey, '/api/projects/secrets/delete', {
      method: 'POST',
      ...form({ project_id: project.id, key }),
    });
    if (!j.ok) fail(j.err || 'delete failed');
    ok(`removed ${key}`);
    return;
  }

  if (action === 'get') {
    fail(`secret values are write-only (decrypted only into the running process). Use 'rh secret list' to see keys.`);
  }
}

async function cmdSql({ base, apiKey }, args) {
  const [sub, ...rest] = args;
  if (!sub) fail('usage: rh sql <subdomain> "<query>"');
  const project = await findProject(base, apiKey, sub);
  const sqlText = rest.join(' ').trim();
  if (!sqlText) fail('empty SQL');
  const j = await api(base, apiKey, '/api/projects/sql', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ project_id: project.id, sql: sqlText }),
  });
  if (j.output) {
    console.log(j.output);
  } else {
    console.log(JSON.stringify(j, null, 2));
  }
}

async function cmdProjectAction({ base, apiKey }, args, action) {
  const [sub] = args;
  if (!sub) fail(`usage: rh ${action} <subdomain>`);
  const project = await findProject(base, apiKey, sub);
  const path = `/api/projects/${action}`;
  const j = await api(base, apiKey, path, {
    method: 'POST',
    ...form({ id: project.id }),
  });
  if (!j.ok) fail(j.err || `${action} failed`);
  ok(`${action} ${project.subdomain}`);
}

async function cmdRedeploy({ base, apiKey }, args) {
  const [sub] = args;
  if (!sub) fail('usage: rh redeploy <subdomain>');
  const project = await findProject(base, apiKey, sub);
  const j = await api(base, apiKey, '/v1/projects/deploy', {
    method: 'POST',
    ...form({ id: project.id }),
  });
  if (!j.ok) fail(j.err || 'deploy failed');
  ok(`deploy started for ${project.subdomain}. Tail with: rh logs ${project.subdomain}`);
}

async function cmdTail({ base, apiKey }, args) {
  const [sub, kind = 'runtime'] = args;
  if (!sub) fail('usage: rh tail <subdomain> [runtime|build]');
  const project = await findProject(base, apiKey, sub);
  const which = kind === 'build' ? 'logs' : 'runtime-logs';
  console.log(`Tailing ${kind} log for ${project.subdomain}. Ctrl-C to stop.`);
  let lastSize = 0;
  while (true) {
    try {
      const j = await api(base, apiKey, `/v1/projects/${which}?id=${project.id}`);
      const log = j.log || '';
      if (log.length > lastSize) {
        process.stdout.write(log.slice(lastSize));
        lastSize = log.length;
      }
    } catch (e) {
      console.error(`(poll error: ${e.message})`);
    }
    await new Promise(r => setTimeout(r, 2000));
  }
}

async function cmdExec({ base, apiKey }, args) {
  const cmd = args.join(' ').trim();
  if (!cmd) fail('usage: rh exec "<shell command>"');
  const j = await api(base, apiKey, '/api/system/exec', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ cmd, timeout_ms: 60000 }),
  });
  if (j.stdout) process.stdout.write(j.stdout);
  if (j.stderr) process.stderr.write(j.stderr);
  if (j.timed_out) console.error('rh: command timed out');
  process.exit(j.exit_code === undefined ? 0 : j.exit_code);
}

async function cmdBan({ base, apiKey }, args) {
  const [sub, ...reasonParts] = args;
  if (!sub) fail('usage: rh ban <ip> [reason...]');
  const reason = reasonParts.join(' ') || 'manual via rh CLI';
  const j = await api(base, apiKey, '/api/security/block', {
    method: 'POST',
    ...form({ ip: sub, reason }),
  });
  if (!j.ok) fail(j.err || 'block failed');
  ok(`blocked ${sub}`);
}

async function cmdUnban({ base, apiKey }, args) {
  const [ip] = args;
  if (!ip) fail('usage: rh unban <ip>');
  const j = await api(base, apiKey, '/api/security/unblock', {
    method: 'POST',
    ...form({ ip }),
  });
  if (!j.ok) fail(j.err || 'unblock failed');
  ok(`unblocked ${ip}`);
}

async function cmdMcpConfig({ base }) {
  // Print snippets for popular MCP clients.
  console.log();
  console.log('=== Claude Desktop / claude_desktop_config.json ===');
  console.log(JSON.stringify({
    mcpServers: {
      rofihosted: {
        url: `${base}/mcp`,
        transport: 'streamable-http',
        headers: { Authorization: 'Bearer ${ROFIHOSTED_API_KEY}' },
      },
    },
  }, null, 2));
  console.log();
  console.log('=== Kiro / Cursor / continuum (similar pattern) ===');
  console.log('Add to your MCP servers list:');
  console.log(`  url:        ${base}/mcp`);
  console.log(`  transport:  streamable-http`);
  console.log(`  auth:       Bearer <admin-scoped api key>`);
  console.log();
  console.log('Discovery doc: ' + base + '/.well-known/mcp.json');
  console.log();
}

// ---- main ----

async function main() {
  const [cmd, ...args] = process.argv.slice(2);

  if (!cmd || cmd === 'help' || cmd === '--help' || cmd === '-h') {
    console.log(`rh - rofihosted CLI`);
    console.log();
    console.log(`Account & system:`);
    console.log(`  rh login                       save API key (interactive)`);
    console.log(`  rh whoami                      show current API key identity`);
    console.log(`  rh status                      hp-server vitals`);
    console.log(`  rh power                       charger and battery status`);
    console.log(`  rh update                      pull latest commit and rebuild`);
    console.log(`  rh backup [--r2]               trigger a backup`);
    console.log(`  rh exec "<cmd>"                run an arbitrary shell command on the phone`);
    console.log();
    console.log(`Projects:`);
    console.log(`  rh ls                          list all projects`);
    console.log(`  rh deploy <dir> <sub>          zip and upload as static project`);
    console.log(`  rh redeploy <sub>              re-clone the repo and rebuild`);
    console.log(`  rh start <sub>                 start a project`);
    console.log(`  rh stop <sub>                  stop a project`);
    console.log(`  rh restart <sub>               stop then start with grace`);
    console.log(`  rh logs <sub>                  show build + runtime logs once`);
    console.log(`  rh tail <sub> [runtime|build]  follow the runtime/build log live`);
    console.log();
    console.log(`Secrets and database:`);
    console.log(`  rh secret list <sub>           list secret keys`);
    console.log(`  rh secret set <sub> <key> [v]  set a secret (prompts if v omitted)`);
    console.log(`  rh secret rm <sub> <key>       remove a secret`);
    console.log(`  rh sql <sub> "<query>"         run SQL against the project's SQLite DB`);
    console.log();
    console.log(`Security:`);
    console.log(`  rh ban <ip> [reason]           manually block an IP`);
    console.log(`  rh unban <ip>                  remove an IP from the blocklist`);
    console.log();
    console.log(`MCP integration:`);
    console.log(`  rh mcp                         print config snippets for Claude/Kiro/Cursor`);
    console.log();
    console.log(`config: ~/.rofihosted/config.json or env ROFIHOSTED_API_KEY`);
    process.exit(0);
  }

  if (cmd === 'login') {
    await cmdLogin();
    return;
  }

  const cfg = await loadConfig();
  const creds = getCreds(cfg);
  if (!creds.apiKey) {
    fail('not logged in. run: rh login');
  }

  const handlers = {
    whoami: cmdWhoami,
    status: cmdStatus,
    update: cmdUpdate,
    power: cmdPower,
    backup: cmdBackup,
    deploy: cmdDeploy,
    ls: cmdLs,
    logs: cmdLogs,
    tail: cmdTail,
    secret: cmdSecret,
    sql: cmdSql,
    redeploy: cmdRedeploy,
    start: (creds, args) => cmdProjectAction(creds, args, 'start'),
    stop: (creds, args) => cmdProjectAction(creds, args, 'stop'),
    restart: (creds, args) => cmdProjectAction(creds, args, 'restart'),
    exec: cmdExec,
    ban: cmdBan,
    unban: cmdUnban,
    mcp: cmdMcpConfig,
  };
  const handler = handlers[cmd];
  if (!handler) fail(`unknown command: ${cmd}. Run 'rh help' for the list.`);
  await handler(creds, args);
}

main().catch((e) => {
  fail(e.message || String(e));
});
