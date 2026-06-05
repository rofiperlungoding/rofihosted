pkill -f 'watchdog.sh' 2>/dev/null || true
sleep 1
pkill -TERM -f 'bin/hp-server$' 2>/dev/null || true
sleep 3
pkill -KILL -f 'bin/hp-server$' 2>/dev/null || true
sleep 1
set -a; . "$HOME/.hp-server.env"; set +a
mkdir -p "$HOME/logs"
setsid nohup "$HOME/zig/hp-server/zig-out/bin/hp-server" >> "$HOME/logs/hp-server.log" 2>&1 < /dev/null &
sleep 3
setsid nohup "$HOME/watchdog.sh" > "$HOME/logs/watchdog.log" 2>&1 < /dev/null &
sleep 2
echo "HP_COUNT=$(pgrep -f 'bin/hp-server$' | wc -l)"
echo "WD_COUNT=$(pgrep -f 'watchdog.sh$' | wc -l)"
echo "HEALTH=$(curl -s http://127.0.0.1:8080/health)"
echo "=== boot log tail ==="
tail -6 "$HOME/logs/hp-server.log" 2>/dev/null
