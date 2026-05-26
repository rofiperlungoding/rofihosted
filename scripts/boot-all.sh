#!/data/data/com.termux/files/usr/bin/sh
# Master boot script - auto-start all services on Termux boot
# Symlinked to ~/.termux/boot/01-server.sh

LOG=~/logs/boot.log
mkdir -p ~/logs
exec >> "$LOG" 2>&1
echo ""
echo "==================================="
echo "[boot] starting at $(date)"
echo "==================================="

# Load auth creds (HP_AUTH_USER, HP_AUTH_PASS)
[ -f ~/.hp-server.env ] && . ~/.hp-server.env

# Wake lock biar gak ke-kill android
termux-wake-lock
echo "[boot] wake lock acquired"

# 1. SSH server
if ! pgrep -x sshd > /dev/null; then
  sshd && echo "[boot] sshd started"
else
  echo "[boot] sshd already running"
fi

# 2. hp-server (Zig binary)
if ! pgrep -f 'hp-server$' > /dev/null; then
  setsid nohup ~/zig/hp-server/zig-out/bin/hp-server > ~/logs/hp-server.log 2>&1 < /dev/null &
  echo "[boot] hp-server (Zig) started"
else
  echo "[boot] hp-server already running"
fi

# 3. Cloudflare Tunnel - prefer named tunnel if config.yml exists
if ! pgrep -f 'cloudflared.*tunnel' > /dev/null; then
  if [ -f ~/.cloudflared/config.yml ]; then
    # Named tunnel (stable, multi-subdomain)
    setsid nohup proot \
      -b $PREFIX/etc/resolv.conf:/etc/resolv.conf \
      -b $PREFIX/etc/tls/cert.pem:/etc/ssl/certs/ca-certificates.crt \
      -b $PREFIX/etc/tls/cert.pem:/etc/ssl/cert.pem \
      cloudflared tunnel --no-autoupdate --edge-ip-version 4 run \
      > ~/logs/cloudflared.log 2>&1 < /dev/null &
    echo "[boot] cloudflared NAMED tunnel starting"
  else
    # Quick tunnel fallback
    setsid nohup proot \
      -b $PREFIX/etc/resolv.conf:/etc/resolv.conf \
      -b $PREFIX/etc/tls/cert.pem:/etc/ssl/certs/ca-certificates.crt \
      -b $PREFIX/etc/tls/cert.pem:/etc/ssl/cert.pem \
      cloudflared tunnel --no-autoupdate --edge-ip-version 4 \
      --url http://localhost:8080 > ~/logs/cloudflared.log 2>&1 < /dev/null &
    echo "[boot] cloudflared QUICK tunnel starting (no config.yml yet)"
  fi
fi

echo "[boot] services kicked at $(date)"
