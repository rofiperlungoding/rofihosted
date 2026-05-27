#!/data/data/com.termux/files/usr/bin/sh
# Quick smoke test: login and grep new UI markers + cache buster on security/settings pages.
set -e

if [ -f ~/.hp-server.env ]; then
  set -a
  . ~/.hp-server.env
  set +a
fi

USER="${HP_AUTH_USER:-mrofid}"
PASS="${HP_AUTH_PASS:-}"

if [ -z "$PASS" ]; then
  echo "no HP_AUTH_PASS in ~/.hp-server.env" >&2
  exit 1
fi

CJ=$(mktemp)
trap "rm -f $CJ" EXIT

# Cookie has Secure flag, must use HTTPS through cloudflared.
BASE="https://app.rofihosted.space"

CODE=$(curl -s -c "$CJ" \
  --data-urlencode "username=$USER" \
  --data-urlencode "password=$PASS" \
  -o /dev/null -w '%{http_code}' \
  "$BASE/login/submit")
echo "login http: $CODE"
echo "--- raw login response headers ---"
curl -s -i \
  --data-urlencode "username=$USER" \
  --data-urlencode "password=$PASS" \
  "$BASE/login/submit" 2>&1 | grep -iE '^(http|set-cookie|location)' | head -10
echo "--- cookie jar ---"
grep -v '^#' "$CJ" | grep -v '^$' | head -3
echo "------------------"

echo "--- /security ---"
SEC=$(curl -s -b "$CJ" "$BASE/security")
echo "cache buster: $(echo "$SEC" | grep -oE 'theme\.css\?v=[0-9]+' | head -1)"
echo "scrub-run-btn: $(echo "$SEC" | grep -c 'scrub-run-btn')"
echo "scrub-findings: $(echo "$SEC" | grep -c 'scrub-findings')"
echo "title: $(echo "$SEC" | grep -oE '<title>[^<]+' | head -1)"

echo "--- /settings ---"
SET=$(curl -s -b "$CJ" "$BASE/settings")
echo "cache buster: $(echo "$SET" | grep -oE 'theme\.css\?v=[0-9]+' | head -1)"
echo "dbcache-grid: $(echo "$SET" | grep -c 'dbcache-grid')"
echo "dbc-rows: $(echo "$SET" | grep -c 'dbc-rows')"
echo "title: $(echo "$SET" | grep -oE '<title>[^<]+' | head -1)"
