#!/data/data/com.termux/files/usr/bin/bash
set +e
[ -f ~/.hp-server.env ] && { set -a; . ~/.hp-server.env; set +a; }

BASE="https://app.rofihosted.space"
CJ=$(mktemp); trap "rm -f $CJ" EXIT
curl -s -c "$CJ" -o /dev/null --data-urlencode "username=$HP_AUTH_USER" --data-urlencode "password=$HP_AUTH_PASS" "$BASE/login/submit"

echo "=== /api/system/backup?target=local ==="
curl -s -b "$CJ" -X POST "$BASE/api/system/backup?target=local" | python3 -m json.tool

echo
echo "=== /api/system/backups ==="
curl -s -b "$CJ" "$BASE/api/system/backups" | python3 -m json.tool

echo
echo "=== /api/system/power ==="
curl -s -b "$CJ" "$BASE/api/system/power" | python3 -m json.tool
