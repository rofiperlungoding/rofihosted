#!/data/data/com.termux/files/usr/bin/sh
mkdir -p ~/logs

# Load auth creds if set
[ -f ~/.hp-server.env ] && . ~/.hp-server.env

pkill -f 'hp-server' 2>/dev/null
sleep 1
setsid nohup ~/zig/hp-server/zig-out/bin/hp-server > ~/logs/hp-server.log 2>&1 < /dev/null &
disown 2>/dev/null || true
sleep 2

echo "=== LOG ==="
cat ~/logs/hp-server.log
echo "=== PROC ==="
pgrep -af hp-server || echo "(none)"
echo "=== HEALTH ==="
curl -s http://127.0.0.1:8080/health
echo "=== AUTH USER ==="
echo "${HP_AUTH_USER:-admin (default - run ~/set-creds.sh to change)}"
echo "=== MEM USAGE ==="
ps -o pid,rss,cmd -p $(pgrep hp-server | head -1) 2>/dev/null || echo "(can't get rss)"
