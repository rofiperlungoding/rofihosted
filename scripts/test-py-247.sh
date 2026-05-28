#!/data/data/com.termux/files/usr/bin/bash
# End-to-end test: deploy a Python app that runs an HTTP server AND a
# background "AI worker" thread, then verify both are running.
set +e
[ -f ~/.hp-server.env ] && { set -a; . ~/.hp-server.env; set +a; }

BASE="https://app.rofihosted.space"
CJ=$(mktemp); trap "rm -f $CJ" EXIT
SUB="ai247"
NAME="ai247-test"

# --- Login ---
HTTP=$(curl -s -c "$CJ" -o /dev/null -w '%{http_code}' \
  --data-urlencode "username=$HP_AUTH_USER" \
  --data-urlencode "password=$HP_AUTH_PASS" \
  "$BASE/login/submit")
[ "$HTTP" != "302" ] && { echo "FAIL login -> $HTTP"; exit 1; }
echo "login OK"

# --- Cleanup any previous test run ---
PREV_ID=$(curl -s -b "$CJ" "$BASE/api/projects" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for p in data.get('projects', []):
    if p['subdomain'] == '$SUB':
        print(p['id']); break
")
if [ -n "$PREV_ID" ]; then
  echo "purging previous test project $PREV_ID"
  curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data "id=$PREV_ID&purge=true" "$BASE/api/projects/delete" >/dev/null
fi

# --- Create project (no repo_url, we'll sideload code) ---
RESP=$(curl -s -b "$CJ" -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "name=$NAME" \
  --data-urlencode "subdomain=$SUB" \
  --data-urlencode "runtime=python" \
  --data-urlencode "install_cmd=" \
  --data-urlencode "build_cmd=" \
  --data-urlencode "start_cmd=python3 app.py" \
  "$BASE/api/projects/create")
echo "create -> $RESP"
PID=$(echo "$RESP" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))")
[ -z "$PID" ] && { echo "FAIL: no id"; exit 1; }
echo "project id = $PID"

# --- Write the Python app directly into the project repo dir ---
REPO_DIR=~/data/projects/$PID/repo
mkdir -p "$REPO_DIR"

cat > "$REPO_DIR/app.py" << 'PYEOF'
"""
Test backend: HTTP API + background AI worker.

- HTTP server on $PORT (provided by rofihosted) returns JSON status
- Background thread runs every 5 seconds, simulating AI work
- All work persisted to state.json so we can verify continuity
"""
import http.server
import json
import os
import socketserver
import sys
import threading
import time
from datetime import datetime

PORT = int(os.environ.get("PORT", "8000"))
STATE_FILE = os.path.join(os.path.dirname(__file__), "state.json")

state = {
    "started_at": datetime.utcnow().isoformat() + "Z",
    "tick_count": 0,
    "last_tick_at": None,
    "ai_results": [],
    "uptime_s": 0,
}
state_lock = threading.Lock()
boot_time = time.time()


def save_state():
    try:
        with open(STATE_FILE, "w") as f:
            json.dump(state, f, indent=2)
    except Exception as e:
        print(f"[!] state save failed: {e}", flush=True)


def ai_worker():
    """Simulates a continuous AI loop: every 5s pretend to do inference."""
    print("[ai_worker] thread started", flush=True)
    while True:
        try:
            time.sleep(5)
            with state_lock:
                state["tick_count"] += 1
                state["last_tick_at"] = datetime.utcnow().isoformat() + "Z"
                state["uptime_s"] = int(time.time() - boot_time)
                # Pretend we just ran an AI inference
                fake_result = {
                    "tick": state["tick_count"],
                    "answer": f"AI thought #{state['tick_count']}: hello from rofihosted",
                    "ts": state["last_tick_at"],
                }
                state["ai_results"].append(fake_result)
                # Keep only last 5 results
                state["ai_results"] = state["ai_results"][-5:]
                save_state()
            print(f"[ai_worker] tick {state['tick_count']} done", flush=True)
        except Exception as e:
            print(f"[ai_worker] error: {e}", flush=True)
            time.sleep(2)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with state_lock:
            state["uptime_s"] = int(time.time() - boot_time)
            body = json.dumps(state, indent=2).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # Quieter logs
        sys.stderr.write("[http] %s - %s\n" % (self.address_string(), fmt % args))


def main():
    print(f"[main] starting on 127.0.0.1:{PORT}", flush=True)
    t = threading.Thread(target=ai_worker, daemon=True)
    t.start()
    with socketserver.ThreadingTCPServer(("127.0.0.1", PORT), Handler) as httpd:
        print(f"[main] HTTP serving on :{PORT}", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    main()
PYEOF

# Empty requirements (stdlib only)
echo "" > "$REPO_DIR/requirements.txt"

echo "code written to $REPO_DIR"
ls -la "$REPO_DIR"

# --- Trigger deploy (will run install_cmd which is empty, then start ---
echo
echo "=== triggering deploy ==="
curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
  --data "id=$PID" "$BASE/api/projects/deploy"
echo

# --- Wait for deploy to finish + start to complete ---
echo
echo "=== waiting 10s for deploy + start ==="
for i in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  printf "."
done
echo

# --- Check supervisor status ---
echo
echo "=== /api/projects (status) ==="
curl -s -b "$CJ" "$BASE/api/projects" | python3 -c "
import sys, json
for p in json.load(sys.stdin)['projects']:
    if p['id'] == '$PID':
        print(f\"  status: {p['status']}\")
        print(f\"  port: {p['port']}\")
"

# --- Hit the public URL through Cloudflare tunnel ---
echo
echo "=== hitting public URL https://$SUB.rofihosted.space/ ==="
curl -s --max-time 10 "https://$SUB.rofihosted.space/" | head -c 500
echo

# --- Wait 12 more seconds, then hit again to verify tick_count grew ---
echo
echo "=== sleeping 12s to let AI worker tick a few times ==="
sleep 12

echo
echo "=== second hit (tick_count should be > 0) ==="
curl -s --max-time 10 "https://$SUB.rofihosted.space/" | head -c 500
echo

# --- Show runtime logs proving the worker is running ---
echo
echo "=== runtime logs ==="
curl -s -b "$CJ" "$BASE/api/projects/runtime-logs?id=$PID" | python3 -c "
import sys, json
data = json.load(sys.stdin)
log = data.get('log', '')
print(log[-1500:] if len(log) > 1500 else log)
"

# --- Show state.json proving persistence ---
echo
echo "=== state.json on disk ==="
cat ~/data/projects/$PID/repo/state.json 2>/dev/null

echo
echo "=== TEST DONE ==="
echo "Project ID: $PID"
echo "URL: https://$SUB.rofihosted.space/"
echo "Cleanup: curl -b $CJ -X POST -d 'id=$PID&purge=true' $BASE/api/projects/delete"
