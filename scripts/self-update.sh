#!/data/data/com.termux/files/usr/bin/sh
# Self-update hp-server from GitHub. Triggered via /api/system/update or
# manually. Stdout is a single JSON line for the dashboard. Verbose diag
# goes to ~/logs/self-update.log so you can tail it from /shell.
#
# Flow:
#   1. cd ~/rofihosted-src && git fetch origin main
#   2. If at HEAD: exit early with already_up_to_date
#   3. git reset --hard, rsync sources to ~/zig/hp-server/
#   4. Run ~/rebuild.sh
#   5. SIGTERM running hp-server; watchdog respawns with new binary

SRC_REPO="$HOME/rofihosted-src"
TARGET="$HOME/zig/hp-server"
LOG="$HOME/logs/self-update.log"
mkdir -p "$HOME/logs"

# Echo helpers: log() goes to the log file only; emit_json() goes to stdout.
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >> "$LOG"; }
emit() { printf '%s\n' "$*"; }

log "=== self-update started ==="

if [ ! -d "$SRC_REPO/.git" ]; then
    emit '{"ok":false,"err":"src_repo_missing","detail":"~/rofihosted-src is not a git clone"}'
    log "src repo missing"
    exit 1
fi

cd "$SRC_REPO" || { emit '{"ok":false,"err":"cd_failed"}'; exit 1; }

BEFORE=$(git rev-parse HEAD 2>/dev/null || echo unknown)
log "before HEAD = $BEFORE"

if ! git fetch --quiet origin main >> "$LOG" 2>&1; then
    emit '{"ok":false,"err":"fetch_failed"}'
    log "git fetch failed"
    exit 1
fi

REMOTE=$(git rev-parse origin/main)
log "remote HEAD = $REMOTE"

SHORT_BEFORE=$(echo "$BEFORE" | cut -c1-7)
SHORT_AFTER=$(echo "$REMOTE" | cut -c1-7)

if [ "$BEFORE" = "$REMOTE" ]; then
    emit "{\"ok\":true,\"reason\":\"already_up_to_date\",\"head\":\"$SHORT_BEFORE\"}"
    log "already up to date"
    exit 0
fi

log "updating $SHORT_BEFORE -> $SHORT_AFTER"
git reset --hard origin/main >> "$LOG" 2>&1

# Sync sources into the build tree, preserving cache + zig-out for fast rebuilds.
rsync -a --delete \
    --exclude='.zig-cache/' \
    --exclude='zig-out/' \
    "$SRC_REPO/zig/hp-server/" "$TARGET/" >> "$LOG" 2>&1

log "running rebuild.sh..."
if ! "$HOME/rebuild.sh" >> "$LOG" 2>&1; then
    emit "{\"ok\":false,\"err\":\"rebuild_failed\",\"before\":\"$SHORT_BEFORE\",\"after\":\"$SHORT_AFTER\"}"
    log "rebuild failed"
    exit 1
fi

if [ ! -x "$TARGET/zig-out/bin/hp-server" ]; then
    emit '{"ok":false,"err":"binary_missing"}'
    log "binary missing after rebuild"
    exit 1
fi

BIN_AGE_S=$(( $(date +%s) - $(stat -c %Y "$TARGET/zig-out/bin/hp-server") ))
log "binary age = ${BIN_AGE_S}s"

# Trigger watchdog respawn. The current request is being served by hp-server
# itself, so this kills our parent. We dispatch the kill in a subshell with a
# delay so this process can finish writing JSON output before dying.
(
    sleep 1
    pkill -TERM -f 'zig-out/bin/hp-server' >> "$LOG" 2>&1 || true
) &

emit "{\"ok\":true,\"reason\":\"updated\",\"before\":\"$SHORT_BEFORE\",\"after\":\"$SHORT_AFTER\",\"binary_age_s\":$BIN_AGE_S,\"status\":\"restarting\",\"note\":\"hp-server will be down for ~5s while watchdog respawns the new binary\"}"
log "emitted success, scheduling kill in 1s"
exit 0
