#!/data/data/com.termux/files/usr/bin/sh
# Smoke-test the new structured AI features.
set -eu
[ -f ~/.hp-server.env ] && { set -a; . ~/.hp-server.env; set +a; }
[ -n "${HP_AUTH_USER:-}" ] && [ -n "${HP_AUTH_PASS:-}" ] || { echo "auth env not set"; exit 1; }

COOKIE=$(curl -sS -i \
  --data-urlencode "username=$HP_AUTH_USER" \
  --data-urlencode "password=$HP_AUTH_PASS" \
  https://app.rofihosted.space/login/submit \
  | awk -F'[=;]' '/^set-cookie: rofi_session=/ { print $2; exit }')
[ -n "$COOKIE" ] || { echo "login failed"; exit 1; }
HDR="Cookie: rofi_session=$COOKIE"

echo "--- /api/embeddings/stats ---"
curl -sS -H "$HDR" https://app.rofihosted.space/api/embeddings/stats
echo

echo "--- /api/embeddings/clusters ---"
curl -sS -H "$HDR" https://app.rofihosted.space/api/embeddings/clusters | head -c 400
echo

echo "--- /api/honeypot ---"
curl -sS -H "$HDR" https://app.rofihosted.space/api/honeypot
echo

echo "--- /api/ai/query (count visits last 24h) ---"
curl -sS -H "$HDR" --max-time 30 \
  --data-urlencode 'q=how many visits did I get in the last 24 hours?' \
  https://app.rofihosted.space/api/ai/query
echo

echo "--- /api/ai/query (top countries) ---"
curl -sS -H "$HDR" --max-time 30 \
  --data-urlencode 'q=top 5 countries hitting my server today' \
  https://app.rofihosted.space/api/ai/query
echo

echo "--- /api/ai/query (failed logins) ---"
curl -sS -H "$HDR" --max-time 30 \
  --data-urlencode 'q=any failed login attempts recently?' \
  https://app.rofihosted.space/api/ai/query
echo

echo "--- /api/ai/policy/run (synchronous) ---"
curl -sS -H "$HDR" --max-time 60 https://app.rofihosted.space/api/ai/policy/run
echo

echo "--- /api/ai/policy/latest ---"
curl -sS -H "$HDR" https://app.rofihosted.space/api/ai/policy/latest | head -c 800
echo
