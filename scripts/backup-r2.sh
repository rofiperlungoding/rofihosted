#!/data/data/com.termux/files/usr/bin/sh
# Snapshot rofihosted state and push the tarball to Cloudflare R2.
# Reads R2_BUCKET from ~/.hp-server.env, expects rclone to be configured
# via scripts/r2-setup.sh first.
#
# Usage:
#   bash ~/backup-r2.sh              # one-shot
#   crontab -e ; 0 * * * * ~/backup-r2.sh   # hourly
#
# Output: prints a JSON-ish summary that the dashboard can parse.

set -e

# Load env
if [ -f ~/.hp-server.env ]; then
    set -a
    . ~/.hp-server.env
    set +a
fi

if [ -z "${R2_BUCKET:-}" ]; then
    echo '{"ok":false,"err":"R2_BUCKET not set in ~/.hp-server.env, run r2-setup.sh"}'
    exit 1
fi
if ! command -v rclone >/dev/null 2>&1; then
    echo '{"ok":false,"err":"rclone not installed"}'
    exit 1
fi

# Step 1: build the local tarball
LOCAL_TAR=""
if [ -x ~/backup-quick.sh ]; then
    out=$(bash ~/backup-quick.sh 2>&1)
    LOCAL_TAR=$(echo "$out" | grep '^path=' | cut -d= -f2-)
fi
if [ -z "$LOCAL_TAR" ] || [ ! -f "$LOCAL_TAR" ]; then
    echo '{"ok":false,"err":"local backup failed","detail":"'"$out"'"}'
    exit 1
fi

basename=$(basename "$LOCAL_TAR")
size_bytes=$(stat -c %s "$LOCAL_TAR" 2>/dev/null || echo 0)

# Step 2: upload to R2 under rofihosted/<filename>
remote_path="r2:${R2_BUCKET}/rofihosted/${basename}"
upload_start=$(date +%s)
if rclone copy "$LOCAL_TAR" "r2:${R2_BUCKET}/rofihosted/" --no-traverse 2>/dev/null; then
    upload_end=$(date +%s)
    upload_ms=$(( (upload_end - upload_start) * 1000 ))
    echo "{\"ok\":true,\"local_path\":\"$LOCAL_TAR\",\"remote_path\":\"$remote_path\",\"size_bytes\":$size_bytes,\"upload_ms\":$upload_ms}"
else
    echo "{\"ok\":false,\"err\":\"r2_upload_failed\",\"local_path\":\"$LOCAL_TAR\"}"
    exit 1
fi

# Step 3: rotate remote, keep last 168 (7 days hourly = 168 backups)
# Cleanest: list, sort by name (timestamp prefix), drop older
keep=168
rclone lsf "r2:${R2_BUCKET}/rofihosted/" 2>/dev/null \
    | grep '^rofihosted-' \
    | sort \
    | head -n -$keep 2>/dev/null \
    | while read -r f; do
        rclone delete "r2:${R2_BUCKET}/rofihosted/$f" 2>/dev/null || true
      done

exit 0
