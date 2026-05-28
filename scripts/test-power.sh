#!/data/data/com.termux/files/usr/bin/bash
set +e
[ -f ~/.hp-server.env ] && { set -a; . ~/.hp-server.env; set +a; }

BASE="https://app.rofihosted.space"
CJ=$(mktemp); trap "rm -f $CJ" EXIT
curl -s -c "$CJ" -o /dev/null --data-urlencode "username=$HP_AUTH_USER" --data-urlencode "password=$HP_AUTH_PASS" "$BASE/login/submit"

echo "=== /api/system/power (initial; first poll happens 5s after boot) ==="
curl -s -b "$CJ" "$BASE/api/system/power" | python3 -m json.tool
echo
echo "=== sleep 8s for first poll ==="
sleep 8
echo "=== /api/system/power (after first poll) ==="
curl -s -b "$CJ" "$BASE/api/system/power" | python3 -m json.tool
