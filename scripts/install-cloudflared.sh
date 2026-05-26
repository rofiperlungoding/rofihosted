#!/data/data/com.termux/files/usr/bin/sh
set -e

if ! command -v cloudflared >/dev/null 2>&1; then
  echo "[cf] downloading cloudflared (arm64)..."
  curl -L --fail -o $PREFIX/bin/cloudflared \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64
  chmod +x $PREFIX/bin/cloudflared
else
  echo "[cf] cloudflared already installed"
fi

cloudflared --version
echo "[cf] ok"
