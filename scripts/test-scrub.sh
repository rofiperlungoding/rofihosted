#!/data/data/com.termux/files/usr/bin/sh
set -eu
[ -f ~/.hp-server.env ] && { set -a; . ~/.hp-server.env; set +a; }
COOKIE=$(curl -sS -i \
  --data-urlencode "username=$HP_AUTH_USER" \
  --data-urlencode "password=$HP_AUTH_PASS" \
  https://app.rofihosted.space/login/submit \
  | awk -F'[=;]' '/^set-cookie: rofi_session=/ { print $2; exit }')
HDR="Cookie: rofi_session=$COOKIE"

echo "--- /api/ai/scrub (synchronous, ~10-20s) ---"
curl -sS -H "$HDR" --max-time 60 https://app.rofihosted.space/api/ai/scrub | head -c 1500
echo
