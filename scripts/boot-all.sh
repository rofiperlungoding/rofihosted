#!/data/data/com.termux/files/usr/bin/sh
# Master boot script - auto-start all services on Termux boot.
# Symlinked or copied to ~/.termux/boot/01-server.sh.

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

# Wake lock so Android does not kill background services
termux-wake-lock
echo "[boot] wake lock acquired"

# 1. SSH server
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

# 4. Watchdog (long-lived, restarts services if they die)
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
