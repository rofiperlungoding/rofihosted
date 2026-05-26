#!/data/data/com.termux/files/usr/bin/sh
set -e
TUNNEL_NAME="hp-server"

cf() {
  proot \
    -b $PREFIX/etc/resolv.conf:/etc/resolv.conf \
    -b $PREFIX/etc/tls/cert.pem:/etc/ssl/certs/ca-certificates.crt \
    -b $PREFIX/etc/tls/cert.pem:/etc/ssl/cert.pem \
    cloudflared "$@"
}

# Stop any running cloudflared
pkill -f 'cloudflared.*tunnel' 2>/dev/null || true
sleep 2

# Delete old tunnel (--force in case routes still attached)
echo "[+] deleting old tunnel..."
cf tunnel delete --force "$TUNNEL_NAME" 2>&1 | tail -3 || true

# Create fresh - this generates the credentials JSON locally
echo "[+] creating fresh tunnel..."
cf tunnel create "$TUNNEL_NAME"

TUNNEL_ID=$(cf tunnel list 2>/dev/null | awk -v n="$TUNNEL_NAME" '$2==n {print $1}' | head -1)
echo "[+] new tunnel ID: $TUNNEL_ID"

# Verify JSON exists
ls -la ~/.cloudflared/${TUNNEL_ID}.json

# Update config.yml with new tunnel ID
cat > ~/.cloudflared/config.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: /data/data/com.termux/files/home/.cloudflared/${TUNNEL_ID}.json
no-autoupdate: true

ingress:
  - hostname: rofihosted.space
    service: http://localhost:8080
  - hostname: dashboard.rofihosted.space
    service: http://localhost:8080
  - hostname: status.rofihosted.space
    service: http://localhost:8080
  - hostname: api.rofihosted.space
    service: http://localhost:8080
  - hostname: files.rofihosted.space
    service: http://localhost:8080
  - service: http_status:404
EOF
echo "[+] config.yml updated"

# Re-route subdomain DNS (CNAMEs need updating to new tunnel ID)
for HOST in dashboard.rofihosted.space status.rofihosted.space api.rofihosted.space files.rofihosted.space; do
  echo "[+] re-routing $HOST"
  cf tunnel route dns --overwrite-dns "$TUNNEL_NAME" "$HOST" 2>&1 | tail -1 || true
done

# Try root once more
echo "[+] trying root domain (delete old A record first)..."
cf tunnel route dns --overwrite-dns "$TUNNEL_NAME" rofihosted.space 2>&1 | tail -1 || true

echo "[+] DONE"
