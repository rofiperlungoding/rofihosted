#!/data/data/com.termux/files/usr/bin/sh
# Seed initial credentials file (consumed by hp-server on next start).
CREDS=~/.hp-server-creds.txt

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <username> <password>"
  exit 1
fi

# Write atomically with restrictive permissions
TMP="${CREDS}.tmp"
printf '%s\n%s\n' "$1" "$2" > "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$CREDS"
echo "[+] credentials file written to $CREDS (mode 600)"
echo "[+] restart hp-server to apply: ~/start-zig-server.sh"
