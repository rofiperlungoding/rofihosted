#!/data/data/com.termux/files/usr/bin/sh
# End-to-end Phase C: create a backend project, deploy it (no repo, just a
# tiny start_cmd that hot-cooks an HTTP server), start it via supervisor,
# verify the public subdomain proxies to it, kill it, watch auto-restart.
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

SUB="be$(date +%s)"

echo "--- create node project ---"
RESP=$(curl -s -b "$CJ" \
  --data-urlencode "name=Backend test" \
  --data-urlencode "subdomain=$SUB" \
  --data-urlencode "runtime=node" \
  --data-urlencode "repo_url=" \
  --data-urlencode "branch=main" \
  --data-urlencode "install_cmd=" \
  --data-urlencode "build_cmd=" \
  --data-urlencode 'start_cmd=node -e "const http=require(\"http\");const port=Number(process.env.PORT||3000);http.createServer((q,r)=>{r.writeHead(200,{\"content-type\":\"application/json\"});r.end(JSON.stringify({hello:\"world\",port,id:process.env.ROFI_PROJECT_ID,sub:process.env.ROFI_SUBDOMAIN,custom:process.env.MY_SECRET||null,path:q.url}))}).listen(port,\"127.0.0.1\",()=>console.log(\"listening on \"+port))"' \
  "$BASE/api/projects/create")
echo "$RESP"
PID=$(echo "$RESP" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
PORT=$(echo "$RESP" | sed -n 's/.*"port":\([0-9]*\).*/\1/p')
echo "project id: $PID, port: $PORT"

echo
echo "--- set a secret ---"
curl -s -b "$CJ" --data-urlencode "project_id=$PID" --data-urlencode "key=MY_SECRET" --data-urlencode "value=hello-from-vault" "$BASE/api/projects/secrets/set"
echo

# Pre-create the project working dir / repo dir so start can run without a
# real repo (we have no install/build, the start_cmd is self-contained).
mkdir -p ~/data/projects/$PID/repo

echo
echo "--- start the project ---"
curl -s -b "$CJ" --data-urlencode "id=$PID" "$BASE/api/projects/start"
echo
sleep 3

echo "--- supervisor status ---"
curl -s -b "$CJ" "$BASE/api/projects/status?id=$PID"
echo

echo
echo "--- direct localhost probe ---"
curl -s -o /dev/null -w 'http=%{http_code}\n' "http://127.0.0.1:$PORT/probe"

echo "--- runtime log (should show 'listening on N') ---"
curl -s -b "$CJ" "$BASE/api/projects/runtime-logs?id=$PID" | python3 -c '
import sys, json
print(json.loads(sys.stdin.read()).get("log", "")[-512:])
' || true

echo
echo "--- public URL through Cloudflare ---"
sleep 2
curl -s "https://$SUB.rofihosted.space/some/path"
echo
echo "expected: hello/world JSON, port=$PORT, custom=hello-from-vault, path=/some/path"

echo
echo "--- kill the child to test auto-restart ---"
PID_ALIVE=$(curl -s -b "$CJ" "$BASE/api/projects/status?id=$PID" | sed -n 's/.*"pid":\([0-9]*\).*/\1/p')
echo "child pid: $PID_ALIVE"
if [ -n "$PID_ALIVE" ]; then
  # Kill the underlying node process (supervisor sees the sh wrapper). Find children of sh.
  pkill -P "$PID_ALIVE" 2>/dev/null || true
  kill "$PID_ALIVE" 2>/dev/null || true
fi
echo "killed; waiting 12s for auto-restart loop to respawn..."
sleep 12

echo "--- status after auto-restart ---"
curl -s -b "$CJ" "$BASE/api/projects/status?id=$PID"
echo

echo "--- public URL after auto-restart ---"
curl -s -o /dev/null -w 'http=%{http_code}\n' "https://$SUB.rofihosted.space/"

echo
echo "--- stop the project ---"
curl -s -b "$CJ" --data-urlencode "id=$PID" "$BASE/api/projects/stop"
echo

echo
echo "--- public URL after stop (should 503) ---"
sleep 1
curl -s -o /dev/null -w 'http=%{http_code}\n' "https://$SUB.rofihosted.space/"

echo
echo "--- cleanup ---"
curl -s -b "$CJ" --data-urlencode "id=$PID" "$BASE/api/projects/delete"
echo
rm -rf ~/data/projects/$PID
