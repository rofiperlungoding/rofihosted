#!/data/data/com.termux/files/usr/bin/sh
# Test the preview-repo endpoint (framework auto-detection).
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

echo "--- detect: rivex (TypeScript/Vite project) ---"
curl -s -b "$CJ" -H 'Content-Type: application/json' \
  -d '{"repo_url":"https://github.com/rofiperlungoding/rivex","branch":"main"}' \
  "$BASE/api/projects/preview-repo" | python3 -c 'import json,sys;d=json.loads(sys.stdin.read());print(json.dumps(d,indent=2) if d.get("ok") else "ERROR: "+str(d))'

echo
echo "--- detect: rofihosted (no framework, has README) ---"
curl -s -b "$CJ" -H 'Content-Type: application/json' \
  -d '{"repo_url":"https://github.com/rofiperlungoding/rofihosted","branch":"main"}' \
  "$BASE/api/projects/preview-repo" | python3 -c 'import json,sys;d=json.loads(sys.stdin.read());print(json.dumps(d,indent=2) if d.get("ok") else "ERROR: "+str(d))'

echo
echo "--- tables endpoint (empty project) ---"
curl -s -b "$CJ" "$BASE/api/projects/tables?id=0000000000000000"
echo
