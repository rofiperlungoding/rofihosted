#!/data/data/com.termux/files/usr/bin/sh
# Atomic deploy helper for hosted sites at *.rofihosted.space.
#
# Usage:
#   ./hosted-deploy.sh <subdomain> <local_dir>
# Example:
#   ./hosted-deploy.sh blog ~/my-blog/dist
#
# What it does:
#   1. Validates subdomain shape (matches pathsafe.validateSubdomain).
#   2. Creates ~/hosted/sites/<sub>/releases/<UTC timestamp>/.
#   3. Copies files in.
#   4. Atomic-swaps ~/hosted/sites/<sub>/current via `ln -sfn`.
#   5. Prunes old releases keeping last 5.
#   6. Calls /api/hosted/refresh to bump the in-process cache.
#
# Run on the phone after `scp`'ing the local_dir to ~/staging/<sub>/.

set -e

SUBDOMAIN="${1:-}"
SRC="${2:-}"
HOSTED_ROOT="$HOME/hosted/sites"
KEEP=5

if [ -z "$SUBDOMAIN" ] || [ -z "$SRC" ]; then
  echo "usage: $0 <subdomain> <local_dir>" >&2
  exit 1
fi

if ! printf '%s' "$SUBDOMAIN" | grep -Eq '^[a-z0-9](-?[a-z0-9])*$'; then
  echo "invalid subdomain (must be [a-z0-9-], 1-63 chars, no leading/trailing dash)" >&2
  exit 1
fi
if [ ${#SUBDOMAIN} -gt 63 ]; then
  echo "invalid subdomain (longer than 63 chars)" >&2
  exit 1
fi

if [ ! -d "$SRC" ]; then
  echo "source dir not found: $SRC" >&2
  exit 1
fi

SITE="$HOSTED_ROOT/$SUBDOMAIN"
RELEASES="$SITE/releases"
TS=$(date -u +%Y%m%dT%H%M%SZ)
NEW="$RELEASES/$TS"

mkdir -p "$NEW"
# Use cp -a to preserve perms; rsync may not be installed in Termux.
cp -a "$SRC"/. "$NEW"/

# Atomic symlink swap (-f overwrites, -n treats existing symlink dir as a file)
ln -sfn "$NEW" "$SITE/current"

# Prune old releases, keep last $KEEP including the new one.
ls -1t "$RELEASES" 2>/dev/null | tail -n +"$((KEEP + 1))" | while read -r old; do
  [ -n "$old" ] && rm -rf "$RELEASES/$old"
done

# Bump in-process cache
if [ -f "$HOME/.hp-server.env" ]; then
  set -a
  . "$HOME/.hp-server.env"
  set +a
fi
USER="${HP_AUTH_USER:-}"
PASS="${HP_AUTH_PASS:-}"
if [ -n "$USER" ] && [ -n "$PASS" ]; then
  CJ=$(mktemp)
  trap "rm -f $CJ" EXIT
  curl -s -c "$CJ" \
    --data-urlencode "username=$USER" \
    --data-urlencode "password=$PASS" \
    -o /dev/null \
    https://app.rofihosted.space/login/submit
  curl -s -b "$CJ" \
    --data-urlencode "subdomain=$SUBDOMAIN" \
    -o /dev/null \
    https://app.rofihosted.space/api/hosted/refresh
  echo "deployed: $SUBDOMAIN -> $NEW (cache bumped)"
else
  echo "deployed: $SUBDOMAIN -> $NEW (set HP_AUTH_USER/PASS to auto-bump cache)"
fi
