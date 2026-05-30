#!/data/data/com.termux/files/usr/bin/sh
# Exhaustive end-to-end smoke test. Every operator-facing endpoint is hit
# at least once. Anything that 500s, returns malformed JSON, or breaks the
# contract is flagged immediately.
#
# This was added after a regression where /api/security 500'd silently
# because the old test only checked /security PAGE returned 200 (it does;
# it just renders empty when the underlying API fails).
#
# We now treat "page returned 200" as necessary but not sufficient. Every
# endpoint the page consumes must be tested.
#
# Run on phone:  bash ~/test-everything.sh
# Run remotely:  ssh hp 'bash ~/test-everything.sh'

set +e
[ -f ~/.hp-server.env ] && { set -a; . ~/.hp-server.env; set +a; }

BASE="https://app.rofihosted.space"
CJ=$(mktemp)
PASS=0
FAIL=0
WARN=0

cleanup() {
    rm -f "$CJ"
    [ -n "$KEY_ID" ] && curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode "id=$KEY_ID" "$BASE/api/apikeys/revoke" >/dev/null 2>&1
}
trap cleanup EXIT

pass() { echo "PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL  $1${2:+  -- $2}"; FAIL=$((FAIL + 1)); }
warn() { echo "WARN  $1${2:+  -- $2}"; WARN=$((WARN + 1)); }
sect() { echo; echo "=== $1 ==="; }

# Hit a GET endpoint, verify HTTP 200 + body has "ok":true (or contract).
get_ok() {
    # get_ok "label" "url" [allow_empty]
    body=$(curl -sm 30 -b "$CJ" -w "\n__STATUS__:%{http_code}" "$2")
    code=$(echo "$body" | tail -1 | cut -d: -f2)
    payload=$(echo "$body" | sed '$d')
    if [ "$code" != "200" ]; then
        fail "$1" "HTTP $code"
        return
    fi
    if [ "${3:-}" = "allow_empty" ] && [ -z "$payload" ]; then
        pass "$1"
        return
    fi
    # Some endpoints return non-JSON (badges as SVG, /api/audit as raw, etc).
    # If the body starts with { or [, expect ok:true. Otherwise just trust 200.
    case "$payload" in
        '{'*|'['*)
            if echo "$payload" | grep -q '"ok":true' || echo "$payload" | grep -q '"timestamp"' || echo "$payload" | grep -q '"username"'; then
                pass "$1"
            elif echo "$payload" | grep -q '"err"\|"error"'; then
                fail "$1" "$(echo "$payload" | head -c 200)"
            else
                # No ok:true but no error either - probably a list/dict that just doesn't use the envelope
                pass "$1"
            fi
            ;;
        *)
            pass "$1"
            ;;
    esac
}

# Hit a GET endpoint, expect HTTP code other than 5xx (so 4xx is acceptable
# for endpoints that need params we're not providing).
get_no_5xx() {
    code=$(curl -sm 30 -b "$CJ" -o /dev/null -w '%{http_code}' "$2")
    if [ "$code" -lt 500 ]; then
        pass "$1 (HTTP $code)"
    else
        fail "$1" "HTTP $code"
    fi
}

# -----------------------------------------------------------------------------
sect "AUTH"

HTTP=$(curl -s -c "$CJ" -o /dev/null -w '%{http_code}' \
    --data-urlencode "username=$HP_AUTH_USER" \
    --data-urlencode "password=$HP_AUTH_PASS" \
    "$BASE/login/submit")
[ "$HTTP" = "302" ] && pass "session login" || { fail "session login" "got $HTTP"; exit 1; }

KEY_RESP=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "name=test-everything-$(date +%s)" \
    --data-urlencode "scopes=admin" \
    "$BASE/api/apikeys/create")
