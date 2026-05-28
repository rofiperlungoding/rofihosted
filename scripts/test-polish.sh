#!/data/data/com.termux/files/usr/bin/sh
# E2E Phase E: ZIP upload + rollback + SQL runner + cron tasks.
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

SUB="pol$(date +%s)"
echo "--- create static project ---"
RESP=$(curl -s -b "$CJ" \
  --data-urlencode "name=Polish test" \
  --data-urlencode "subdomain=$SUB" \
  --data-urlencode "runtime=static" \
  "$BASE/api/projects/create")
PID=$(echo "$RESP" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
echo "id: $PID"

echo
echo "--- create a tiny zip and upload it ---"
TMPDIR="$HOME/.tmp-polish"
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR/zip-src"
cat > "$TMPDIR/zip-src/index.html" << EOF
<!doctype html>
<html><head><title>uploaded v1</title></head>
<body><h1>Uploaded via ZIP</h1><p>Project: $SUB</p></body></html>
EOF
python3 -c "
import zipfile
with zipfile.ZipFile('$TMPDIR/upload.zip', 'w') as z:
  z.write('$TMPDIR/zip-src/index.html', 'index.html')
"
ls -la "$TMPDIR/upload.zip"

curl -s -b "$CJ" -X POST \
  -H 'Content-Type: application/zip' \
  --data-binary @"$TMPDIR/upload.zip" \
  "$BASE/api/projects/upload?id=$PID"
echo

sleep 2
echo
echo "--- fetch the uploaded site ---"
curl -s "https://$SUB.rofihosted.space/" | head -3

echo
echo "--- list releases ---"
curl -s -b "$CJ" "$BASE/api/projects/releases?id=$PID"
echo

echo
echo "--- upload v2 (different content) ---"
cat > "$TMPDIR/zip-src/index.html" << EOF
<!doctype html>
<html><head><title>uploaded v2</title></head>
<body><h1>v2</h1></body></html>
EOF
sleep 2  # ensure timestamp differs
python3 -c "
import zipfile
with zipfile.ZipFile('$TMPDIR/upload.zip', 'w') as z:
  z.write('$TMPDIR/zip-src/index.html', 'index.html')
"
curl -s -b "$CJ" -X POST \
  -H 'Content-Type: application/zip' \
  --data-binary @"$TMPDIR/upload.zip" \
  "$BASE/api/projects/upload?id=$PID"
echo

sleep 2
echo "--- v2 should be live ---"
curl -s "https://$SUB.rofihosted.space/"

echo
echo "--- list releases (should have 2) ---"
curl -s -b "$CJ" "$BASE/api/projects/releases?id=$PID"
echo

# Pick the older release for rollback (smaller timestamp = first in releases array)
OLD=$(curl -s -b "$CJ" "$BASE/api/projects/releases?id=$PID" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
rels = d.get("releases", [])
# Releases come back newest-first; the older one is the last entry
print(rels[-1] if len(rels) >= 2 else "")
')
echo "rollback target: $OLD"
if [ -n "$OLD" ]; then
  curl -s -b "$CJ" --data-urlencode "id=$PID" --data-urlencode "release=$OLD" "$BASE/api/projects/rollback"
  echo
  sleep 2
  echo "--- after rollback (should show v1) ---"
  curl -s "https://$SUB.rofihosted.space/" | head -3
fi

echo
echo "--- SQL runner: create a table + insert + select ---"
curl -s -b "$CJ" -H 'Content-Type: application/json' \
  -d "{\"project_id\":\"$PID\",\"sql\":\"CREATE TABLE IF NOT EXISTS notes(id INTEGER PRIMARY KEY, body TEXT); INSERT INTO notes(body) VALUES('hello from sql ui'); SELECT * FROM notes;\"}" \
  "$BASE/api/projects/sql"
echo

echo
echo "--- create a cron task: every 30s echo current time to file ---"
CRON_FILE="$HOME/.tmp-polish/cron-test.txt"
RESP=$(curl -s -b "$CJ" \
  --data-urlencode "project_id=$PID" \
  --data-urlencode "name=hb" \
  --data-urlencode "schedule=every 30s" \
  --data-urlencode "command=date >> $CRON_FILE" \
  "$BASE/api/projects/cron/create")
echo "$RESP"
TASK=$(echo "$RESP" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
echo "task id: $TASK"

echo
echo "--- run task once via API ---"
curl -s -b "$CJ" --data-urlencode "id=$TASK" "$BASE/api/projects/cron/run"
echo
sleep 1

echo
echo "--- list project tasks ---"
curl -s -b "$CJ" "$BASE/api/projects/cron/list?project_id=$PID"
echo

echo
echo "--- check the file the task wrote ---"
cat "$CRON_FILE" 2>&1 | head -3 || echo "(no file)"

echo
echo "--- toggle task off ---"
curl -s -b "$CJ" --data-urlencode "id=$TASK" --data-urlencode "enabled=false" "$BASE/api/projects/cron/toggle"
echo

echo
echo "--- delete task ---"
curl -s -b "$CJ" --data-urlencode "id=$TASK" "$BASE/api/projects/cron/delete"
echo

echo
echo "--- cleanup ---"
curl -s -b "$CJ" --data-urlencode "id=$PID" "$BASE/api/projects/delete"
rm -rf ~/data/projects/$PID ~/data/dbs/$PID.db "$TMPDIR"
