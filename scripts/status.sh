#!/data/data/com.termux/files/usr/bin/sh
echo "=== RUNNING SERVICES ==="
printf "%-15s %s\n" "sshd:"        "$(pgrep -c sshd) procs"
printf "%-15s %s\n" "postgres:"    "$(pg_isready 2>&1)"
printf "%-15s %s\n" "redis:"       "$(pgrep -c redis-server) procs"
printf "%-15s %s\n" "nginx:"       "$(pgrep -c nginx) procs"
printf "%-15s %s\n" "node-api:"    "$(pgrep -af 'node.*server.js' | head -1 || echo none)"
printf "%-15s %s\n" "cloudflared:" "$(pgrep -af cloudflared | head -1 | cut -c1-60 || echo none)"
echo
echo "=== TUNNEL URL ==="
grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' ~/logs/cloudflared.log | head -1
echo
echo "=== MEMORY ==="
free -h | head -2
echo
echo "=== STORAGE (Termux data) ==="
df -h $PREFIX | tail -1
echo
echo "=== LOAD ==="
uptime
