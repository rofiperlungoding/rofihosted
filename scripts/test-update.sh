#!/data/data/com.termux/files/usr/bin/bash
set +e
[ -f ~/.hp-server.env ] && { set -a; . ~/.hp-server.env; set +a; }

BASE="https://app.rofihosted.space"
CJ=$(mktemp); trap "rm -f $CJ" EXIT
curl -s -c "$CJ" -o /dev/null --data-urlencode "username=$HP_AUTH_USER" --data-urlencode "password=$HP_AUTH_PASS" "$BASE/login/submit"

echo "=== BEFORE update: /api/system/version ==="
curl -s -b "$CJ" "$BASE/api/system/version" | python3 -m json.tool

echo
echo "=== POST /api/system/update (this rebuilds, takes 30-90s)... ==="
curl -s -b "$CJ" -X POST --max-time 180 "$BASE/api/system/update" | python3 -m json.tool

echo
echo "=== sleep 10s for watchdog to respawn hp-server ==="
sleep 10

echo
echo "=== Re-login (cookie may have invalidated during restart) ==="
rm -f "$CJ"
curl -s -c "$CJ" -o /dev/null --data-urlencode "username=$HP_AUTH_USER" --data-urlencode "password=$HP_AUTH_PASS" "$BASE/login/submit"

echo
echo "=== AFTER update: /api/system/version ==="
curl -s -b "$CJ" "$BASE/api/system/version" | python3 -m json.tool

echo
echo "=== self-update log tail ==="
tail -30 ~/logs/self-update.log 2>/dev/null
