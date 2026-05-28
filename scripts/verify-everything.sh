#!/data/data/com.termux/files/usr/bin/sh
# Comprehensive smoke test - hits every project-related endpoint and verifies
# the response shape. Reports PASS/FAIL per endpoint so we know exactly
# what's working and what's not.
set +e

if [ -f ~/.hp-server.env ]; then set -a; . ~/.hp-server.env; set +a; fi

BASE="https://app.rofihosted.space"
CJ=$(mktemp); trap "rm -f $CJ" EXIT

# Login
HTTP=$(curl -s -c "$CJ" -o /dev/null -w '%{http_code}' \
  --data-urlencode "username=$HP_AUTH_USER" \
  --data-urlencode "password=$HP_AUTH_PASS" \
  "$BASE/login/submit")
if [ "$HTTP" != "302" ]; then
  echo "FAIL: login (got $HTTP)"
  exit 1
fi
echo "PASS: login"

# Helper: hit endpoint, check ok:true in response
check() {
  local label="$1"
  local method="$2"
  local url="$3"
  local data="$4"
  local content_type="${5:-application/x-www-form-urlencoded}"
  local body
  if [ "$method" = "GET" ]; then
    body=$(curl -s -b "$CJ" "$url")
  else
    body=$(curl -s -b "$CJ" -X "$method" -H "Content-Type: $content_type" -d "$data" "$url")
  fi
  if echo "$body" | grep -q '"ok":true'; then
    echo "PASS: $label"
    return 0
  else
    echo "FAIL: $label"
    echo "      response: $(echo "$body" | head -c 200)"
    return 1
  fi
}

echo
echo "=== READ ENDPOINTS ==="
check "GET /api/projects" GET "$BASE/api/projects"
check "GET /api/dbcache/stats" GET "$BASE/api/dbcache/stats"
check "GET /api/dbpool/stats" GET "$BASE/api/dbpool/stats"
check "GET /api/apikeys" GET "$BASE/api/apikeys"
check "GET /api/webhooks" GET "$BASE/api/webhooks"
check "GET /api/rules" GET "$BASE/api/rules"
check "GET /api/audit" GET "$BASE/api/audit"
# /api/me uses {username} not {ok:true}
RESP=$(curl -s -b "$CJ" "$BASE/api/me")
if echo "$RESP" | grep -q '"username"'; then echo "PASS: GET /api/me"; else echo "FAIL: GET /api/me -> $RESP"; fi

echo
echo "=== WRITE/CREATE ENDPOINTS (lifecycle test) ==="
SUB="verify$(date +%s)"

# Create
RESP=$(curl -s -b "$CJ" -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "name=Verify $SUB" \
  --data-urlencode "subdomain=$SUB" \
  --data-urlencode "runtime=static" \
  --data-urlencode "branch=main" \
  "$BASE/api/projects/create")