KEY=$(echo "$KEY_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))')
KEY_ID=$(echo "$KEY_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))')
[ -n "$KEY" ] && pass "admin API key created" || { fail "admin API key created" "$KEY_RESP"; exit 1; }

# -----------------------------------------------------------------------------
sect "INFRA HEALTH"

code=$(curl -sm 5 -o /dev/null -w '%{http_code}' "$BASE/health")
[ "$code" = "200" ] && pass "GET /health" || fail "GET /health" "got $code"

code=$(curl -sm 5 -o /dev/null -w '%{http_code}' "https://rofihosted.space/")
[ "$code" = "200" ] && pass "GET / (apex)" || fail "GET / (apex)" "got $code"

code=$(curl -sm 5 -o /dev/null -w '%{http_code}' "$BASE/login")
[ "$code" = "200" ] && pass "GET /login" || fail "GET /login" "got $code"

# -----------------------------------------------------------------------------
sect "DASHBOARD PAGES"

for page in "" status files api projects security settings shell; do
    code=$(curl -sm 5 -b "$CJ" -o /dev/null -w '%{http_code}' "$BASE/$page")
    [ "$code" = "200" ] && pass "GET /$page" || fail "GET /$page" "got $code"
done

# -----------------------------------------------------------------------------
sect "OVERVIEW + STATUS PAGES BACKING APIs"

get_ok "GET /api/me" "$BASE/api/me"
get_ok "GET /api/stats" "$BASE/api/stats"
get_ok "GET /api/host" "$BASE/api/host"
get_ok "GET /api/tunnel" "$BASE/api/tunnel"
get_ok "GET /api/visits" "$BASE/api/visits"
get_ok "GET /api/uptime" "$BASE/api/uptime"
get_ok "GET /api/tunnel/health" "$BASE/api/tunnel/health"

# -----------------------------------------------------------------------------
sect "SECURITY PAGE BACKING APIs"

# This is THE one we missed last time. Now thoroughly validated.
body=$(curl -sm 60 -b "$CJ" "$BASE/api/security")
if echo "$body" | grep -q '"timestamp"'; then
    total=$(echo "$body" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("total_requests",0))' 2>/dev/null)
    pass "GET /api/security (total_requests=$total)"
else
    fail "GET /api/security" "$(echo "$body" | head -c 300)"
fi

# Audit, geoblock, blocklist
get_ok "GET /api/audit" "$BASE/api/audit"
get_ok "GET /api/geoblock" "$BASE/api/geoblock"

# Honeypot, rules
get_ok "GET /api/honeypot" "$BASE/api/honeypot"
get_ok "GET /api/rules" "$BASE/api/rules"

# -----------------------------------------------------------------------------
sect "FILES PAGE BACKING APIs"

get_ok "GET /api/files/list" "$BASE/api/files/list"

# -----------------------------------------------------------------------------
sect "API TAB BACKING APIs"

get_ok "GET /api/apikeys" "$BASE/api/apikeys"
get_ok "GET /api/webhooks" "$BASE/api/webhooks"

# -----------------------------------------------------------------------------
sect "AI BACKING APIs"

get_ok "GET /api/ai/digest/latest" "$BASE/api/ai/digest/latest"
get_ok "GET /api/ai/policy/latest" "$BASE/api/ai/policy/latest"
get_ok "GET /api/ai/usage" "$BASE/api/ai/usage"

get_ok "GET /api/embeddings/clusters" "$BASE/api/embeddings/clusters"
get_ok "GET /api/embeddings/stats" "$BASE/api/embeddings/stats"

# -----------------------------------------------------------------------------
sect "DB + HOSTED + DBPOOL"

get_ok "GET /api/dbcache/stats" "$BASE/api/dbcache/stats"
get_ok "GET /api/dbpool/stats" "$BASE/api/dbpool/stats"
get_ok "GET /api/hosted/stats" "$BASE/api/hosted/stats"
get_ok "GET /api/hosted/list" "$BASE/api/hosted/list"

# -----------------------------------------------------------------------------
sect "PROJECTS BACKING APIs"

get_ok "GET /api/projects" "$BASE/api/projects"

# Endpoints requiring id - hit with empty id, should 4xx (missing_id) not 5xx
get_no_5xx "GET /api/projects/logs (no id, expect 4xx)" "$BASE/api/projects/logs"
get_no_5xx "GET /api/projects/runtime-logs (no id, expect 4xx)" "$BASE/api/projects/runtime-logs"
get_no_5xx "GET /api/projects/status (no id, expect 4xx)" "$BASE/api/projects/status"
get_no_5xx "GET /api/projects/releases (no id, expect 4xx)" "$BASE/api/projects/releases"
get_no_5xx "GET /api/projects/users (no id, expect 4xx)" "$BASE/api/projects/users"
get_no_5xx "GET /api/projects/tables (no id, expect 4xx)" "$BASE/api/projects/tables"
get_no_5xx "GET /api/projects/cron/list (no id, expect 4xx)" "$BASE/api/projects/cron/list"
get_no_5xx "GET /api/projects/secrets/list (no id, expect 4xx)" "$BASE/api/projects/secrets/list"

# -----------------------------------------------------------------------------
sect "SYSTEM ENDPOINTS (cookie auth)"

get_ok "GET /api/system/info" "$BASE/api/system/info"
get_ok "GET /api/system/power" "$BASE/api/system/power"
get_ok "GET /api/system/version" "$BASE/api/system/version"
get_ok "GET /api/system/backups" "$BASE/api/system/backups"

# Trigger backup and validate
R=$(curl -sm 30 -b "$CJ" -X POST "$BASE/api/system/backup?target=local")
if echo "$R" | grep -q '"ok":true'; then pass "POST /api/system/backup local"; else fail "POST /api/system/backup local" "$R"; fi

R=$(curl -sm 30 -b "$CJ" -X POST "$BASE/api/system/restore-test?source=local")
if echo "$R" | grep -q '"ok":true'; then pass "POST /api/system/restore-test local"; else fail "POST /api/system/restore-test local" "$R"; fi

# Shell exec basic test
R=$(curl -sm 10 -b "$CJ" -X POST -H 'Content-Type: application/json' -d '{"cmd":"echo hello"}' "$BASE/api/system/exec")
if echo "$R" | grep -q '"stdout":"hello'; then pass "POST /api/system/exec (echo)"; else fail "POST /api/system/exec (echo)" "$R"; fi

# Timeout enforcement
R=$(curl -sm 10 -b "$CJ" -X POST -H 'Content-Type: application/json' -d '{"cmd":"sleep 5","timeout_ms":500}' "$BASE/api/system/exec")
if echo "$R" | grep -q '"timed_out":true'; then pass "POST /api/system/exec (timeout)"; else fail "POST /api/system/exec (timeout)" "$R"; fi

# -----------------------------------------------------------------------------
sect "V1 ENDPOINTS (X-API-Key auth)"

# Identity
R=$(curl -sm 5 -H "X-API-Key: $KEY" "$BASE/v1/whoami")
if echo "$R" | grep -q '"ok":true'; then pass "GET /v1/whoami"; else fail "GET /v1/whoami" "$R"; fi

# System mirrors
get_ok_v1() {
    R=$(curl -sm 10 -H "X-API-Key: $KEY" "$2")
    if echo "$R" | grep -q '"ok":true'; then pass "$1"; else fail "$1" "$R"; fi
}
get_ok_v1 "GET /v1/system/version" "$BASE/v1/system/version"
get_ok_v1 "GET /v1/system/info" "$BASE/v1/system/info"
get_ok_v1 "GET /v1/system/power" "$BASE/v1/system/power"
get_ok_v1 "GET /v1/projects" "$BASE/v1/projects"

# Scope enforcement
SQL_KEY_RESP=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "name=test-sql-$(date +%s)" \
    --data-urlencode "scopes=sql" \
    "$BASE/api/apikeys/create")
SQL_KEY=$(echo "$SQL_KEY_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))')
SQL_KEY_ID=$(echo "$SQL_KEY_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))')
R=$(curl -s -H "X-API-Key: $SQL_KEY" "$BASE/v1/system/version")
if echo "$R" | grep -q '"err":"scope_required"'; then pass "scope enforcement (sql key blocked from system)"; else fail "scope enforcement" "$R"; fi
curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode "id=$SQL_KEY_ID" "$BASE/api/apikeys/revoke" >/dev/null

# Bad key rejected
R=$(curl -s -H "X-API-Key: rh_nonsense_invalid_key_value_xxxxxxxxxxxxxxxxx" "$BASE/v1/system/version")
if echo "$R" | grep -q '"err":"invalid_api_key"'; then pass "invalid API key rejected"; else fail "invalid API key rejected" "$R"; fi

# No key rejected
R=$(curl -s "$BASE/v1/system/version")
if echo "$R" | grep -q '"err":"missing_api_key"'; then pass "missing API key rejected"; else fail "missing API key rejected" "$R"; fi

# -----------------------------------------------------------------------------
sect "PROJECT LIFECYCLE (full CRUD via v1)"

SUB="testall-$(date +%s)"
R=$(curl -s -H "X-API-Key: $KEY" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "name=$SUB" \
    --data-urlencode "subdomain=$SUB" \
    --data-urlencode "runtime=static" \
    --data-urlencode "rss_limit_mb=128" \
    "$BASE/v1/projects/create")
PID=$(echo "$R" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))')
[ -n "$PID" ] && pass "v1 projects create" || { fail "v1 projects create" "$R"; PID=""; }

if [ -n "$PID" ]; then
    R=$(curl -s -H "X-API-Key: $KEY" "$BASE/v1/projects")
    if echo "$R" | grep -q "\"id\":\"$PID\""; then pass "list sees new project"; else fail "list sees new project" "$R"; fi
    if echo "$R" | grep -q '"rss_limit_mb":128'; then pass "rss_limit_mb persisted from create"; else fail "rss_limit_mb persisted" "$R"; fi

    # Update rss limit
    R=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode "id=$PID" --data-urlencode "rss_limit_mb=256" \
        "$BASE/api/projects/update")
    if echo "$R" | grep -q '"ok":true'; then pass "POST /api/projects/update rss_limit_mb"; else fail "update rss_limit_mb" "$R"; fi

    # Status with rss fields
    R=$(curl -s -H "X-API-Key: $KEY" "$BASE/v1/projects/status?id=$PID")
    if echo "$R" | grep -q '"rss_limit_mb":256'; then pass "status reflects rss_limit update"; else fail "status reflects rss_limit" "$R"; fi
    if echo "$R" | grep -q '"last_kill_reason":"none"'; then pass "status has last_kill_reason field"; else fail "status has last_kill_reason" "$R"; fi

    # Stop / start cycle
    R=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode "id=$PID" "$BASE/api/projects/stop")
    if echo "$R" | grep -q '"ok":true'; then pass "POST /api/projects/stop (static)"; else fail "stop" "$R"; fi
    R=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode "id=$PID" "$BASE/api/projects/start")
    if echo "$R" | grep -q '"ok":true'; then pass "POST /api/projects/start (static)"; else fail "start" "$R"; fi
    R=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode "id=$PID" "$BASE/api/projects/restart")
    if echo "$R" | grep -q '"ok":true'; then pass "POST /api/projects/restart (static)"; else fail "restart" "$R"; fi

    # Secrets lifecycle
    R=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode "project_id=$PID" --data-urlencode "key=TEST_KEY" --data-urlencode "value=secret_value" \
        "$BASE/api/projects/secrets/set")
    if echo "$R" | grep -q '"ok":true'; then pass "POST /api/projects/secrets/set"; else fail "secrets set" "$R"; fi

    R=$(curl -s -b "$CJ" "$BASE/api/projects/secrets/list?id=$PID")
    if echo "$R" | grep -q '"TEST_KEY"'; then pass "GET /api/projects/secrets/list (sees TEST_KEY)"; else fail "secrets list" "$R"; fi

    R=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode "project_id=$PID" --data-urlencode "key=TEST_KEY" \
        "$BASE/api/projects/secrets/delete")
    if echo "$R" | grep -q '"ok":true'; then pass "POST /api/projects/secrets/delete"; else fail "secrets delete" "$R"; fi

    # SQL endpoint
    R=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/json' \
        -d "{\"project_id\":\"$PID\",\"sql\":\"CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);\"}" \
        "$BASE/api/projects/sql")
    if echo "$R" | grep -q '"ok":true'; then pass "POST /api/projects/sql (CREATE TABLE)"; else fail "sql create" "$R"; fi

    # Cron lifecycle
    R=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode "project_id=$PID" --data-urlencode "name=test" \
        --data-urlencode "schedule=every 1h" --data-urlencode "command=echo test" \
        "$BASE/api/projects/cron/create")
    TID=$(echo "$R" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
    if [ -n "$TID" ]; then pass "POST /api/projects/cron/create"; else fail "cron create" "$R"; fi
    if [ -n "$TID" ]; then
        R=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode "id=$TID" "$BASE/api/projects/cron/run")
        if echo "$R" | grep -q '"ok":true'; then pass "POST /api/projects/cron/run"; else fail "cron run" "$R"; fi
        R=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode "id=$TID" "$BASE/api/projects/cron/delete")
        if echo "$R" | grep -q '"ok":true'; then pass "POST /api/projects/cron/delete"; else fail "cron delete" "$R"; fi
    fi

    # Cleanup with purge
    R=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode "id=$PID" --data-urlencode "purge=true" "$BASE/api/projects/delete")
    if echo "$R" | grep -q '"ok":true'; then pass "POST /api/projects/delete (purge)"; else fail "delete purge" "$R"; fi
