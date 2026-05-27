#!/data/data/com.termux/files/usr/bin/sh
# Add wildcard DNS route to the tunnel so any *.rofihosted.space resolves.
# Run via proot so cloudflared has access to /etc/resolv.conf and TLS roots.
set -e

PREFIX_DIR="/data/data/com.termux/files/usr"

proot \
  -b "$PREFIX_DIR/etc/resolv.conf:/etc/resolv.conf" \
  -b "$PREFIX_DIR/etc/tls/cert.pem:/etc/ssl/certs/ca-certificates.crt" \
  -b "$PREFIX_DIR/etc/tls/cert.pem:/etc/ssl/cert.pem" \
  cloudflared tunnel route dns hp-server "*.rofihosted.space"
