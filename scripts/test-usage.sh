#!/data/data/com.termux/files/usr/bin/sh
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

echo "--- /api/ai/usage ---"
curl -sS -H "$HDR" https://app.rofihosted.space/api/ai/usage
echo