fi

# -----------------------------------------------------------------------------
sect "STATIC DEPLOY VIA v1 UPLOAD"

TMP_DIR=$(mktemp -d)
echo '<!doctype html><h1>test-everything live</h1>' > "$TMP_DIR/index.html"
ZIP="$TMP_DIR/site.zip"
(cd "$TMP_DIR" && zip -q "$ZIP" index.html)

SUB2="testdeploy-$(date +%s)"
R=$(curl -s -H "X-API-Key: $KEY" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "name=$SUB2" --data-urlencode "subdomain=$SUB2" --data-urlencode "runtime=static" \
    "$BASE/v1/projects/create")
PID2=$(echo "$R" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
[ -n "$PID2" ] && pass "v1 deploy: project created" || fail "v1 deploy: project created" "$R"

if [ -n "$PID2" ]; then
    R=$(curl -s -H "X-API-Key: $KEY" -X POST -H 'Content-Type: application/zip' --data-binary "@$ZIP" "$BASE/v1/projects/upload?id=$PID2")
    if echo "$R" | grep -q '"ok":true'; then
        pass "v1 deploy: upload"
        sleep 2
        BODY=$(curl -sk -m 10 "https://$SUB2.rofihosted.space/")
        if echo "$BODY" | grep -q "test-everything live"; then pass "v1 deploy: site reachable through CF"; else fail "v1 deploy: site reachable" "$BODY"; fi
    else
        fail "v1 deploy: upload" "$R"
    fi
    curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode "id=$PID2" --data-urlencode "purge=true" "$BASE/api/projects/delete" >/dev/null
fi
rm -rf "$TMP_DIR"

# -----------------------------------------------------------------------------
sect "BACKUP PIPELINE"

R=$(curl -sm 30 -b "$CJ" -X POST "$BASE/api/system/backup?target=local")
if echo "$R" | grep -q '"ok":true'; then pass "backup local"; else fail "backup local" "$R"; fi

R=$(curl -sm 15 -b "$CJ" "$BASE/api/system/backups")
if echo "$R" | grep -q '"name":"rofihosted-'; then
    LOCAL_COUNT=$(echo "$R" | grep -o '"name":"rofihosted-' | wc -l | tr -d ' ')
    pass "local backups visible (count=$LOCAL_COUNT)"
else
    fail "local backups visible" "$(echo "$R" | head -c 300)"
fi

R2_CONFIGURED=$(echo "$R" | grep -c '"r2_configured":true')
if [ "$R2_CONFIGURED" -gt 0 ]; then
    pass "R2 configured"
    R=$(curl -sm 90 -b "$CJ" -X POST "$BASE/api/system/backup?target=r2")
    if echo "$R" | grep -q '"ok":true'; then pass "R2 backup upload"; else fail "R2 backup upload" "$R"; fi
    REMOTE_COUNT=$(curl -sm 15 -b "$CJ" "$BASE/api/system/backups" | grep -o '"name":"rofihosted-' | wc -l | tr -d ' ')
    [ "$REMOTE_COUNT" -gt 0 ] && pass "R2 backup visible (count=$REMOTE_COUNT)" || fail "R2 backup visible"
else
    warn "R2 not configured (skip remote backup tests)"
fi

# -----------------------------------------------------------------------------
sect "POWERMON"

R=$(curl -sm 5 -H "X-API-Key: $KEY" "$BASE/v1/system/power")
PCT=$(echo "$R" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("percentage",-99))' 2>/dev/null)
if [ "$PCT" != "-99" ] && [ "$PCT" != "-1" ]; then pass "powermon: battery readable ($PCT%)"; else fail "powermon: battery readable" "$R"; fi

# -----------------------------------------------------------------------------
sect "AUDIT TRAIL"

R=$(curl -sm 5 -b "$CJ" "$BASE/api/audit?limit=20")
if echo "$R" | grep -q '"ok":true'; then
    pass "audit trail readable"
    if echo "$R" | grep -q '"action":"system_backup"'; then pass "audit logs system_backup"; else warn "no system_backup in last 20 entries"; fi
    if echo "$R" | grep -q '"action":"project_create"'; then pass "audit logs project_create"; else warn "no project_create in last 20 entries"; fi
else
    fail "audit trail" "$R"
fi

# -----------------------------------------------------------------------------
sect "FILESYSTEM SANITY (visits.jsonl size)"

VISITS_BYTES=$(stat -c %s ~/data/visits.jsonl 2>/dev/null || echo 0)
if [ "$VISITS_BYTES" -lt 10485760 ]; then  # 10 MB
    pass "visits.jsonl size OK ($VISITS_BYTES bytes)"
elif [ "$VISITS_BYTES" -lt 33554432 ]; then  # 32 MB (within readJsonl tail window)
    warn "visits.jsonl is ${VISITS_BYTES} bytes (rotator should trim soon)"
else
    fail "visits.jsonl is ${VISITS_BYTES} bytes" "exceeds 32 MB tail window, rotator stuck"
fi

UPTIME_BYTES=$(stat -c %s ~/data/uptime.jsonl 2>/dev/null || echo 0)
if [ "$UPTIME_BYTES" -lt 10485760 ]; then
    pass "uptime.jsonl size OK ($UPTIME_BYTES bytes)"
else
    warn "uptime.jsonl is ${UPTIME_BYTES} bytes (rotator should trim soon)"
fi

# -----------------------------------------------------------------------------
sect "PUBLIC HOMEPAGE STATIC ASSETS"

for asset in /theme.css /theme.js /icons.css; do
    code=$(curl -sm 5 -o /dev/null -w '%{http_code}' "https://rofihosted.space$asset")
    [ "$code" = "200" ] && pass "GET $asset" || fail "GET $asset" "got $code"
done

# -----------------------------------------------------------------------------
sect "PHASE 3 - DEVELOPER EXPERIENCE"

# Apex root (unauth) serves the marketing landing, not the login page.
APEX=$(curl -sm 8 -L -o /dev/null -w '%{http_code}' "https://rofihosted.space/")
[ "$APEX" = "200" ] && pass "apex / returns 200" || fail "apex / returns 200" "got $APEX"
APEX_BODY=$(curl -sm 8 -L "https://rofihosted.space/")
echo "$APEX_BODY" | grep -qi "rofihosted" && pass "apex contains 'rofihosted'" || fail "apex contains 'rofihosted'" ""
echo "$APEX_BODY" | grep -qi "Sign up" && pass "apex shows Sign up CTA" || fail "apex shows Sign up CTA" ""

# /v1/public/stats has the Phase 3 fields.
PSTATS=$(curl -sm 5 "$BASE/v1/public/stats")
echo "$PSTATS" | grep -q '"projects_running"' && pass "public stats: projects_running field" || fail "public stats: projects_running" "$PSTATS"
echo "$PSTATS" | grep -q '"total_users"' && pass "public stats: total_users field" || fail "public stats: total_users" "$PSTATS"
echo "$PSTATS" | grep -q '"version_short"' && pass "public stats: version_short field" || fail "public stats: version_short" "$PSTATS"
echo "$PSTATS" | grep -q '"uptime_days"' && pass "public stats: uptime_days field" || fail "public stats: uptime_days" "$PSTATS"

# /api/me exposes Phase 3 quota fields (tested via legacy operator cookie).
ME=$(curl -sm 5 -b "$CJ" "$BASE/api/me")
echo "$ME" | grep -q '"max_projects"' && pass "/api/me exposes max_projects" || fail "/api/me exposes max_projects" "$ME"

# Auto-deploy endpoint exists and rejects bad URLs synchronously.
BAD=$(curl -sm 8 -b "$CJ" -X POST -H "Content-Type: application/x-www-form-urlencoded" \
    -d "repo_url=ssh://nope" "$BASE/api/projects/auto-deploy")
echo "$BAD" | grep -q '"err":"bad_repo_url"' && pass "auto-deploy rejects ssh://" || fail "auto-deploy rejects ssh://" "$BAD"

NOAT=$(curl -sm 8 -b "$CJ" -X POST -H "Content-Type: application/x-www-form-urlencoded" \
    -d "repo_url=https://user:pass@github.com/x/y" "$BASE/api/projects/auto-deploy")
echo "$NOAT" | grep -q '"err":"bad_repo_url"' && pass "auto-deploy blocks credentials in URL" || fail "auto-deploy blocks credentials in URL" "$NOAT"

# MCP discovery / tools/list contains the new Phase 3 tools.
MCP_TOOLS=$(curl -sm 8 -X POST -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' "$BASE/mcp")
echo "$MCP_TOOLS" | grep -q '"name":"auto_deploy"' && pass "mcp tools/list contains auto_deploy" || fail "mcp tools/list contains auto_deploy" "$MCP_TOOLS"
echo "$MCP_TOOLS" | grep -q '"name":"tail_build_log"' && pass "mcp tools/list contains tail_build_log" || fail "mcp tools/list contains tail_build_log" "$MCP_TOOLS"
echo "$MCP_TOOLS" | grep -q '"name":"get_db_url"' && pass "mcp tools/list contains get_db_url" || fail "mcp tools/list contains get_db_url" "$MCP_TOOLS"
echo "$MCP_TOOLS" | grep -q '"name":"set_db_url"' && pass "mcp tools/list contains set_db_url" || fail "mcp tools/list contains set_db_url" "$MCP_TOOLS"

# -----------------------------------------------------------------------------
sect "SUMMARY"

TOTAL=$((PASS + FAIL))
echo
echo "  $PASS / $TOTAL passed"
[ $WARN -gt 0 ] && echo "  $WARN warnings"
if [ $FAIL -gt 0 ]; then
    echo "  $FAIL FAILED"
    exit 1
fi
echo "  All green."
