#!/data/data/com.termux/files/usr/bin/sh
# End-to-end test of Phase B: create a project from a public repo, deploy,
# verify the served HTML matches what's in the repo, then test the GitHub
# webhook by HMAC-signing a fake push payload and posting it.
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

# Use a small known-stable repo with an obvious index.html.
# We use rofiperlungoding/rofihosted itself (this repo) as a worst-case
# (large) test - but with publish_dir pointing at zig/hello which doesn't
# exist. Better: use a tiny upstream demo. Fall back on operator's own
# rofihosted README if no demo repo exists.
REPO_URL="https://github.com/rofiperlungoding/rofihosted"
SUB="depb-$(date +%s)"

echo "--- create project ---"
RESP=$(curl -s -b "$CJ" \
  --data-urlencode "name=Deploy phase B test" \
  --data-urlencode "subdomain=$SUB" \
  --data-urlencode "runtime=static" \
  --data-urlencode "repo_url=$REPO_URL" \
  --data-urlencode "branch=main" \
  --data-urlencode "publish_dir=" \
  "$BASE/api/projects/create")
echo "$RESP"
PID=$(echo "$RESP" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
echo "project id: $PID"

echo
echo "--- trigger deploy ---"
curl -s -b "$CJ" --data-urlencode "id=$PID" "$BASE/api/projects/deploy"
echo
echo "deploy queued; polling for completion..."

# Poll project status until it's running or failed.
DEADLINE=$(($(date +%s) + 90))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  STATE=$(curl -s -b "$CJ" "$BASE/api/projects" | grep -o "\"id\":\"$PID\",[^}]*\"status\":\"[^\"]*\"" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
  echo "  status: $STATE"
  case "$STATE" in
    running|failed|stopped) break;;
  esac
  sleep 3
done

echo
echo "--- last 1KB of build log ---"
curl -s -b "$CJ" "$BASE/api/projects/logs?id=$PID" | python3 -c '
import sys, json
d = json.loads(sys.stdin.read())
print(d.get("log", "")[-1024:])
' || true

echo
echo "--- fetch deployed URL (root) ---"
curl -s -o /dev/null -w 'http=%{http_code} size=%{size_download}\n' "https://$SUB.rofihosted.space/"

echo
echo "--- fetch a known file (README.md) ---"
curl -s -o /dev/null -w 'http=%{http_code} size=%{size_download}\n' "https://$SUB.rofihosted.space/README.md"

echo
echo "--- find webhook secret ---"
SECRET=$(grep -oE "\"id\":\"$PID\"[^}]*\"webhook_secret\":\"[^\"]*\"" ~/.hp-server-projects.jsonl | sed -n 's/.*"webhook_secret":"\([^"]*\)".*/\1/p')
echo "secret prefix: $(echo "$SECRET" | head -c 12)..."

echo
echo "--- simulate GitHub push webhook (HMAC verified) ---"
PAYLOAD='{"ref":"refs/heads/main","head_commit":{"id":"abc123"}}'
SIG=$(python3 -c "
import hmac, hashlib, sys
secret = '$SECRET'.encode()
body = '''$PAYLOAD'''.encode()
print(hmac.new(secret, body, hashlib.sha256).hexdigest())
")
echo "computed sig: $SIG"
curl -s \
  -H "X-Hub-Signature-256: sha256=$SIG" \
  -H "X-GitHub-Event: push" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$BASE/v1/github/$PID"
echo
echo "(if 'triggered:true', a redeploy started in the background)"

echo
echo "--- bad signature should 401 ---"
curl -s -o /dev/null -w 'http=%{http_code}\n' \
  -H "X-Hub-Signature-256: sha256=0000000000000000000000000000000000000000000000000000000000000000" \
  -H "X-GitHub-Event: push" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$BASE/v1/github/$PID"

echo
echo "--- cleanup: delete project ---"
curl -s -b "$CJ" --data-urlencode "id=$PID" "$BASE/api/projects/delete"
echo
rm -rf ~/data/projects/$PID
