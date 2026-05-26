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

# Load env (auth + Mistral + telegram tokens) so child inherits them.
if [ -f ~/.hp-server.env ]; then
  set -a
  . ~/.hp-server.env
  set +a
fi

CHECK_INTERVAL=30
RESTART_FLAG=~/data/.tunnel-restart-requested

log() { printf '[watchdog %s] %s\n' "$(date +%H:%M:%S)" "$*" >> "$LOG"; }

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
      -b "$PREFIX/etc/tls/cert.pem:/etc/ssl/certs/ca-certificates.crt" \
      -b "$PREFIX/etc/tls/cert.pem:/etc/ssl/cert.pem" \
      cloudflared tunnel --no-autoupdate --edge-ip-version 4 run \
      >> ~/logs/cloudflared.log 2>&1 < /dev/null &
    log "started cloudflared NAMED tunnel"
  fi
}

log "watchdog booted, interval=${CHECK_INTERVAL}s"

while true; do
  # 1. hp-server liveness
  if ! pgrep -f 'hp-server$' > /dev/null 2>&1; then
    log "hp-server NOT running, restarting"
    start_hp_server
  fi

  # 2. cloudflared liveness
  if ! pgrep -f 'cloudflared.*tunnel' > /dev/null 2>&1; then
    log "cloudflared NOT running, restarting"
    start_cloudflared
  fi

  # 3. Tunnel restart flag from hp-server's own health watchdog
  if [ -f "$RESTART_FLAG" ]; then
    log "tunnel-restart flag present, restarting cloudflared"
    rm -f "$RESTART_FLAG"
    start_cloudflared
  fi

  sleep "$CHECK_INTERVAL"
done
