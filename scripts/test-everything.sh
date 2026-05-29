#!/data/data/com.termux/files/usr/bin/sh
# Comprehensive end-to-end test of every operator-facing feature.
# Hits every documented endpoint and verifies the response shape.
#
# Reports PASS/FAIL per feature so we know exactly what works.
# Designed to run on the phone via /shell or SSH.

set +e
[ -f ~/.hp-server.env ] && { set -a; . ~/.hp-server.env; set +a; }

BASE="https://app.rofihosted.space"
CJ=$(mktemp); trap "rm -f $CJ" EXIT
PASS=0
FAIL=0

# Helpers
pass() { echo "PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL  $1${2:+  -- $2}"; FAIL=$((FAIL + 1)); }
sect() { echo; echo "=== $1 ==="; }

check_ok() {
    # check_ok "label" "json response"
    if echo "$2" | grep -q '"ok":true'; then pass "$1"; else fail "$1" "$2"; fi
}

check_status() {
    # check_status "label" "url" "expected_code"
    code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "$2")
    if [ "$code" = "$3" ]; then pass "$1"; else fail "$1" "got $code, expected $3"; fi
}

# -----------------------------------------------------------------------------
sect "AUTH"

HTTP=$(curl -s -c "$CJ" -o /dev/null -w '%{http_code}' \
    --data-urlencode "username=$HP_AUTH_USER" \
    --data-urlencode "password=$HP_AUTH_PASS" \
    "$BASE/login/submit")
[ "$HTTP" = "302" ] && pass "session login" || { fail "session login" "got $HTTP"; exit 1; }

# Create an admin-scoped API key for v1 endpoint tests
KEY_RESP=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "name=test-everything-$(date +%s)" \
    --data-urlencode "scopes=admin" \
    "$BASE/api/apikeys/create")
