#!/data/data/com.termux/files/usr/bin/sh
# Login to Cloudflare via cloudflared (one-time per device)
# Will print a URL — open it in browser, login, pick domain, authorize.
proot \
  -b $PREFIX/etc/resolv.conf:/etc/resolv.conf \
  -b $PREFIX/etc/tls/cert.pem:/etc/ssl/certs/ca-certificates.crt \
  -b $PREFIX/etc/tls/cert.pem:/etc/ssl/cert.pem \
  cloudflared tunnel login
