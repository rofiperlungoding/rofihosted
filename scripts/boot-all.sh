#!/data/data/com.termux/files/usr/bin/sh
# Master boot script - auto-start all services on Termux boot.
# Symlinked or copied to ~/.termux/boot/01-server.sh.
#
# Recovery contract: this script must be idempotent (safe to re-run) and must
# never block forever. Every external dependency has a timeout so a partial
# failure (e.g. WiFi stuck) doesn't deadlock the recovery chain.

LOG=~/logs/boot.log
mkdir -p ~/logs
exec >> "$LOG" 2>&1
echo ""
echo "==================================="
echo "[boot] starting at $(date)"
echo "==================================="

# Load env (HP_AUTH_*, MISTRAL_API_KEY, BACKUP_PASSPHRASE, optional TG_*)
if [ -f ~/.hp-server.env ]; then
  set -a
  . ~/.hp-server.env
  set +a
fi

# Wake lock so Android does not kill background services. Acquire FIRST so
# we survive any radio negotiation that follows.
termux-wake-lock
echo "[boot] wake lock acquired"

# Wait for the radio + WiFi to actually have an Internet route. Without this
# guard, cloudflared spawns before DNS is reachable, fails to register the
# tunnel, and the watchdog ends up looping a stuck process for minutes.
#
# We probe Cloudflare's public resolver (1.1.1.1) since cloudflared is going
# to need to talk to Cloudflare anyway. Max wait is 90 seconds; after that
# we proceed regardless and let the watchdog handle the retry path. ping is
# bionic-busybox in Termux which lacks -W on some builds, so we fall back to
# a curl probe.
wait_for_network() {
  i=0
  while [ "$i" -lt 90 ]; do
    if curl -sm 4 -o /dev/null https://1.1.1.1/ 2>/dev/null; then
      echo "[boot] network ready after ${i}s"
      return 0
    fi
    i=$((i + 3))
    sleep 3
  done
  echo "[boot] network NOT ready after 90s; spawning cloudflared anyway (watchdog will retry)"
  return 1
}
wait_for_network

# 1. SSH server (LAN only; doesn't need internet)
if ! pgrep -x sshd > /dev/null; then
  sshd && echo "[boot] sshd started"
else
  echo "[boot] sshd already running"
fi

# 2. hp-server (Zig binary). Watchdog is responsible for keeping it alive.
if ! pgrep -f 'hp-server$' > /dev/null; then
  setsid nohup ~/zig/hp-server/zig-out/bin/hp-server > ~/logs/hp-server.log 2>&1 < /dev/null &
  echo "[boot] hp-server started"
else
  echo "[boot] hp-server already running"
fi

# 3. Cloudflare Tunnel
if ! pgrep -f 'cloudflared.*tunnel' > /dev/null; then
  if [ -f ~/.cloudflared/config.yml ]; then
    setsid nohup proot \
      -b "$PREFIX/etc/tls/cert.pem:/etc/ssl/certs/ca-certificates.crt" \
      -b "$PREFIX/etc/tls/cert.pem:/etc/ssl/cert.pem" \
      cloudflared tunnel --no-autoupdate --edge-ip-version 4 run \
      > ~/logs/cloudflared.log 2>&1 < /dev/null &
    echo "[boot] cloudflared NAMED tunnel starting"
  else
    setsid nohup proot \
      -b "$PREFIX/etc/tls/cert.pem:/etc/ssl/certs/ca-certificates.crt" \
      -b "$PREFIX/etc/tls/cert.pem:/etc/ssl/cert.pem" \
      cloudflared tunnel --no-autoupdate --edge-ip-version 4 \
      --url http://localhost:8080 > ~/logs/cloudflared.log 2>&1 < /dev/null &
    echo "[boot] cloudflared QUICK tunnel starting"
  fi
fi

# 4. Watchdog (long-lived, restarts services if they die). Spawned LAST so
# the things it watches (hp-server, cloudflared) are already up.
if ! pgrep -f 'watchdog\.sh' > /dev/null; then
  if [ -x ~/watchdog.sh ]; then
    setsid nohup ~/watchdog.sh > ~/logs/watchdog.log 2>&1 < /dev/null &
    echo "[boot] watchdog started"
  fi
fi

# 5. Daily backup at 03:00 (handled by separate cron-like loop or termux-job-scheduler)
# Trigger a one-shot backup at boot if BACKUP_PASSPHRASE is set
if [ -n "${BACKUP_PASSPHRASE:-}" ] && [ -x ~/backup.sh ]; then
  setsid nohup ~/backup.sh > ~/logs/backup.log 2>&1 < /dev/null &
  echo "[boot] one-shot backup scheduled"
fi

echo "[boot] services kicked at $(date)"

# 6. Telegram boot notification (optional, only if TG_BOT_TOKEN + TG_CHAT_ID set).
# Sends the operator a "rofihosted booted" message so they know cold-boot
# recovery is in flight without having to refresh the dashboard. The send is
# done in the background so a network blip doesn't slow the boot down.
if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
  (
    # Wait up to 30s for /health to come up so we can include uptime in the
    # message; if it takes longer we send anyway.
    j=0
    while [ "$j" -lt 30 ]; do
      if curl -sm 3 -o /dev/null http://127.0.0.1:8080/health 2>/dev/null; then
        break
      fi
      j=$((j + 2))
      sleep 2
    done
    BOOT_TIME=$(date '+%H:%M:%S %Z')
    HOST=$(getprop ro.product.model 2>/dev/null || echo 'phone')
    MSG="rofihosted booted on ${HOST} at ${BOOT_TIME}. hp-server, cloudflared, watchdog kicked. /health: $(curl -sm 3 http://127.0.0.1:8080/health 2>/dev/null || echo 'pending')"
    curl -sm 10 -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TG_CHAT_ID}" \
      --data-urlencode "text=${MSG}" > /dev/null 2>&1 \
      && echo "[boot] telegram notif sent" \
      || echo "[boot] telegram notif failed (network?)"
  ) &
fi