PID=$(echo "$RESP" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
if [ -n "$PID" ]; then echo "PASS: POST /api/projects/create (id=$PID)"; else echo "FAIL: POST /api/projects/create -> $RESP"; exit 1; fi

# Set secret
check "POST /api/projects/secrets/set" POST "$BASE/api/projects/secrets/set" \
  "project_id=$PID&key=TEST_KEY&value=test_value"

# List secrets
RESP=$(curl -s -b "$CJ" "$BASE/api/projects/secrets/list?id=$PID")
if echo "$RESP" | grep -q 'TEST_KEY'; then echo "PASS: GET /api/projects/secrets/list (sees TEST_KEY)"; else echo "FAIL: GET /api/projects/secrets/list -> $RESP"; fi

# Delete secret
check "POST /api/projects/secrets/delete" POST "$BASE/api/projects/secrets/delete" \
  "project_id=$PID&key=TEST_KEY"

# Tables (empty DB so tables list returns empty)
check "GET /api/projects/tables" GET "$BASE/api/projects/tables?id=$PID"
check "GET /api/projects/users" GET "$BASE/api/projects/users?id=$PID"
check "GET /api/projects/releases" GET "$BASE/api/projects/releases?id=$PID"
check "GET /api/projects/cron/list" GET "$BASE/api/projects/cron/list?project_id=$PID"

# SQL runner
check "POST /api/projects/sql (CREATE TABLE)" POST "$BASE/api/projects/sql" \
  "{\"project_id\":\"$PID\",\"sql\":\"CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT);\"}" \
  "application/json"

check "POST /api/projects/sql (INSERT)" POST "$BASE/api/projects/sql" \
  "{\"project_id\":\"$PID\",\"sql\":\"INSERT INTO notes(body) VALUES('hello');\"}" \
  "application/json"

check "POST /api/projects/sql (SELECT)" POST "$BASE/api/projects/sql" \
  "{\"project_id\":\"$PID\",\"sql\":\"SELECT * FROM notes;\"}" \
  "application/json"

# Now table list should show notes
RESP=$(curl -s -b "$CJ" "$BASE/api/projects/tables?id=$PID")
if echo "$RESP" | grep -q 'notes'; then echo "PASS: GET /api/projects/tables (sees notes table)"; else echo "FAIL: tables -> $RESP"; fi

# Cron task
RESP=$(curl -s -b "$CJ" -X POST \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "project_id=$PID" \
  --data-urlencode "name=hb" \
  --data-urlencode "schedule=every 1h" \
  --data-urlencode "command=echo test" \
  "$BASE/api/projects/cron/create")
TID=$(echo "$RESP" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
if [ -n "$TID" ]; then echo "PASS: POST /api/projects/cron/create"; else echo "FAIL: $RESP"; fi
[ -n "$TID" ] && check "POST /api/projects/cron/run" POST "$BASE/api/projects/cron/run" "id=$TID"
[ -n "$TID" ] && check "POST /api/projects/cron/delete" POST "$BASE/api/projects/cron/delete" "id=$TID"

# Update
check "POST /api/projects/update" POST "$BASE/api/projects/update" \
  "id=$PID&name=Verify Renamed&build_cmd=echo built"

# Auth signup (built-in per-project auth)
check "POST <sub>/auth/signup" POST "https://$SUB.rofihosted.space/auth/signup" \
  '{"email":"test@example.com","password":"longenoughpw"}' \
  "application/json"

check "POST <sub>/auth/login" POST "https://$SUB.rofihosted.space/auth/login" \
  '{"email":"test@example.com","password":"longenoughpw"}' \
  "application/json"

# Now users endpoint should return 1 user
RESP=$(curl -s -b "$CJ" "$BASE/api/projects/users?id=$PID")
if echo "$RESP" | grep -q 'test@example.com'; then echo "PASS: GET /api/projects/users (sees test@example.com)"; else echo "FAIL: users -> $RESP"; fi

# Cleanup
check "POST /api/projects/delete" POST "$BASE/api/projects/delete" "id=$PID"
rm -rf ~/data/projects/$PID ~/data/dbs/$PID.db

echo
echo "=== AI ENDPOINTS ==="
RESP=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/json' \
  -d '{"repo_url":"https://github.com/rofiperlungoding/rivex","branch":"main"}' \
  "$BASE/api/projects/preview-repo")
if echo "$RESP" | grep -q '"ok":true'; then echo "PASS: POST /api/projects/preview-repo (rivex)"; else echo "FAIL: preview-repo -> $RESP"; fi

# AI analyze (longer, costs tokens, only run if explicitly enabled)
if [ "${RUN_AI_TEST:-no}" = "yes" ]; then
  RESP=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/json' \
    -d '{"repo_url":"https://github.com/rofiperlungoding/rivex","branch":"main"}' \
    "$BASE/api/projects/analyze")
  if echo "$RESP" | grep -q '"ok":true'; then echo "PASS: POST /api/projects/analyze (rivex)"; else echo "FAIL: analyze -> $RESP"; fi
else
  echo "SKIP: POST /api/projects/analyze (set RUN_AI_TEST=yes to run; uses tokens)"
fi

echo
echo "=== INFRA ==="
HTTP=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/health"); [ "$HTTP" = "200" ] && echo "PASS: /health" || echo "FAIL: /health ($HTTP)"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' "https://rofihosted.space/"); [ "$HTTP" = "200" ] && echo "PASS: apex landing" || echo "FAIL: apex ($HTTP)"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' -L "$BASE/login"); [ "$HTTP" = "200" ] && echo "PASS: /login page" || echo "FAIL: login page ($HTTP)"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' -L "$BASE/projects"); [ "$HTTP" = "200" ] && echo "PASS: /projects page" || echo "FAIL: projects page ($HTTP)"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' -L "$BASE/security"); [ "$HTTP" = "200" ] && echo "PASS: /security page" || echo "FAIL: security page ($HTTP)"
HTTP=$(curl -s -o /dev/null -w '%{http_code}' -L "$BASE/settings"); [ "$HTTP" = "200" ] && echo "PASS: /settings page" || echo "FAIL: settings page ($HTTP)"

echo
echo "=== DONE ==="
