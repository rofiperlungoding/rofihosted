#!/usr/bin/env bash
# Integration smoke test: boot the built hp-server against a throwaway HOME and
# assert it actually serves. Catches runtime/init/route regressions that a
# build-only CI misses. Usage: scripts/smoke-test.sh <path-to-hp-server-binary>
# Exits non-zero on any failure. Safe to run in CI (no external services needed;
# AI/email/telegram simply stay disabled without keys).
set -u

BIN="${1:?usage: smoke-test.sh <binary>}"
WORK="$(mktemp -d)"
export HOME="$WORK"
mkdir -p "$WORK/logs"
BASE="http://127.0.0.1:8080"

"$BIN" > "$WORK/logs/server.log" 2>&1 &
PID=$!

cleanup() { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# Wait up to 30s for /health.
up=0
for _ in $(seq 1 30); do
  if curl -fsS -m 2 "$BASE/health" >/dev/null 2>&1; then up=1; break; fi
  if ! kill -0 "$PID" 2>/dev/null; then echo "FAIL: server process exited during startup"; break; fi
  sleep 1
done
if [ "$up" != 1 ]; then
  echo "FAIL: server did not become healthy within 30s"
  echo "----- server.log -----"; cat "$WORK/logs/server.log" || true
  exit 1
fi

pass=0; fail=0
chk() { # name, command
  if eval "$2" >/dev/null 2>&1; then echo "PASS  $1"; pass=$((pass+1));
  else echo "FAIL  $1"; fail=$((fail+1)); fi
}

chk "/health returns ok"            "curl -fsS -m3 $BASE/health | grep -q ok"
chk "apex landing 200"              "curl -fsS -m3 -H 'Host: rofihosted.space' $BASE/"
chk "static theme.css served"       "curl -fsS -m3 -H 'Host: rofihosted.space' $BASE/theme.css"
chk "status /api/status json"       "curl -fsS -m3 -H 'Host: status.rofihosted.space' $BASE/api/status | grep -q overall"
chk "admin host needs auth (no 5xx)" "curl -s -m3 -o /dev/null -w '%{http_code}' -H 'Host: admin.rofihosted.space' $BASE/ | grep -qE '^(200|302|401|403)$'"

echo "----- smoke: pass=$pass fail=$fail -----"
[ "$fail" -eq 0 ]
