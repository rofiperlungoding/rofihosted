#!/data/data/com.termux/files/usr/bin/sh
# Build hp-server on the phone. Wraps in proot to bind Termux's CA cert
# at the standard /etc paths so Zig's package fetcher and TLS libraries work.
# Explicit -Dtarget=aarch64-linux-android avoids Zig 0.14's "FileNotFound …
# falling back to default ABI and dynamic linker" warning being treated as a
# build failure on Termux.
export PREFIX=/data/data/com.termux/files/usr
cd /data/data/com.termux/files/home/zig/hp-server
proot \
  -b $PREFIX/etc/tls/cert.pem:/etc/ssl/certs/ca-certificates.crt \
  -b $PREFIX/etc/tls/cert.pem:/etc/ssl/cert.pem \
  zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseFast 2>&1 | tail -30
echo --- DONE ---
ls -la zig-out/bin/hp-server 2>&1 | tail -1
