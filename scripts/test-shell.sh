#!/data/data/com.termux/files/usr/bin/bash
set +e
[ -f ~/.hp-server.env ] && { set -a; . ~/.hp-server.env; set +a; }

BASE="https://app.rofihosted.space"
CJ=$(mktemp); trap "rm -f $CJ" EXIT
curl -s -c "$CJ" -o /dev/null --data-urlencode "username=$HP_AUTH_USER" --data-urlencode "password=$HP_AUTH_PASS" "$BASE/login/submit"

echo "=== /api/system/info ==="
curl -s -b "$CJ" "$BASE/api/system/info" | python3 -m json.tool

echo
echo "=== /api/system/exec: pwd ==="
curl -s -b "$CJ" -X POST -H 'Content-Type: application/json' -d '{"cmd":"pwd"}' "$BASE/api/system/exec" | python3 -m json.tool

echo
echo "=== /api/system/exec: uname -a ==="
curl -s -b "$CJ" -X POST -H 'Content-Type: application/json' -d '{"cmd":"uname -a"}' "$BASE/api/system/exec" | python3 -m json.tool

echo
echo "=== /api/system/exec: bad command (should have non-zero exit) ==="
curl -s -b "$CJ" -X POST -H 'Content-Type: application/json' -d '{"cmd":"ls /nonexistent"}' "$BASE/api/system/exec" | python3 -m json.tool

echo
echo "=== /api/system/exec: timeout test (sleep 3 with 1s timeout) ==="
curl -s -b "$CJ" -X POST -H 'Content-Type: application/json' -d '{"cmd":"sleep 3","timeout_ms":1000}' "$BASE/api/system/exec" | python3 -m json.tool

echo
echo "=== /api/system/exec: cwd test ==="
curl -s -b "$CJ" -X POST -H 'Content-Type: application/json' -d '{"cmd":"pwd && ls | head -3","cwd":"/data/data/com.termux/files/home/zig/hp-server/src"}' "$BASE/api/system/exec" | python3 -m json.tool

echo
echo "=== /shell page check ==="
curl -s -b "$CJ" -o /dev/null -w 'status=%{http_code}\n' "$BASE/shell"
