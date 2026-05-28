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
# Prefer rsync (precise --delete + exclude); fall back to cp + manual delete
# if rsync is not installed.
if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete \
        --exclude='.zig-cache/' \
        --exclude='zig-out/' \
        "$SRC_REPO/zig/hp-server/" "$TARGET/" >> "$LOG" 2>&1
    log "synced via rsync"
else
    log "rsync not found, using cp fallback"
    # Copy fresh sources, but preserve build cache directories
    for sub in src build.zig build.zig.zon; do
        if [ -e "$SRC_REPO/zig/hp-server/$sub" ]; then
            rm -rf "$TARGET/$sub" 2>/dev/null
            cp -R "$SRC_REPO/zig/hp-server/$sub" "$TARGET/" 2>>"$LOG"
        fi
    done
fi

log "running rebuild.sh..."
# Capture the binary's mtime before rebuild so we can verify it actually changed
PRE_REBUILD_MTIME=0
if [ -f "$TARGET/zig-out/bin/hp-server" ]; then
    PRE_REBUILD_MTIME=$(stat -c %Y "$TARGET/zig-out/bin/hp-server" 2>/dev/null || echo 0)
fi

if ! "$HOME/rebuild.sh" >> "$LOG" 2>&1; then
    emit "{\"ok\":false,\"err\":\"rebuild_failed\",\"before\":\"$SHORT_BEFORE\",\"after\":\"$SHORT_AFTER\"}"
    log "rebuild script returned non-zero"
    exit 1
fi

if [ ! -x "$TARGET/zig-out/bin/hp-server" ]; then
    emit '{"ok":false,"err":"binary_missing"}'
    log "binary missing after rebuild"
    exit 1
fi

POST_REBUILD_MTIME=$(stat -c %Y "$TARGET/zig-out/bin/hp-server")
BIN_AGE_S=$(( $(date +%s) - POST_REBUILD_MTIME ))
log "binary age = ${BIN_AGE_S}s, mtime change: $PRE_REBUILD_MTIME -> $POST_REBUILD_MTIME"

# If the binary mtime didn't advance, the build silently failed or was a
# no-op. We treat this as a failure so the operator knows they're not
# actually running the new code.
# If the binary mtime didn't advance, that may be expected if the commit
# touched only scripts / docs (Zig caches builds by source hash). Detect
# whether any .zig file actually changed; if not, the update is a no-op
# at the binary level and that's fine. If Zig sources DID change but the
# binary still didn't advance, that's a real rebuild failure.
ZIG_CHANGED=$(git diff --name-only "$BEFORE" "$AFTER" 2>/dev/null | grep -E '\.(zig|html|js|css)$|build\.zig\.zon' | wc -l)
log "files affecting binary changed: $ZIG_CHANGED"

if [ "$POST_REBUILD_MTIME" = "$PRE_REBUILD_MTIME" ] && [ "$ZIG_CHANGED" -gt 0 ]; then
    emit "{\"ok\":false,\"err\":\"rebuild_did_not_produce_new_binary\",\"before\":\"$SHORT_BEFORE\",\"after\":\"$SHORT_AFTER\",\"binary_mtime_unchanged\":true,\"hint\":\"check ~/logs/self-update.log for compile errors\"}"
    log "binary mtime unchanged but $ZIG_CHANGED build-affecting files changed; treating as failure"
    exit 1
fi

# If only scripts/docs changed, no need to restart hp-server. Emit success
# and skip the kill so the operator's session survives.
if [ "$ZIG_CHANGED" = "0" ]; then
    emit "{\"ok\":true,\"reason\":\"updated\",\"before\":\"$SHORT_BEFORE\",\"after\":\"$SHORT_AFTER\",\"binary_age_s\":$BIN_AGE_S,\"status\":\"no_restart_needed\",\"note\":\"only non-build files changed (scripts/docs); hp-server kept running\"}"
    log "only non-build files changed; skipping restart"
    exit 0
fi

# Trigger watchdog respawn. The current request is being served by hp-server
# itself, so this kills our parent. We dispatch the kill in a subshell with a
# longer delay (3s) so this process can finish writing JSON output AND the
# HTTP client can read the response before the connection is severed.
(
    sleep 3
    pkill -TERM -f 'zig-out/bin/hp-server' >> "$LOG" 2>&1 || true
) &
disown 2>/dev/null || true

emit "{\"ok\":true,\"reason\":\"updated\",\"before\":\"$SHORT_BEFORE\",\"after\":\"$SHORT_AFTER\",\"binary_age_s\":$BIN_AGE_S,\"status\":\"restarting\",\"note\":\"hp-server will be down for ~5s while watchdog respawns the new binary\"}"
log "emitted success, scheduling kill in 3s"
exit 0
