#!/data/data/com.termux/files/usr/bin/sh
set -e
if [ -f ~/.hp-server.env ]; then set -a; . ~/.hp-server.env; set +a; fi
CJ=$(mktemp); trap "rm -f $CJ" EXIT
curl -s -c "$CJ" --data-urlencode "username=$HP_AUTH_USER" --data-urlencode "password=$HP_AUTH_PASS" -o /dev/null https://app.rofihosted.space/login/submit

echo "--- Pancasila-Etika with branch=main (should fall back to master) ---"
curl -s -b "$CJ" -H 'Content-Type: application/json' \
  -d '{"repo_url":"https://github.com/rofiperlungoding/Pancasila-Etika","branch":"main"}' \
  https://app.rofihosted.space/api/projects/preview-repo | python3 -m json.tool 2>&1 | head -20
