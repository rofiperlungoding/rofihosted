#!/data/data/com.termux/files/usr/bin/sh
# Configure rclone for Cloudflare R2 backup target.
# Run this once, interactively, on the phone (or via dashboard /shell).
#
# Required from your Cloudflare dashboard (R2 -> Manage R2 API Tokens):
#   1. Account ID (visible in R2 sidebar)
#   2. Access Key ID
#   3. Secret Access Key
#   4. Bucket name (create one if needed)
#
# After this script runs, scripts/backup-r2.sh will be able to push tarballs
# to s3://r2/<bucket>/rofihosted/ at any time.

set -e
RCLONE_CONF="$HOME/.config/rclone/rclone.conf"
mkdir -p "$(dirname "$RCLONE_CONF")"

if ! command -v rclone >/dev/null 2>&1; then
    echo "rclone not installed. run: pkg install rclone"
    exit 1
fi

# Allow non-interactive mode via env vars (set in /shell or scripts):
#   R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET
if [ -n "${R2_ACCOUNT_ID:-}" ] && [ -n "${R2_ACCESS_KEY_ID:-}" ] && \
   [ -n "${R2_SECRET_ACCESS_KEY:-}" ] && [ -n "${R2_BUCKET:-}" ]; then
    echo "configuring rclone non-interactively from env..."
    cat > "$RCLONE_CONF" <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = $R2_ACCESS_KEY_ID
secret_access_key = $R2_SECRET_ACCESS_KEY
endpoint = https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF
    chmod 600 "$RCLONE_CONF"

    # Persist bucket name for backup script
    grep -v '^R2_BUCKET=' ~/.hp-server.env 2>/dev/null > ~/.hp-server.env.tmp || true
    echo "R2_BUCKET=$R2_BUCKET" >> ~/.hp-server.env.tmp
    mv ~/.hp-server.env.tmp ~/.hp-server.env
    chmod 600 ~/.hp-server.env

    echo "OK config written to $RCLONE_CONF"
    echo "testing connectivity to bucket..."
    if rclone lsd "r2:$R2_BUCKET" >/dev/null 2>&1; then
        echo "PASS: bucket reachable"
    else
        echo "WARN: bucket not reachable yet (perhaps empty or wrong name)"
        echo "      run: rclone lsd r2:$R2_BUCKET"
    fi
    exit 0
fi

# Interactive fallback
echo "Cloudflare R2 setup"
echo "---"
echo "Find these in Cloudflare dashboard -> R2 -> Manage API Tokens"
echo
printf "Account ID: "; read -r account_id
printf "Access Key ID: "; read -r access_key
printf "Secret Access Key: "; stty -echo; read -r secret; stty echo; echo
printf "Bucket name: "; read -r bucket

cat > "$RCLONE_CONF" <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = $access_key
secret_access_key = $secret
endpoint = https://${account_id}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF
chmod 600 "$RCLONE_CONF"

grep -v '^R2_BUCKET=' ~/.hp-server.env 2>/dev/null > ~/.hp-server.env.tmp || true
echo "R2_BUCKET=$bucket" >> ~/.hp-server.env.tmp
mv ~/.hp-server.env.tmp ~/.hp-server.env
chmod 600 ~/.hp-server.env

echo
echo "OK rclone configured. Testing..."
rclone lsd "r2:$bucket" 2>&1 | head -5 || echo "(bucket might be empty, that's fine)"
echo
echo "Backup with: bash ~/backup-r2.sh"
