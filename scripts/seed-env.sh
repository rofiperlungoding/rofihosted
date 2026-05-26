#!/data/data/com.termux/files/usr/bin/sh
# Append HP_AUTH_USER and HP_AUTH_PASS to ~/.hp-server.env if not already present.
# Pass them as args so they never sit in shell history under predictable names.
#   ./seed-env.sh <user> <pass>
set -e
if [ "$#" -ne 2 ]; then
  echo "usage: $0 <user> <pass>" >&2
  exit 1
fi
ENV=~/.hp-server.env
touch "$ENV"
chmod 600 "$ENV"

if grep -q '^HP_AUTH_USER=' "$ENV"; then
  echo "HP_AUTH_USER already present, skipping"
else
  printf 'HP_AUTH_USER=%s\n' "$1" >> "$ENV"
  echo "HP_AUTH_USER added"
fi
if grep -q '^HP_AUTH_PASS=' "$ENV"; then
  echo "HP_AUTH_PASS already present, skipping"
else
  printf 'HP_AUTH_PASS=%s\n' "$2" >> "$ENV"
  echo "HP_AUTH_PASS added"
fi
chmod 600 "$ENV"
