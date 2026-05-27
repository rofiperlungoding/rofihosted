#!/data/data/com.termux/files/usr/bin/sh
# Microbenchmark: latency of /api/dbcache/stats (fast path through pool)
# vs /api/dbcache/sync (slow path that needs JSONL).
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

echo "--- 20 sequential /api/dbcache/stats calls ---"
total=0
for i in $(seq 1 20); do
  ms=$(curl -s -b "$CJ" -o /dev/null -w '%{time_total}' \
    https://app.rofihosted.space/api/dbcache/stats)
  ms_int=$(awk -v t="$ms" 'BEGIN{printf "%d", t*1000}')
  total=$((total + ms_int))
  printf "  %2d: %sms\n" "$i" "$ms_int"
done
echo "average: $((total / 20))ms over 20 calls"

echo
echo "--- subprocess processes after the benchmark ---"
pgrep -af sqlite3 | head -5
