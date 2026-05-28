#!/data/data/com.termux/files/usr/bin/bash
set +e
[ -f ~/.hp-server.env ] && { set -a; . ~/.hp-server.env; set +a; }

BASE="https://app.rofihosted.space"
CJ=$(mktemp); trap "rm -f $CJ" EXIT
curl -s -c "$CJ" -o /dev/null --data-urlencode "username=$HP_AUTH_USER" --data-urlencode "password=$HP_AUTH_PASS" "$BASE/login/submit"

echo "=== /api/system/version ==="
curl -s -b "$CJ" "$BASE/api/system/version" | python3 -m json.tool

echo
echo "=== /api/system/restore-test?source=r2 ==="
curl -s -b "$CJ" -X POST "$BASE/api/system/restore-test?source=r2" | python3 -m json.tool

echo
echo "=== /api/system/restore-test?source=local ==="
curl -s -b "$CJ" -X POST "$BASE/api/system/restore-test?source=local" | python3 -m json.tool
