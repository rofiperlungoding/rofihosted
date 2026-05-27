#!/data/data/com.termux/files/usr/bin/sh
# Smoke test for the operator rules engine.
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

echo "--- GET /api/rules (initial) ---"
curl -sS -H "$HDR" https://app.rofihosted.space/api/rules
echo

echo "--- POST /api/rules/replace (one log rule) ---"
curl -sS -H "$HDR" -H "Content-Type: application/json" \
  --data-binary '[{"id":"r1","name":"log all visits","enabled":true,"trigger":"on_visit","conditions":[],"actions":[{"type":"increment","counter":"visits_seen"}]}]' \
  https://app.rofihosted.space/api/rules/replace
echo

echo "--- GET /api/rules (after replace, should show r1 + counter) ---"
sleep 2
curl -sS -H "$HDR" https://app.rofihosted.space/api/rules | head -c 700
echo

echo "--- replace with invalid trigger ---"
curl -sS -H "$HDR" -H "Content-Type: application/json" \
  --data-binary '[{"id":"bad","name":"x","enabled":true,"trigger":"on_nope","conditions":[],"actions":[]}]' \
  https://app.rofihosted.space/api/rules/replace
echo

echo "--- replace with empty array (clear all rules) ---"
curl -sS -H "$HDR" -H "Content-Type: application/json" \
  --data-binary '[]' \
  https://app.rofihosted.space/api/rules/replace
echo
