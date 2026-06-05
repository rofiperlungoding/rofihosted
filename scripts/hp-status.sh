#!/data/data/com.termux/files/usr/bin/sh
# hp-status.sh - live one-screen status, printed on every interactive SSH
# login (wired via ~/.bash_profile). Read-only: it inspects, never changes
# state, and every external probe has a short timeout so login never hangs.
#
# Source of truth lives in the repo at scripts/hp-status.sh; the on-phone copy
# is ~/hp-status.sh. Keep them in sync.

# ---- tiny helpers ---------------------------------------------------------
# Colors only when stdout is a terminal; plain text otherwise (logs, pipes).
if [ -t 1 ]; then
  G='\033[32m'; R='\033[31m'; Y='\033[33m'; D='\033[2m'; B='\033[1m'; X='\033[0m'
else
  G=''; R=''; Y=''; D=''; B=''; X=''
fi

up()   { printf "${G}up${X}"; }
down() { printf "${R}DOWN${X}"; }

# Is a process whose command line matches $1 alive?
alive() { pgrep -f "$1" >/dev/null 2>&1; }

# RSS (MB) of the first PID matching $1, or "-".
rss_mb() {
  pid=$(pgrep -f "$1" 2>/dev/null | head -1)
  [ -n "$pid" ] && [ -r "/proc/$pid/status" ] || { printf '-'; return; }
  awk '/^VmRSS:/ {printf "%d", int($2/1024); exit}' "/proc/$pid/status"
}

HOME_DIR="${HOME:-/data/data/com.termux/files/home}"

# Elapsed run time of the process matching $1, as procps formats it
# (e.g. 1-02:03:04 or 05:12). Android/SELinux blocks /proc/uptime for the
# Termux UID, but a same-UID process's own /proc entry is readable, so we
# derive uptime from the hp-server process itself - which is what we care
# about anyway ("how long has the server been up").
proc_uptime() {
  pid=$(pgrep -f "$1" 2>/dev/null | head -1)
  [ -n "$pid" ] || { printf '-'; return; }
  ps -o etime= -p "$pid" 2>/dev/null | tr -d ' '
}

# ---- header ---------------------------------------------------------------
MODEL=$(getprop ro.product.model 2>/dev/null || echo phone)
IP=$(ifconfig 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | head -1)
[ -z "$IP" ] && IP='?'
UPTIME=$(proc_uptime 'zig-out/bin/hp-server')

printf "\n${B}HP-SERVER${X} ${D}%s${X}  ${D}@${X} %s:8022  ${D}server up${X} %s\n" "$MODEL" "$IP" "$UPTIME"
printf "${D}--------------------------------------------------------${X}\n"

# ---- services -------------------------------------------------------------
printf "  hp-server   "
if alive 'zig-out/bin/hp-server'; then printf "%b ${D}(%s MB)${X}" "$(up)" "$(rss_mb 'zig-out/bin/hp-server')"; else printf "%b" "$(down)"; fi
# Liveness via HTTP, not just pgrep, to catch hangs.
if curl -fsS -m 2 -o /dev/null http://127.0.0.1:8080/health 2>/dev/null; then
  printf "  ${D}/health${X} %b\n" "$(up)"
else
  printf "  ${D}/health${X} %b\n" "$(down)"
fi

printf "  cloudflared "
if alive 'cloudflared.*tunnel'; then printf "%b" "$(up)"; else printf "%b" "$(down)"; fi
# Tunnel connected? ha_connections>0 from cloudflared's metrics endpoint.
HA=$(curl -fsS -m 2 http://127.0.0.1:20241/metrics 2>/dev/null | awk '/^cloudflared_tunnel_ha_connections / {print int($2); exit}')
if [ -n "$HA" ] && [ "$HA" -gt 0 ] 2>/dev/null; then
  printf "  ${D}tunnel${X} %bconnected (%s)${X}\n" "$G" "$HA"
else
  printf "  ${D}tunnel${X} ${Y}not connected${X}\n"
fi

printf "  watchdog    "; alive 'watchdog\.sh' && printf "%b" "$(up)" || printf "%b" "$(down)"
printf "    sshd "; pgrep -x sshd >/dev/null 2>&1 && printf "%b\n" "$(up)" || printf "%b\n" "$(down)"

# ---- deploy ---------------------------------------------------------------
SRC="$HOME_DIR/rofihosted-src"
if [ -d "$SRC/.git" ]; then
  SHA=$(cd "$SRC" && git rev-parse --short HEAD 2>/dev/null)
  SUBJ=$(cd "$SRC" && git log -1 --format=%s 2>/dev/null | cut -c1-46)
  printf "${D}--------------------------------------------------------${X}\n"
  printf "  deploy      ${B}%s${X} ${D}%s${X}\n" "${SHA:-?}" "$SUBJ"
fi

# ---- resources ------------------------------------------------------------
DISK=$(df -h "$HOME_DIR" 2>/dev/null | awk 'NR==2 {print $4" free ("$5" used)"}')
MEM=$(awk '/MemAvailable/ {a=$2} /MemTotal/ {t=$2} END {if (t>0) printf "%d/%d MB free", a/1024, t/1024}' /proc/meminfo 2>/dev/null)
printf "${D}--------------------------------------------------------${X}\n"
printf "  disk %s   mem %s\n" "${DISK:-?}" "${MEM:-?}"
printf "${D}  console: admin.rofihosted.space/shell  |  status.sh for more${X}\n\n"
