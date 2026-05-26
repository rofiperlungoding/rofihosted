#!/data/data/com.termux/files/usr/bin/sh
# Encrypted backup of operator state.
#
# Bundles: ~/data/, ~/.hp-server-creds.txt, ~/.hp-server-blocklist.txt,
#          ~/.hp-server.env, ~/.hp-server-secret.bin, ~/.hp-server-geoblock.txt,
#          ~/.cloudflared/ (tunnel cred + cert)
#
# Encrypts with `age` using a passphrase from $BACKUP_PASSPHRASE (set in
# ~/.hp-server.env). Output: ~/data/backups/hp-YYYY-MM-DD.tar.age
#
# Schedule with cron:
#   0 3 * * * /data/data/com.termux/files/home/backup.sh
#
# Restore:
#   age -d hp-YYYY-MM-DD.tar.age | tar -xv -C ~/restore/
set -eu

BACKUP_DIR=~/data/backups
mkdir -p "$BACKUP_DIR"

# Load env
if [ -f ~/.hp-server.env ]; then
  set -a
  . ~/.hp-server.env
  set +a
fi

if [ -z "${BACKUP_PASSPHRASE:-}" ]; then
  echo "BACKUP_PASSPHRASE not set in ~/.hp-server.env, aborting" >&2
  exit 1
fi

if ! command -v age > /dev/null 2>&1; then
  echo "age not installed. run: pkg install age" >&2
  exit 1
fi

DATE=$(date +%F)
OUT="$BACKUP_DIR/hp-$DATE.tar.age"
TMP="$BACKUP_DIR/.hp-$DATE.tar"

# Build the tarball. Use --ignore-failed-read so missing optional files don't abort.
tar -cf "$TMP" --ignore-failed-read \
  -C ~ data \
  -C ~ .hp-server-creds.txt \
  -C ~ .hp-server-blocklist.txt \
  -C ~ .hp-server.env \
  -C ~ .hp-server-secret.bin \
  -C ~ .hp-server-geoblock.txt \
  -C ~ .cloudflared 2>/dev/null || true

# Encrypt with age (symmetric passphrase mode)
AGE_PASSPHRASE="$BACKUP_PASSPHRASE" age -p -o "$OUT" "$TMP" <<EOF
$BACKUP_PASSPHRASE
$BACKUP_PASSPHRASE
EOF
chmod 600 "$OUT"
rm -f "$TMP"

# Retention: keep last 14 daily backups
ls -1t "$BACKUP_DIR"/hp-*.tar.age 2>/dev/null | tail -n +15 | xargs -r rm -f --

echo "backup written: $OUT ($(stat -c %s "$OUT" 2>/dev/null || stat -f %z "$OUT") bytes)"
