#!/data/data/com.termux/files/usr/bin/sh
# End-to-end test of API key creation + /v1/execute SQL endpoint.
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

echo "--- /api/apikeys (initial list) ---"
curl -s -b "$CJ" "$BASE/api/apikeys"
echo

echo "--- create a new key with sql scope ---"
RAW=$(curl -s -b "$CJ" \
  --data-urlencode "name=test-cli" \
  --data-urlencode "scopes=sql" \
  "$BASE/api/apikeys/create" | tee /dev/stderr | sed -n 's/.*"key":"\([^"]*\)".*/\1/p')
echo
echo "extracted key: $RAW"
echo

echo "--- create a sample DB and seed it ---"
mkdir -p ~/data/dbs
sqlite3 ~/data/dbs/notes.db "CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, body TEXT, created_at INTEGER);"
sqlite3 ~/data/dbs/notes.db "INSERT INTO items (body, created_at) VALUES ('hello world', 1779918000), ('second note', 1779918100);"
echo "items count via direct sqlite3:"
sqlite3 ~/data/dbs/notes.db "SELECT COUNT(*) FROM items;"
echo

echo "--- /v1/whoami via X-API-Key ---"
curl -s -H "X-API-Key: $RAW" "$BASE/v1/whoami"
echo

echo "--- /v1/execute SELECT * FROM items ---"
curl -s -H "X-API-Key: $RAW" -H 'Content-Type: application/json' \
  -d '{"db":"notes","sql":"SELECT id, body FROM items ORDER BY id;"}' \
  "$BASE/v1/execute"
echo

echo "--- /v1/execute with a bad SQL ---"
curl -s -H "X-API-Key: $RAW" -H 'Content-Type: application/json' \
  -d '{"db":"notes","sql":"SELECT * FROM nonexistent;"}' \
  "$BASE/v1/execute"
echo

echo "--- /v1/execute with no api key (should 401) ---"
curl -s -o /dev/null -w 'http=%{http_code}\n' \
  -H 'Content-Type: application/json' \
  -d '{"db":"notes","sql":"SELECT 1;"}' \
  "$BASE/v1/execute"

echo
echo "--- /v1/execute with bogus key ---"
curl -s -o /dev/null -w 'http=%{http_code}\n' \
  -H "X-API-Key: rh_deadbeef" \
  -H 'Content-Type: application/json' \
  -d '{"db":"notes","sql":"SELECT 1;"}' \
  "$BASE/v1/execute"
