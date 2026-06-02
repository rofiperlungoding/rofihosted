#!/data/data/com.termux/files/usr/bin/sh
# Verify backup integrity by downloading latest from R2 and checking contents.
# Run monthly via cron or manually to ensure backups are restorable.
#
# Usage:
#   bash ~/verify-backup.sh              # verify latest R2 backup
#   bash ~/verify-backup.sh local        # verify latest local backup
#
# Output: JSON summary with verification results

set -e

MODE="${1:-r2}"
LOG=~/logs/backup-verify.log
mkdir -p ~/logs

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

# Load env for R2_BUCKET
if [ -f ~/.hp-server.env ]; then
    set -a
    . ~/.hp-server.env
    set +a
fi

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

if [ "$MODE" = "r2" ]; then
    # Verify R2 backup
    if [ -z "${R2_BUCKET:-}" ]; then
        echo '{"ok":false,"err":"R2_BUCKET not set in ~/.hp-server.env"}'
        exit 1
    fi
    if ! command -v rclone >/dev/null 2>&1; then
        echo '{"ok":false,"err":"rclone not installed"}'
        exit 1
    fi

    log "Listing R2 backups..."
    latest=$(rclone lsf "r2:${R2_BUCKET}/rofihosted/" 2>/dev/null \
        | grep '^rofihosted-' \
        | sort -r \
        | head -1)
    
    if [ -z "$latest" ]; then
        echo '{"ok":false,"err":"no backups found in R2"}'
        exit 1
    fi

    log "Latest backup: $latest"
    backup_path="$TEMP_DIR/$latest"
    
    log "Downloading from R2..."
    if ! rclone copy "r2:${R2_BUCKET}/rofihosted/$latest" "$TEMP_DIR/" 2>/dev/null; then
        echo '{"ok":false,"err":"failed to download from R2","file":"'"$latest"'"}'
        exit 1
    fi
else
    # Verify local backup
    log "Finding latest local backup..."
    latest=$(ls -t ~/backups/rofihosted-*.tar.gz 2>/dev/null | head -1)
    
    if [ -z "$latest" ] || [ ! -f "$latest" ]; then
        echo '{"ok":false,"err":"no local backups found"}'
        exit 1
    fi
    
    log "Latest backup: $latest"
    backup_path="$latest"
fi

# Verify tarball integrity
log "Verifying tarball integrity..."
if ! tar -tzf "$backup_path" >/dev/null 2>&1; then
    echo '{"ok":false,"err":"tarball corrupted or invalid","file":"'"$(basename "$backup_path")"'"}'
    exit 1
fi

# Extract and check critical files
log "Extracting backup..."
extract_dir="$TEMP_DIR/extract"
mkdir -p "$extract_dir"
tar -xzf "$backup_path" -C "$extract_dir" 2>/dev/null

# Check for critical files
critical_files=(
    ".hp-server-creds.txt"
    ".hp-server-secret.bin"
    ".hp-server-users.jsonl"
    ".hp-server-projects.jsonl"
    "data/visits.jsonl"
    "data/uptime.jsonl"
    "data/cache.db"
)

missing=0
found=0
for f in "${critical_files[@]}"; do
    if [ -f "$extract_dir/$f" ]; then
        found=$((found + 1))
        log "✓ Found: $f"
    else
        missing=$((missing + 1))
        log "✗ Missing: $f"
    fi
done

# Check database integrity if present
if [ -f "$extract_dir/data/cache.db" ]; then
    log "Checking SQLite database integrity..."
    if sqlite3 "$extract_dir/data/cache.db" "PRAGMA integrity_check;" 2>/dev/null | grep -q "ok"; then
        log "✓ Database integrity OK"
        db_ok=true
    else
        log "✗ Database integrity FAILED"
        db_ok=false
    fi
else
    db_ok=false
fi

# Calculate sizes
backup_size=$(stat -c %s "$backup_path" 2>/dev/null || echo 0)
backup_size_mb=$((backup_size / 1024 / 1024))

# Generate result
if [ $missing -eq 0 ] && [ "$db_ok" = true ]; then
    result="success"
    log "✓ Backup verification PASSED"
    echo "{\"ok\":true,\"result\":\"success\",\"file\":\"$(basename "$backup_path")\",\"size_mb\":$backup_size_mb,\"files_found\":$found,\"files_missing\":$missing,\"db_ok\":true,\"mode\":\"$MODE\"}"
else
    result="partial"
    log "⚠ Backup verification PARTIAL (missing=$missing, db_ok=$db_ok)"
    echo "{\"ok\":true,\"result\":\"partial\",\"file\":\"$(basename "$backup_path")\",\"size_mb\":$backup_size_mb,\"files_found\":$found,\"files_missing\":$missing,\"db_ok\":$db_ok,\"mode\":\"$MODE\"}"
fi

exit 0

# Made with Bob