KEY=$(echo "$KEY_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))')
[ -n "$KEY" ] && pass "admin API key created" || { fail "admin API key created" "$KEY_RESP"; exit 1; }
KEY_ID=$(echo "$KEY_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))')

# Cleanup the key on exit
trap "rm -f $CJ; curl -s -b '$CJ' -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode 'id=$KEY_ID' '$BASE/api/apikeys/revoke' >/dev/null 2>&1" EXIT

# -----------------------------------------------------------------------------
sect "INFRA HEALTH"

check_status "GET /health" "$BASE/health" "200"
check_status "GET / (apex)" "https://rofihosted.space/" "200"
check_status "GET /login" "$BASE/login" "200"

# Authenticated pages
HTTP=$(curl -sk -b "$CJ" -o /dev/null -w '%{http_code}' "$BASE/")
[ "$HTTP" = "200" ] && pass "GET / (overview)" || fail "GET / (overview)" "got $HTTP"

for page in projects security settings shell status files api; do
    HTTP=$(curl -sk -b "$CJ" -o /dev/null -w '%{http_code}' "$BASE/$page")
    [ "$HTTP" = "200" ] && pass "GET /$page" || fail "GET /$page" "got $HTTP"
done

# -----------------------------------------------------------------------------
sect "SYSTEM ENDPOINTS (cookie auth)"

R=$(curl -s -b "$CJ" "$BASE/api/system/info"); check_ok "GET /api/system/info" "$R"
R=$(curl -s -b "$CJ" "$BASE/api/system/power"); check_ok "GET /api/system/power" "$R"
R=$(curl -s -b "$CJ" "$BASE/api/system/version"); check_ok "GET /api/system/version" "$R"
R=$(curl -s -b "$CJ" "$BASE/api/system/backups"); check_ok "GET /api/system/backups" "$R"
R=$(curl -s -b "$CJ" -X POST "$BASE/api/system/backup?target=local"); check_ok "POST /api/system/backup local" "$R"

# Restore-test (validates a real tarball is restorable)
R=$(curl -s -b "$CJ" -X POST "$BASE/api/system/restore-test?source=local"); check_ok "POST /api/system/restore-test local" "$R"

# Shell exec (the killer feature - replaces SSH)
R=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/json' -d '{"cmd":"echo hello"}' "$BASE/api/system/exec")
if echo "$R" | grep -q '"stdout":"hello'; then pass "POST /api/system/exec (echo)"; else fail "POST /api/system/exec (echo)" "$R"; fi

# Verify timeout enforcement
R=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/json' -d '{"cmd":"sleep 5","timeout_ms":500}' "$BASE/api/system/exec")
if echo "$R" | grep -q '"timed_out":true'; then pass "POST /api/system/exec (timeout)"; else fail "POST /api/system/exec (timeout)" "$R"; fi

# -----------------------------------------------------------------------------
sect "V1 ENDPOINTS (X-API-Key auth, admin scope)"

R=$(curl -s -H "X-API-Key: $KEY" "$BASE/v1/whoami"); check_ok "GET /v1/whoami" "$R"
R=$(curl -s -H "X-API-Key: $KEY" "$BASE/v1/system/version"); check_ok "GET /v1/system/version" "$R"
R=$(curl -s -H "X-API-Key: $KEY" "$BASE/v1/system/info"); check_ok "GET /v1/system/info" "$R"
R=$(curl -s -H "X-API-Key: $KEY" "$BASE/v1/system/power"); check_ok "GET /v1/system/power" "$R"
R=$(curl -s -H "X-API-Key: $KEY" "$BASE/v1/projects"); check_ok "GET /v1/projects" "$R"

# Verify admin scope is enforced (sql-only key should be rejected)
SQL_KEY_RESP=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "name=test-sql-$(date +%s)" \
    --data-urlencode "scopes=sql" \
    "$BASE/api/apikeys/create")
SQL_KEY=$(echo "$SQL_KEY_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))')
SQL_KEY_ID=$(echo "$SQL_KEY_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))')
R=$(curl -s -H "X-API-Key: $SQL_KEY" "$BASE/v1/system/version")
if echo "$R" | grep -q '"err":"scope_required"'; then pass "scope enforcement (sql key rejected from system)"; else fail "scope enforcement" "$R"; fi
curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode "id=$SQL_KEY_ID" "$BASE/api/apikeys/revoke" >/dev/null

# -----------------------------------------------------------------------------
sect "PROJECT LIFECYCLE (full CRUD via v1)"

SUB="testall-$(date +%s)"
R=$(curl -s -H "X-API-Key: $KEY" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "name=$SUB" \
    --data-urlencode "subdomain=$SUB" \
    --data-urlencode "runtime=static" \
    "$BASE/v1/projects/create")
PID=$(echo "$R" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))')
[ -n "$PID" ] && pass "v1 projects create" || { fail "v1 projects create" "$R"; PID=""; }

if [ -n "$PID" ]; then
    # List should now include our project
    R=$(curl -s -H "X-API-Key: $KEY" "$BASE/v1/projects")
    if echo "$R" | grep -q "\"id\":\"$PID\""; then pass "v1 projects list (sees new project)"; else fail "v1 projects list (sees new)" "$R"; fi

    # Update with rss_limit_mb
    R=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode "id=$PID" \
        --data-urlencode "rss_limit_mb=256" \
        "$BASE/api/projects/update")
    check_ok "set rss_limit_mb=256" "$R"

    # Verify it persisted
    R=$(curl -s -H "X-API-Key: $KEY" "$BASE/v1/projects")
    if echo "$R" | grep -q '"rss_limit_mb":256'; then pass "rss_limit_mb persisted"; else fail "rss_limit_mb persisted" "$R"; fi

    # Status endpoint should expose RSS fields
    R=$(curl -s -H "X-API-Key: $KEY" "$BASE/v1/projects/status?id=$PID")
    if echo "$R" | grep -q '"rss_limit_mb":256'; then pass "v1 projects status (rss fields)"; else fail "v1 projects status" "$R"; fi
    if echo "$R" | grep -q '"last_kill_reason":"none"'; then pass "v1 projects status (kill_reason field)"; else fail "v1 projects status (kill_reason)" "$R"; fi

    # Stop / Start cycle (static project, just flips status)
    R=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode "id=$PID" "$BASE/api/projects/stop"); check_ok "stop static project" "$R"
    R=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode "id=$PID" "$BASE/api/projects/start"); check_ok "start static project" "$R"

    # Cleanup with purge
    R=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode "id=$PID" --data-urlencode "purge=true" "$BASE/api/projects/delete")
    check_ok "delete with purge" "$R"
fi

# -----------------------------------------------------------------------------
sect "STATIC DEPLOY VIA v1 UPLOAD"

# Build a tiny zip in memory
TMP_DIR=$(mktemp -d)
echo '<!doctype html><h1>test-everything live</h1>' > "$TMP_DIR/index.html"
ZIP="$TMP_DIR/site.zip"
(cd "$TMP_DIR" && zip -q "$ZIP" index.html)

