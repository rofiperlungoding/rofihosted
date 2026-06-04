#!/data/data/com.termux/files/usr/bin/bash
set -e
source ~/.hp-server.env
export TMPDIR="$PREFIX/tmp"

echo "=== Login (form-urlencoded to /login/submit) ==="
RESP=$(curl -sS -m 5 -i --resolve app.rofihosted.space:8080:127.0.0.1 --data-urlencode "username=$HP_AUTH_USER" --data-urlencode "password=$HP_AUTH_PASS" http://app.rofihosted.space:8080/login/submit 2>&1)
COOKIE=$(echo "$RESP" | grep -i "^set-cookie:" | head -1 | sed 's/^[Ss]et-[Cc]ookie: //; s/;.*//')
echo "Cookie: $COOKIE"

if [ -z "$COOKIE" ]; then
  echo "Login failed - no cookie returned"
  exit 1
fi

echo
echo "=== /metrics with cookie ==="
curl -sS -m 5 --resolve app.rofihosted.space:8080:127.0.0.1 -H "Cookie: $COOKIE" -o "$TMPDIR/m.txt" -w "HTTP=%{http_code} Size=%{size_download}\n" http://app.rofihosted.space:8080/metrics

echo
echo "First 50 lines:"
head -50 "$TMPDIR/m.txt"
echo
echo "Total lines: $(wc -l < $TMPDIR/m.txt)"
