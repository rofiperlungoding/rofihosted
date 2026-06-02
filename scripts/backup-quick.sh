#!/data/data/com.termux/files/usr/bin/sh
# Quick unencrypted backup of irreplaceable rofihosted state.
# Designed to be triggered from the dashboard /shell page (no SSH needed).
#
# For encrypted offsite backups with rotation, use scripts/backup.sh instead
# (requires `age` and BACKUP_PASSPHRASE in ~/.hp-server.env).
#
# What's included:
#   - ~/.hp-server-*.jsonl         (all config files)
#   - ~/.hp-server-creds.txt       (auth credentials)
#   - ~/.hp-server-secret.bin      (session HMAC pepper)
#   - ~/data/*.jsonl               (visits, uptime, logins, audit, etc.)
#   - ~/data/cache.db              (main database)
#   - ~/data/dbs/                  (per-project SQLite databases)
#   - ~/data/projects/*/secrets.bin (encrypted env vars per project)
#
# What's NOT included (recoverable from elsewhere):
#   - hp-server source/binary (rebuild from GitHub)
#   - project working trees (re-clone from project repo_url)
#   - cloudflared tunnel JSON (re-login + recreate-tunnel)

set -e
ts=$(date +%Y%m%d-%H%M%S)
out_dir="$HOME/backups"
out="$out_dir/rofihosted-$ts.tar.gz"
mkdir -p "$out_dir"

files=""

# Config files
for f in \
    "$HOME/.hp-server-projects.jsonl" \
    "$HOME/.hp-server-users.jsonl" \
    "$HOME/.hp-server-invites.jsonl" \
    "$HOME/.hp-server-creds.txt" \
    "$HOME/.hp-server-secret.bin" \
    "$HOME/.hp-server-blocklist.txt" \
    "$HOME/.hp-server-webhooks.jsonl" \
    "$HOME/.hp-server-apikeys.jsonl" \
    "$HOME/.hp-server-rules.jsonl" \
    "$HOME/.hp-server-cron.jsonl" \
    "$HOME/.hp-server-geoblock.txt" \
    "$HOME/.hp-server-honeypot.txt" \
    "$HOME/.hp-server.env" ; do
    [ -e "$f" ] && files="$files $f"
done

# Data files (JSONL logs)
for f in \
    "$HOME/data/visits.jsonl" \
    "$HOME/data/uptime.jsonl" \
    "$HOME/data/logins.jsonl" \
    "$HOME/data/audit.jsonl" \
    "$HOME/data/digests.jsonl" \
    "$HOME/data/policy.jsonl" \
    "$HOME/data/ai-calls.jsonl" \
    "$HOME/data/scrub.jsonl" ; do
    [ -e "$f" ] && files="$files $f"
done

# Main database
[ -e "$HOME/data/cache.db" ] && files="$files $HOME/data/cache.db"
[ -e "$HOME/data/embeddings.bin" ] && files="$files $HOME/data/embeddings.bin"

# Per-project databases
[ -d "$HOME/data/dbs" ] && files="$files $HOME/data/dbs"

# Per-project secrets
for sb in "$HOME"/data/projects/*/secrets.bin ; do
    [ -e "$sb" ] && files="$files $sb"
done

if [ -z "$files" ]; then
    echo "nothing to back up"
    exit 1
fi

echo "creating $out ..."
# shellcheck disable=SC2086
tar czf "$out" $files 2>/dev/null
chmod 600 "$out"

# Rotate: keep last 14 backups locally
ls -1t "$out_dir"/rofihosted-*.tar.gz 2>/dev/null | tail -n +15 | xargs -r rm -f

size=$(du -h "$out" | cut -f1)
count=$(ls -1 "$out_dir"/rofihosted-*.tar.gz 2>/dev/null | wc -l)
echo "OK  size=$size  total_backups=$count"
echo "path=$out"