SUB2="testdeploy-$(date +%s)"
# Create the project
R=$(curl -s -H "X-API-Key: $KEY" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "name=$SUB2" \
    --data-urlencode "subdomain=$SUB2" \
    --data-urlencode "runtime=static" \
    "$BASE/v1/projects/create")
PID2=$(echo "$R" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))')

if [ -n "$PID2" ]; then
    pass "v1 deploy: project created"
    # Upload zip
    R=$(curl -s -H "X-API-Key: $KEY" -X POST -H 'Content-Type: application/zip' --data-binary "@$ZIP" "$BASE/v1/projects/upload?id=$PID2")
    if echo "$R" | grep -q '"ok":true'; then
        pass "v1 deploy: upload"
        # Wait briefly for the deploy to settle
        sleep 2
        # Hit the public URL through Cloudflare
        BODY=$(curl -sk -m 10 "https://$SUB2.rofihosted.space/")
        if echo "$BODY" | grep -q "test-everything live"; then pass "v1 deploy: site reachable through CF"; else fail "v1 deploy: site reachable" "$BODY"; fi
    else
        fail "v1 deploy: upload" "$R"
    fi

    # Cleanup
    curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode "id=$PID2" --data-urlencode "purge=true" \
        "$BASE/api/projects/delete" >/dev/null
fi
rm -rf "$TMP_DIR"

# -----------------------------------------------------------------------------
sect "BACKUP PIPELINE"

# Trigger local backup
R=$(curl -s -b "$CJ" -X POST "$BASE/api/system/backup?target=local")
check_ok "POST /api/system/backup local" "$R"
SIZE=$(echo "$R" | python3 -c 'import sys,json,re; data = json.load(sys.stdin); m = re.search(r"size=(\S+)", data.get("stdout","")); print(m.group(1) if m else "?")')
echo "       (size: $SIZE)"

# List should show local backups
R=$(curl -s -b "$CJ" "$BASE/api/system/backups")
LOCAL_COUNT=$(echo "$R" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("local",[])))')
[ "$LOCAL_COUNT" -gt 0 ] && pass "local backups visible (count=$LOCAL_COUNT)" || fail "local backups visible" "$R"

# R2 backup if configured
R2_CONFIGURED=$(echo "$R" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("r2_configured",False))')
if [ "$R2_CONFIGURED" = "True" ]; then
    pass "R2 configured"
    R=$(curl -s -b "$CJ" -X POST "$BASE/api/system/backup?target=r2")
    check_ok "POST /api/system/backup r2" "$R"
    REMOTE_COUNT=$(curl -s -b "$CJ" "$BASE/api/system/backups" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("remote",[])))')
    [ "$REMOTE_COUNT" -gt 0 ] && pass "R2 backup visible (count=$REMOTE_COUNT)" || fail "R2 backup visible"
else
    echo "SKIP  R2 backup (not configured; run scripts/r2-setup.sh)"
fi

# -----------------------------------------------------------------------------
sect "POWERMON"

R=$(curl -s -H "X-API-Key: $KEY" "$BASE/v1/system/power")
PCT=$(echo "$R" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("percentage","?"))')
PLUGGED=$(echo "$R" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("is_plugged","?"))')
if [ "$PCT" != "?" ] && [ "$PCT" != "-1" ]; then pass "powermon: battery readable ($PCT% plugged=$PLUGGED)"; else fail "powermon: battery readable" "$R"; fi

# -----------------------------------------------------------------------------
sect "AUDIT TRAIL"

R=$(curl -s -b "$CJ" "$BASE/api/audit?limit=20")
if echo "$R" | grep -q '"ok":true'; then
    LINES=$(echo "$R" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("entries",[])))')
    pass "audit trail readable (recent $LINES entries)"
    # Verify our recent actions show up
    if echo "$R" | grep -q '"action":"system_backup"'; then pass "audit logs system_backup"; else fail "audit logs system_backup"; fi
    if echo "$R" | grep -q '"action":"project_create"'; then pass "audit logs project_create"; else fail "audit logs project_create"; fi
else
    fail "audit trail" "$R"
fi

# -----------------------------------------------------------------------------
sect "SUMMARY"

TOTAL=$((PASS + FAIL))
echo
echo "  $PASS / $TOTAL passed"
if [ $FAIL -gt 0 ]; then
    echo "  $FAIL failed"
    exit 1
fi
echo "  All green."
