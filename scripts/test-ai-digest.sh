#!/data/data/com.termux/files/usr/bin/sh
# Smoke test: login then trigger an AI digest run, then fetch the latest digest.
#
# Reads HP_AUTH_USER and HP_AUTH_PASS from ~/.hp-server.env so credentials
# are never embedded in this script.
#
# Add to your ~/.hp-server.env if not already present:
#   HP_AUTH_USER=yourname
#   HP_AUTH_PASS=yourpassword
set -e

if [ -f ~/.hp-server.env ]; then
  set -a
  . ~/.hp-server.env
  set +a
fi

if [ -z "$HP_AUTH_USER" ] || [ -z "$HP_AUTH_PASS" ]; then
  echo "HP_AUTH_USER and HP_AUTH_PASS must be set in ~/.hp-server.env" >&2
  exit 1
fi

COOKIE=$(curl -sS -i \
  --data-urlencode "username=$HP_AUTH_USER" \
  --data-urlencode "password=$HP_AUTH_PASS" \
  https://app.rofihosted.space/login/submit \
  | awk -F'[=;]' '/^set-cookie: rofi_session=/ { print $2; exit }')

if [ -z "$COOKIE" ]; then
  echo "login failed (no session cookie returned)"
  exit 1
fi
echo "got session cookie, len=${#COOKIE}"

echo "--- trigger digest run ---"
curl -sS --max-time 60 \
  -H "Cookie: rofi_session=$COOKIE" \
  https://app.rofihosted.space/api/ai/digest/run
echo

echo "--- latest digest ---"
curl -sS \
  -H "Cookie: rofi_session=$COOKIE" \
  https://app.rofihosted.space/api/ai/digest/latest
echo
