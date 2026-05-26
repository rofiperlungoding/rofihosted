#!/data/data/com.termux/files/usr/bin/sh
# Smoke-test the new endpoints from a live session.
set -eu

if [ -f ~/.hp-server.env ]; then
  set -a; . ~/.hp-server.env; set +a
fi
[ -n "${HP_AUTH_USER:-}" ] && [ -n "${HP_AUTH_PASS:-}" ] || { echo "auth env not set"; exit 1; }

COOKIE=$(curl -sS -i \
  --data-urlencode "username=$HP_AUTH_USER" \
  --data-urlencode "password=$HP_AUTH_PASS" \
  https://app.rofihosted.space/login/submit \
  | awk -F'[=;]' '/^set-cookie: rofi_session=/ { print $2; exit }')
[ -n "$COOKIE" ] || { echo "login failed"; exit 1; }
HDR="Cookie: rofi_session=$COOKIE"

echo "--- /api/tunnel/health ---"
curl -sS -H "$HDR" https://app.rofihosted.space/api/tunnel/health
echo

echo "--- /api/audit ---"
curl -sS -H "$HDR" https://app.rofihosted.space/api/audit | head -c 600
echo

echo "--- /api/geoblock ---"
curl -sS -H "$HDR" https://app.rofihosted.space/api/geoblock
echo

echo "--- /api/geoblock/update (off) ---"
curl -sS -H "$HDR" -d 'enabled=off&allow=ID,SG' https://app.rofihosted.space/api/geoblock/update
echo

echo "--- /api/audit (after geoblock update) ---"
curl -sS -H "$HDR" https://app.rofihosted.space/api/audit | head -c 400
echo
