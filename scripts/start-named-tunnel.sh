#!/data/data/com.termux/files/usr/bin/sh
# Start the named cloudflare tunnel using config.yml
mkdir -p ~/logs
pkill -f 'cloudflared.*tunnel' 2>/dev/null
sleep 2

setsid nohup proot \
  -b $PREFIX/etc/resolv.conf:/etc/resolv.conf \
  -b $PREFIX/etc/tls/cert.pem:/etc/ssl/certs/ca-certificates.crt \
  -b $PREFIX/etc/tls/cert.pem:/etc/ssl/cert.pem \
  cloudflared tunnel --no-autoupdate --edge-ip-version 4 run \
  > ~/logs/cloudflared.log 2>&1 < /dev/null &
disown 2>/dev/null || true

sleep 8
echo "=== cloudflared log ==="
tail -25 ~/logs/cloudflared.log
echo
echo "=== procs ==="
pgrep -af cloudflared | head -5
