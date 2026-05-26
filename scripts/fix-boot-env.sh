#!/data/data/com.termux/files/usr/bin/sh
# One-shot patch: rewrite the env-loading block in the Termux:Boot script
# so sourced variables are auto-exported to child processes (hp-server).
set -e
BOOT=~/.termux/boot/01-server.sh
[ -f "$BOOT" ] || { echo "boot script not found at $BOOT"; exit 1; }

# Replace the single-line POSIX source with a set -a / set +a wrapper.
# Idempotent: if already patched, this is a no-op.
if grep -q '^\[ -f ~/.hp-server.env \] && \. ~/.hp-server.env' "$BOOT"; then
  awk '
    /^\[ -f ~\/\.hp-server\.env \] && \. ~\/\.hp-server\.env/ {
      print "if [ -f ~/.hp-server.env ]; then"
      print "  set -a"
      print "  . ~/.hp-server.env"
      print "  set +a"
      print "fi"
      next
    }
    { print }
  ' "$BOOT" > "$BOOT.tmp" && mv "$BOOT.tmp" "$BOOT" && chmod +x "$BOOT"
  echo "patched"
else
  echo "already patched (or pattern not present)"
fi
