#!/data/data/com.termux/files/usr/bin/sh
# End-to-end test: create a project via API, set 2 secrets, list, deploy a
# static index, verify it serves through Cloudflare, then clean up.
set -e

if [ -f ~/.hp-server.env ]; then
  set -a
  . ~/.hp-server.env
  set +a
fi

BASE="https://app.rofihosted.space"
CJ=$(mktemp)
trap "rm -f $CJ" EXIT

curl -s -c "$CJ" \
  --data-urlencode "username=$HP_AUTH_USER" \
  --data-urlencode "password=$HP_AUTH_PASS" \
  -o /dev/null \
  "$BASE/login/submit"

# Pick a unique subdomain so re-runs don't conflict.
SUB="lab$(date +%s)"
echo "--- create project sub=$SUB ---"
RESP=$(curl -s -b "$CJ" \
  --data-urlencode "name=Test lab" \
  --data-urlencode "subdomain=$SUB" \
  --data-urlencode "runtime=static" \
  --data-urlencode "repo_url=" \
  --data-urlencode "branch=main" \
  "$BASE/api/projects/create")
echo "$RESP"
PID=$(echo "$RESP" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
echo "project id: $PID"
if [ -z "$PID" ]; then
  echo "FAIL: no id" >&2
  exit 1
fi

echo
echo "--- set 2 secrets ---"
curl -s -b "$CJ" --data-urlencode "project_id=$PID" --data-urlencode "key=API_KEY" --data-urlencode "value=sk-deadbeef" "$BASE/api/projects/secrets/set"
echo
curl -s -b "$CJ" --data-urlencode "project_id=$PID" --data-urlencode "key=DATABASE_URL" --data-urlencode "value=postgres://localhost:5432/x" "$BASE/api/projects/secrets/set"
echo

echo
echo "--- list secrets ---"
curl -s -b "$CJ" "$BASE/api/projects/secrets/list?id=$PID"
echo

echo
echo "--- inspect vault on disk (encrypted) ---"
ls -la ~/data/projects/$PID/secrets.bin
echo "first 20 hex bytes:"
head -c 20 ~/data/projects/$PID/secrets.bin | od -A n -t x1 | head -1

echo
echo "--- deploy a fake static release ---"
mkdir -p ~/data/projects/$PID/releases/v1
cat > ~/data/projects/$PID/releases/v1/index.html << EOF
<!doctype html>
<html><head><meta charset=utf-8><title>$SUB.rofihosted.space</title></head>
<body><h1>$SUB</h1><p>Project id: $PID</p><p>Deployed via API.</p></body></html>
EOF
ln -sfn ~/data/projects/$PID/releases/v1 ~/data/projects/$PID/current
echo "current symlink:"
ls -la ~/data/projects/$PID/current

echo
echo "--- fetch the public URL ---"
sleep 2
curl -s "https://$SUB.rofihosted.space/"
echo
echo "http status:"
curl -s -o /dev/null -w '%{http_code}\n' "https://$SUB.rofihosted.space/"

echo
echo "--- delete a secret ---"
curl -s -b "$CJ" --data-urlencode "project_id=$PID" --data-urlencode "key=API_KEY" "$BASE/api/projects/secrets/delete"
echo

echo
echo "--- list keys after delete ---"
curl -s -b "$CJ" "$BASE/api/projects/secrets/list?id=$PID"
echo

echo
echo "--- delete the project ---"
curl -s -b "$CJ" --data-urlencode "id=$PID" "$BASE/api/projects/delete"
echo

echo
echo "--- list projects after delete (should be gone) ---"
curl -s -b "$CJ" "$BASE/api/projects" | head -c 400
echo

# Clean up the working dir we created (delete only removes the registry entry)
rm -rf ~/data/projects/$PID
