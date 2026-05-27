#!/data/data/com.termux/files/usr/bin/sh
# End-to-end dbpool stats check + AI query bar latency to confirm the pool
# is being used (avg latency on the server side should be <5ms once warmed up).
set -e

if [ -f ~/.hp-server.env ]; then
  set -a
  . ~/.hp-server.env
  set +a
fi

CJ=$(mktemp)
trap "rm -f $CJ" EXIT

curl -s -c "$CJ" \
  --data-urlencode "username=$HP_AUTH_USER" \
  --data-urlencode "password=$HP_AUTH_PASS" \
  -o /dev/null \
  https://app.rofihosted.space/login/submit

echo "--- /api/dbpool/stats (initial) ---"
curl -s -b "$CJ" https://app.rofihosted.space/api/dbpool/stats

echo
echo "--- 30 dbcache reads to warm up pool (each call uses 2 SQL queries) ---"
for i in $(seq 1 30); do
  curl -s -b "$CJ" -o /dev/null https://app.rofihosted.space/api/dbcache/stats
done

echo "--- /api/dbpool/stats (after warmup) ---"
curl -s -b "$CJ" https://app.rofihosted.space/api/dbpool/stats
echo
echo
echo "--- pgrep sqlite3 (should show 1-3 persistent processes) ---"
pgrep -af sqlite3 | head -5
