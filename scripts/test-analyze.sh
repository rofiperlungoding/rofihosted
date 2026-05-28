#!/data/data/com.termux/files/usr/bin/sh
# Test the AI project analyzer endpoint.
set -e
if [ -f ~/.hp-server.env ]; then set -a; . ~/.hp-server.env; set +a; fi
CJ=$(mktemp); trap "rm -f $CJ" EXIT
curl -s -c "$CJ" --data-urlencode "username=$HP_AUTH_USER" --data-urlencode "password=$HP_AUTH_PASS" -o /dev/null https://app.rofihosted.space/login/submit

echo "--- analyze: rivex (Vite SPA) ---"
curl -s -b "$CJ" -H 'Content-Type: application/json' \
  -d '{"repo_url":"https://github.com/rofiperlungoding/rivex","branch":"main"}' \
  https://app.rofihosted.space/api/projects/analyze | python3 -m json.tool 2>&1 | head -50
