// Shared app-shell logic for app.rofihosted.space pages.
// Realtime SSE bus + page-level subscribers. No polling.
window.RH = (function () {
  const HIST = 60;
  const cpuHist = [], memHist = [];

  function fmtUptime(secs) {
    if (!secs) return 'restricted';
    const d = Math.floor(secs / 86400),
          h = Math.floor((secs % 86400) / 3600),
          m = Math.floor((secs % 3600) / 60),
          s = secs % 60;
    const parts = [];
    if (d) parts.push(d + 'd');
    if (h || d) parts.push(h + 'h');
    if (m || h || d) parts.push(m + 'm');
    parts.push(s + 's');
    return parts.join(' ');
  }
  function fmtAgo(ts) {
    const ago = Math.floor(Date.now() / 1000 - ts);
    if (ago < 60) return ago + 's ago';
    if (ago < 3600) return Math.floor(ago / 60) + 'm ago';
    if (ago < 86400) return Math.floor(ago / 3600) + 'h ago';
    return Math.floor(ago / 86400) + 'd ago';
  }
  function fmtSize(b) {
    if (b == null) return null;
    if (b < 1024) return b + ' B';
    if (b < 1024*1024) return (b/1024).toFixed(1) + ' KB';
    if (b < 1024*1024*1024) return (b/1024/1024).toFixed(1) + ' MB';
    return (b/1024/1024/1024).toFixed(2) + ' GB';
  }
  // Memory values from /proc come in KIBIBYTES (1 unit = 1024 bytes).
  // Use fmtKB() for those; fmtSize() is for raw byte counts (file sizes, etc).
  function fmtKB(kb) {
    if (kb == null) return null;
    if (kb < 1024) return kb + ' KB';
    if (kb < 1024 * 1024) return (kb / 1024).toFixed(1) + ' MB';
    return (kb / 1024 / 1024).toFixed(2) + ' GB';
  }
  function fmtTime(ts) {
    if (!ts) return '';
    return new Date(ts * 1000).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
  }
  function setText(id, val) { const el = document.getElementById(id); if (el) el.textContent = val; }
  function escapeHtml(s) {
    return (s || '').replace(/[<>&"']/g, function (c) {
      return { '<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;',"'":'&#39;' }[c];
    });
  }

  // --- SSE bus ---
  const listeners = {}; // event_name -> [callback]
  let es = null;
  let backoff = 1000;
  let liveBadgeEl = null;

  function setLiveBadge(state) {
    if (!liveBadgeEl) liveBadgeEl = document.getElementById('ws-status');
    if (!liveBadgeEl) return;
    if (state === 'live') {
      liveBadgeEl.className = 'ws-badge live';
      liveBadgeEl.innerHTML = '<span class="dot"></span> live';
    } else if (state === 'connecting') {
      liveBadgeEl.className = 'ws-badge poll';
      liveBadgeEl.innerHTML = '<span class="dot"></span> connecting';
    } else {
      liveBadgeEl.className = 'ws-badge poll';
      liveBadgeEl.innerHTML = '<span class="dot"></span> offline';
    }
  }

  function emit(event, data) {
    (listeners[event] || []).forEach(function (cb) {
      try { cb(data); } catch (e) { console.error(e); }
    });
  }

  function on(event, cb) {
    if (!listeners[event]) listeners[event] = [];
    listeners[event].push(cb);
  }

  function connect() {
    setLiveBadge('connecting');
    try {
      es = new EventSource('/api/stream');
    } catch (e) {
      setLiveBadge('offline');
      setTimeout(connect, backoff);
      backoff = Math.min(backoff * 2, 15000);
      return;
    }

    es.addEventListener('hello', function () {
      backoff = 1000;
      setLiveBadge('live');
    });
    ['stats_tick', 'visit', 'login_attempt', 'blocklist_change', 'uptime_probe'].forEach(function (name) {
      es.addEventListener(name, function (ev) {
        try { emit(name, JSON.parse(ev.data)); } catch (e) {}
      });
    });

    es.onerror = function () {
      setLiveBadge('offline');
      try { es.close(); } catch (e) {}
      es = null;
      setTimeout(connect, backoff);
      backoff = Math.min(backoff * 2, 15000);
    };
  }

  // --- Stats application (used by overview page) ---
  function barClass(pct, prefix) {
    return pct > 90 ? prefix + ' crit' : pct > 70 ? prefix + ' warn' : prefix;
  }
  function plotChart(svgId, history) {
    if (history.length < 2) return;
    const svg = document.getElementById(svgId);
    if (!svg) return;
    const paths = svg.querySelectorAll('path');
    const w = 100, h = 30;
    const max = Math.max(100, ...history);
    const pts = history.map(function (v, i) {
      const x = (i / (HIST - 1)) * w;
      const y = h - (v / max) * h;
      return [x.toFixed(2), y.toFixed(2)];
    });
    const linePath = pts.map(function (p, i) { return (i === 0 ? 'M' : 'L') + p[0] + ' ' + p[1]; }).join(' ');
    const fillPath = linePath + ' L' + pts[pts.length - 1][0] + ' ' + h + ' L' + pts[0][0] + ' ' + h + ' Z';
    paths[0].setAttribute('d', fillPath);
    paths[1].setAttribute('d', linePath);
  }

  function applyTickToOverview(s) {
    if (s.process) {
      setText('proc-rss', fmtKB(s.process.rss_kb));
      setText('proc-rss-sub', 'virtual ' + fmtKB(s.process.vsz_kb) + ' . uptime ' + fmtUptime(s.process.uptime_seconds));
      setText('proc-vsz', fmtKB(s.process.vsz_kb));
      setText('proc-threads', s.process.threads);
      setText('proc-fds', s.process.open_fds);
    }
    if (s.memory) {
      setText('mem-percent', s.memory.percent.toFixed(1));
      const bar = document.getElementById('mem-bar');
      if (bar) {
        bar.style.width = s.memory.percent + '%';
        bar.parentElement.className = barClass(s.memory.percent, 'bar');
      }
      setText('mem-sub', fmtKB(s.memory.used_kb) + ' of ' + fmtKB(s.memory.total_kb));
      setText('mem-avail', fmtKB(s.memory.available_kb));
      setText('mem-free', fmtKB(s.memory.free_kb));
      setText('mem-cached', fmtKB(s.memory.cached_kb));
      setText('swap-used', fmtKB(s.memory.swap_used_kb));
      setText('swap-free', fmtKB(s.memory.swap_free_kb));
      setText('swap-total', fmtKB(s.memory.swap_total_kb));
      const swapPct = s.memory.swap_total_kb > 0 ? (s.memory.swap_used_kb / s.memory.swap_total_kb * 100) : 0;
      setText('swap-percent', swapPct.toFixed(1));
      const sbar = document.getElementById('swap-bar');
      if (sbar) {
        sbar.style.width = swapPct + '%';
        sbar.parentElement.className = barClass(swapPct, 'bar');
      }
      memHist.push(s.memory.percent);
      if (memHist.length > HIST) memHist.shift();
      plotChart('mem-chart', memHist);
    }
    setText('updated', new Date().toLocaleTimeString());
  }

  // --- One-shot fetchers (initial state load before SSE has anything to push) ---
  async function loadCurrentUser() {
    try {
      const j = await (await fetch('/api/me')).json();
      const el = document.getElementById('cur-user');
      if (el) el.textContent = j.username || 'unknown';
    } catch (e) {}
  }

  async function fetchInitialStats() {
    try {
      const j = await (await fetch('/api/stats')).json();
      // Same shape as stats_tick (plus capabilities)
      applyTickToOverview(j);
      // Capabilities banner (only present in /api/stats, not in tick)
      if (j.capabilities) {
        const caps = j.capabilities;
        const items = [
          ['/proc/meminfo', caps.meminfo],
          ['/proc/self', caps.self_proc],
          ['/proc/stat', caps.global_cpu],
          ['/proc/loadavg', caps.loadavg],
          ['/proc/uptime', caps.global_uptime],
          ['/proc/net/*', caps.net_stats],
        ];
        const root = document.getElementById('caps');
        if (root) {
          root.innerHTML = items.map(function (i) {
            return '<span class="cap ' + (i[1] ? 'on' : 'off') + '"><span class="cap-dot"></span>' + i[0] + ' ' + (i[1] ? 'readable' : 'blocked') + '</span>';
          }).join('');
        }
      }
    } catch (e) {}
  }

  async function fetchHost() {
    try {
      const j = await (await fetch('/api/host')).json();
      const b = j.battery;
      if (b && b.percentage != null) {
        setText('bat-pct', b.percentage);
        const bar = document.getElementById('bat-bar');
        if (bar) {
          bar.style.width = b.percentage + '%';
          bar.parentElement.className = b.percentage < 15 ? 'bar crit' : b.percentage < 30 ? 'bar warn' : 'bar';
        }
        setText('bat-status', (b.status || '?') + ' . ' + (b.health || '?'));
        setText('bat-plugged', b.plugged || '\u2014');
        setText('bat-temp', b.temperature_c != null ? b.temperature_c.toFixed(1) + ' \u00B0C' : '\u2014');
        setText('bat-voltage', b.voltage_mv != null ? b.voltage_mv + ' mV' : '\u2014');
      }
      const w = j.wifi;
      if (w) {
        setText('wifi-ssid', w.ssid || '\u2014');
        setText('wifi-ip', w.ip || '\u2014');
        setText('wifi-speed', w.link_speed_mbps != null ? w.link_speed_mbps : '\u2014');
        setText('wifi-rssi', w.rssi != null ? w.rssi : '\u2014');
      }
    } catch (e) {}
  }

  async function fetchTunnel() {
    try {
      const j = await (await fetch('/api/tunnel')).json();
      const t = j.tunnel;
      if (!t) return;
      setText('tun-connections', t.connections);
      const edges = document.getElementById('tun-edges');
      if (edges) {
        edges.innerHTML = (t.edge_locations || []).map(function (e) {
          return '<span class="edge-badge">' + escapeHtml(e) + '</span>';
        }).join('');
      }
      setText('tun-total', t.total_requests);
      setText('tun-errors', t.request_errors);
      const codesEl = document.getElementById('tun-codes');
      if (codesEl) {
        const sorted = (t.response_codes || []).slice().sort(function (a, b) {
          return parseInt(a.code) - parseInt(b.code);
        });
        codesEl.innerHTML = sorted.map(function (c) {
          return '<span class="code-cell"><span class="code">' + escapeHtml(c.code) + '</span><span class="count">' + c.count + '</span></span>';
        }).join('') || '<span class="code-cell"><span class="count">no data</span></span>';
      }
    } catch (e) {}
  }

  async function loadVisits() {
    try {
      const visits = await (await fetch('/api/visits')).json();
      const root = document.getElementById('visits');
      if (!root) return;
      if (!visits.length) { root.innerHTML = '<div class="empty">No visits yet</div>'; return; }
      root.innerHTML = visits.slice(0, 12).map(renderVisitRow).join('');
    } catch (e) {}
  }
  function renderVisitRow(v) {
    return '<div class="visit-row">'
      + '<span class="ip">' + escapeHtml(v.ip || 'local') + '</span>'
      + '<span class="path">' + escapeHtml(v.path) + '</span>'
      + '<span class="ago">' + fmtAgo(v.visited_at) + '</span>'
      + '</div>';
  }
  function prependVisit(v) {
    const root = document.getElementById('visits');
    if (!root) return;
    if (root.querySelector('.empty')) root.innerHTML = '';
    root.insertAdjacentHTML('afterbegin', renderVisitRow(v));
    // Trim to 12
    const rows = root.querySelectorAll('.visit-row');
    for (let i = 12; i < rows.length; i++) rows[i].remove();
  }

  async function loadStatusPage() {
    try {
      const list = await (await fetch('/api/uptime')).json();
      renderStatus(list);
    } catch (e) {}
  }
  function renderStatus(list) {
    const root = document.getElementById('targets');
    if (!root) return;
    if (!list.length) {
      root.innerHTML = '<div class="empty">No probe data yet, waiting for first check</div>';
      return;
    }
    let ups = 0, downs = 0;
    list.sort(function (a, b) { return a.target.localeCompare(b.target); });
    root.innerHTML = list.map(function (t) {
      if (t.ok) ups++; else downs++;
      const cls = t.ok ? 'up' : 'down';
      return '<div class="target">'
        + '<div class="dot-wrap ' + cls + '"><div class="dot ' + cls + '"></div></div>'
        + '<div class="target-info">'
        + '<div class="name">' + escapeHtml(t.target) + '</div>'
        + '<div class="meta">checked ' + fmtAgo(t.checked_at) + ', ' + (t.ok ? 'operational' : 'unreachable') + '</div>'
        + '</div>'
        + '<span class="code-pill">' + (t.status_code || 'ERR') + '</span>'
        + '<span class="latency">' + t.latency_ms + 'ms</span>'
        + '</div>';
    }).join('');
    setText('ups', ups);
    setText('downs', downs);
    const title = downs === 0 ? 'All systems operational' : (ups === 0 ? 'Major outage' : 'Partial outage');
    setText('hero-title', title);
    setText('hero-sub', 'Probing ' + list.length + ' endpoints every 60 seconds');
  }

  async function loadFiles() {
    const path = new URLSearchParams(location.search).get('path') || '/';
    const crumbs = document.getElementById('crumbs');
    if (crumbs) {
      const parts = path.split('/').filter(Boolean);
      let acc = '';
      let html = '<a href="?path=/">~</a>';
      for (const p of parts) {
        acc += '/' + p;
        html += '<span class="sep">/</span><a href="?path=' + encodeURIComponent(acc) + '">' + escapeHtml(p) + '</a>';
      }
      crumbs.innerHTML = html;
    }
    try {
      const data = await (await fetch('/api/files/list?path=' + encodeURIComponent(path))).json();
      const root = document.getElementById('rows');
      if (!root) return;
      let html = '<div class="file-head"><span>Name</span><span class="size">Size</span><span class="mtime">Modified</span></div>';
      const parent = path === '/' ? null : path.replace(/\/[^/]+$/, '') || '/';
      if (parent !== null) {
        html += '<div class="file-row parent">'
          + '<span class="name"><i class="icon-arrow-up"></i><a href="?path=' + encodeURIComponent(parent) + '">..</a></span>'
          + '<span class="size"></span><span class="mtime"></span>'
          + '</div>';
      }
      if (!data.entries.length) {
        html += '<div class="empty">empty directory</div>';
      } else {
        for (const e of data.entries) {
          const subpath = (path === '/' ? '' : path) + '/' + e.name;
          if (e.is_dir) {
            html += '<div class="file-row">'
              + '<span class="name"><i class="icon-folder dir"></i><a href="?path=' + encodeURIComponent(subpath) + '">' + escapeHtml(e.name) + '/</a></span>'
              + '<span class="size"></span>'
              + '<span class="mtime">' + fmtTime(e.mtime) + '</span>'
              + '</div>';
          } else {
            html += '<div class="file-row">'
              + '<span class="name"><i class="icon-doc"></i><span title="' + escapeHtml(e.name) + '">' + escapeHtml(e.name) + '</span></span>'
              + '<span class="size">' + fmtSize(e.size) + '</span>'
              + '<span class="mtime">' + fmtTime(e.mtime) + '</span>'
              + '</div>';
          }
        }
      }
      root.innerHTML = html;
    } catch (e) {
      const root = document.getElementById('rows');
      if (root) root.innerHTML = '<div class="empty">failed to load</div>';
    }
  }

  // --- Natural-language query bar ---
  // Mounts an "Ask" input into the topbar of every authenticated page.
  function mountQueryBar() {
    const tb = document.querySelector('.topbar-actions');
    if (!tb || document.getElementById('rh-ask')) return;

    const wrap = document.createElement('div');
    wrap.className = 'rh-ask-wrap';
    wrap.innerHTML = ''
      + '<button class="btn-icon rh-ask-btn" id="rh-ask-btn" aria-label="Ask"><i class="icon-magnifier"></i></button>'
      + '<div class="rh-ask-popover" id="rh-ask-popover">'
      +   '<form id="rh-ask-form">'
      +     '<input id="rh-ask" type="text" placeholder="Ask about your server, e.g. \u201Ctop scanners today\u201D" autocomplete="off">'
      +   '</form>'
      +   '<div class="rh-ask-result" id="rh-ask-result"></div>'
      + '</div>';
    tb.insertBefore(wrap, tb.firstChild);

    const input = document.getElementById('rh-ask');
    const popover = document.getElementById('rh-ask-popover');
    const result = document.getElementById('rh-ask-result');
    const btn = document.getElementById('rh-ask-btn');

    btn.addEventListener('click', function (e) {
      e.preventDefault();
      popover.classList.toggle('open');
      if (popover.classList.contains('open')) input.focus();
    });

    document.addEventListener('click', function (e) {
      if (!wrap.contains(e.target)) popover.classList.remove('open');
    });

    document.getElementById('rh-ask-form').addEventListener('submit', async function (e) {
      e.preventDefault();
      const q = input.value.trim();
      if (!q) return;
      result.innerHTML = '<span class="digest-loading">Thinking...</span>';
      try {
        const fd = new FormData();
        fd.append('q', q);
        const r = await fetch('/api/ai/query', { method: 'POST', body: fd });
        const j = await r.json();
        if (!j.ok) {
          result.textContent = 'Could not answer (' + (j.err || 'unknown') + ').';
          return;
        }
        renderQueryResult(result, j);
      } catch (err) {
        result.textContent = 'Network error.';
      }
    });
  }

  // Auto-connect SSE when DOM ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { connect(); mountQueryBar(); });
  } else {
    connect();
    mountQueryBar();
  }

  function renderQueryResult(root, j) {
    const fn = j.function;
    const ex = j.explanation || '';
    const r = j.result || {};
    let body = '';
    if (fn === 'count_visits') {
      body = '<div class="rh-ask-num">' + r.count + '</div><div class="rh-ask-sub">visits in last ' + Math.round((r.since_seconds || 0) / 3600) + 'h</div>';
    } else if (fn === 'list_top') {
      body = '<div class="rh-ask-sub">top ' + escapeHtml(r.field || '') + '</div>';
      if (r.items && r.items.length) {
        body += '<div class="rh-ask-list">';
        for (const it of r.items) body += '<div><span>' + escapeHtml(it.value) + '</span><span class="c">' + it.count + '</span></div>';
        body += '</div>';
      } else {
        body += '<div class="rh-ask-sub">no rows</div>';
      }
    } else if (fn === 'list_failed_logins') {
      body = '<div class="rh-ask-sub">' + (r.items || []).length + ' failed login(s)</div>';
      body += '<div class="rh-ask-list">';
      for (const it of (r.items || [])) {
        body += '<div><span>' + escapeHtml(it.ip) + ' . ' + escapeHtml(it.username) + '</span><span class="c">' + fmtAgo(it.timestamp) + '</span></div>';
      }
      body += '</div>';
    } else if (fn === 'list_blocked_ips') {
      body = '<div class="rh-ask-sub">' + (r.items || []).length + ' blocked</div>';
      body += '<div class="rh-ask-list">';
      for (const it of (r.items || [])) {
        body += '<div><span>' + escapeHtml(it.ip) + '</span><span class="c">' + escapeHtml(it.reason || '') + '</span></div>';
      }
      body += '</div>';
    } else if (fn === 'show_uptime') {
      body = '<div class="rh-ask-sub">' + (r.items || []).length + ' probe(s)</div>';
      body += '<div class="rh-ask-list">';
      for (const it of (r.items || [])) {
        body += '<div><span>' + escapeHtml(it.target) + '</span><span class="c">' + (it.ok ? 'up' : 'down') + ' . ' + it.latency_ms + 'ms</span></div>';
      }
      body += '</div>';
    } else if (fn === 'explain_ip') {
      body = '<div class="rh-ask-sub">opens IP profile for ' + escapeHtml(r.ip || '') + '</div>';
      // Trigger explain modal if function exists on this page
      if (typeof openExplain === 'function' && r.ip) setTimeout(function () { openExplain(r.ip); }, 200);
    } else {
      body = '<div class="rh-ask-sub">cannot answer from server logs</div>';
    }
    root.innerHTML = '<div class="rh-ask-explanation">' + escapeHtml(ex) + '</div>' + body;
  }

  return {
    fmtUptime: fmtUptime, fmtAgo: fmtAgo, fmtSize: fmtSize, fmtKB: fmtKB, fmtTime: fmtTime,
    escapeHtml: escapeHtml, setText: setText, barClass: barClass,
    on: on,
    loadCurrentUser: loadCurrentUser,
    fetchInitialStats: fetchInitialStats,
    fetchHost: fetchHost,
    fetchTunnel: fetchTunnel,
    loadVisits: loadVisits,
    prependVisit: prependVisit,
    loadStatusPage: loadStatusPage,
    renderStatus: renderStatus,
    loadFiles: loadFiles,
    applyTickToOverview: applyTickToOverview,
  };
})();
