#!/data/data/com.termux/files/usr/bin/sh
mkdir -p ~/logs

# Canonical process-match pattern (keep in lockstep with watchdog.sh).
HP_MATCH='zig-out/bin/hp-server'

# Auto-export everything sourced from env file so children inherit it.
if [ -f ~/.hp-server.env ]; then
  set -a
  . ~/.hp-server.env
  set +a
fi

# Reconcile to exactly one instance: terminate every match, wait for the
# flock on ~/.hp-server.pid to release, then start one fresh.
pkill -f "$HP_MATCH" 2>/dev/null
sleep 1
setsid nohup ~/zig/hp-server/zig-out/bin/hp-server > ~/logs/hp-server.log 2>&1 < /dev/null &
disown 2>/dev/null || true
sleep 2

echo "=== LOG ==="
cat ~/logs/hp-server.log
echo "=== PROC ==="
pgrep -af "$HP_MATCH" || echo "(none)"
echo "=== HEALTH ==="
curl -s http://127.0.0.1:8080/health
echo "=== AUTH USER ==="
echo "${HP_AUTH_USER:-admin (default - run ~/set-creds.sh to change)}"
echo "=== AI ==="
[ -n "$MISTRAL_API_KEY" ] && echo "mistral: key loaded (length=${#MISTRAL_API_KEY})" || echo "mistral: no key"
echo "=== MEM USAGE ==="
ps -o pid,rss,cmd -p "$(pgrep -f "$HP_MATCH" | head -1)" 2>/dev/null || echo "(can't get rss)"
