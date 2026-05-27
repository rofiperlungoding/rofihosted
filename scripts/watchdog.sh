#!/data/data/com.termux/files/usr/bin/sh
# hp-server + cloudflared watchdog. Runs as a long-lived process.
# Restarts hp-server if pgrep fails, restarts cloudflared if pgrep fails OR
# if hp-server's tunnel-health watchdog wrote ~/data/.tunnel-restart-requested.
#
# Run via:
#   setsid nohup ~/watchdog.sh > ~/logs/watchdog.log 2>&1 < /dev/null &
#
# Or have ~/.termux/boot/01-server.sh launch it after the main services.

set -u
LOG=~/logs/watchdog.log
mkdir -p ~/logs ~/data

# Ensure PREFIX is set even if started from a context where Termux's profile
# wasn't sourced (boot scripts, manual setsid, etc).
: "${PREFIX:=/data/data/com.termux/files/usr}"
export PREFIX

# Load env (auth + Mistral + telegram tokens) so child inherits them.
if [ -f ~/.hp-server.env ]; then
  set -a
  . ~/.hp-server.env
  set +a
fi

CHECK_INTERVAL=30
RESTART_FLAG=~/data/.tunnel-restart-requested
HEALTH_URL="http://127.0.0.1:8080/health"
# Hard cap on hp-server RSS in MB. Beyond this, restart proactively before
# Android's OOM killer terminates us. Snapdragon 720G phones with 8GB usually
# tolerate up to ~200MB without scrutiny; 384MB gives room for any normal
# spike but catches anything pathological.
MAX_RSS_MB=384
# Consecutive HTTP failures before treating server as dead.
HTTP_FAIL_THRESHOLD=3
http_fail_streak=0

log() { printf '[watchdog %s] %s\n' "$(date +%H:%M:%S)" "$*" >> "$LOG"; }

# Returns RSS in MB for the first hp-server PID, or "0" if not running.
hp_rss_mb() {
  local pid
  pid=$(pgrep -f 'hp-server$' 2>/dev/null | head -1)
  if [ -z "$pid" ] || [ ! -r "/proc/$pid/status" ]; then
    echo 0
    return
  fi
  awk '/^VmRSS:/ {print int($2/1024); exit}' "/proc/$pid/status"
}

# 0 if /health responds 200 within timeout, 1 otherwise.
hp_http_ok() {
  curl -fsS -m 5 -o /dev/null "$HEALTH_URL" 2>/dev/null
}

start_hp_server() {
  pkill -f 'hp-server$' 2>/dev/null || true
  sleep 1
  setsid nohup ~/zig/hp-server/zig-out/bin/hp-server \
    >> ~/logs/hp-server.log 2>&1 < /dev/null &
  log "started hp-server (pid hint: $!)"
}

start_cloudflared() {
  pkill -f 'cloudflared.*tunnel' 2>/dev/null || true
  sleep 2
  if [ -f ~/.cloudflared/config.yml ]; then
    setsid nohup proot \
      -b "$PREFIX/etc/resolv.conf:/etc/resolv.conf" \
      -b "$PREFIX/etc/tls/cert.pem:/etc/ssl/certs/ca-certificates.crt" \
      -b "$PREFIX/etc/tls/cert.pem:/etc/ssl/cert.pem" \
      cloudflared tunnel --no-autoupdate --edge-ip-version 4 run \
      >> ~/logs/cloudflared.log 2>&1 < /dev/null &
    log "started cloudflared NAMED tunnel"
  fi
}

log "watchdog booted, interval=${CHECK_INTERVAL}s, max_rss=${MAX_RSS_MB}MB, http_check=on"

while true; do
  # 1. hp-server liveness (process)
  if ! pgrep -f 'hp-server$' > /dev/null 2>&1; then
    log "hp-server NOT running, restarting"
    start_hp_server
    http_fail_streak=0
    sleep "$CHECK_INTERVAL"
    continue
  fi

  # 2. hp-server liveness (HTTP). Detects deadlocks / hangs that pgrep misses.
  if hp_http_ok; then
    http_fail_streak=0
  else
    http_fail_streak=$((http_fail_streak + 1))
    log "hp-server /health failed (streak=$http_fail_streak)"
    if [ "$http_fail_streak" -ge "$HTTP_FAIL_THRESHOLD" ]; then
      log "hp-server hung past threshold, force-restarting"
      start_hp_server
      http_fail_streak=0
    fi
  fi

  # 3. hp-server RAM ceiling. Self-restart before Android OOM kills us.
  rss=$(hp_rss_mb)
  if [ "$rss" -gt "$MAX_RSS_MB" ]; then
    log "hp-server RSS=${rss}MB > ${MAX_RSS_MB}MB, restarting before OOM killer"
    # SIGTERM first so writebuf flushes; start_hp_server will pkill -SIGKILL fallback.
    pkill -SIGTERM -f 'hp-server$' 2>/dev/null || true
    sleep 3
    start_hp_server
    http_fail_streak=0
  fi

  # 4. cloudflared liveness
  if ! pgrep -f 'cloudflared.*tunnel' > /dev/null 2>&1; then
    log "cloudflared NOT running, restarting"
    start_cloudflared
  fi

  # 5. Tunnel restart flag from hp-server's own health watchdog
  if [ -f "$RESTART_FLAG" ]; then
    log "tunnel-restart flag present, restarting cloudflared"
    rm -f "$RESTART_FLAG"
    start_cloudflared
  fi

  sleep "$CHECK_INTERVAL"
done
