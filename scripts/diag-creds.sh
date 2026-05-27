#!/data/data/com.termux/files/usr/bin/sh
echo "=== env keys ==="
awk -F= '{print $1}' ~/.hp-server.env
echo
echo "=== creds file user line (just the username, no password) ==="
head -1 ~/.hp-server-creds.txt
echo
echo "=== env user matches? ==="
. ~/.hp-server.env
ENV_USER="$HP_AUTH_USER"
FILE_USER=$(head -1 ~/.hp-server-creds.txt)
if [ "$ENV_USER" = "$FILE_USER" ]; then
  echo "match: usernames equal"
else
  echo "MISMATCH: env=$ENV_USER file=$FILE_USER"
fi
