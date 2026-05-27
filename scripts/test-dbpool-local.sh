#!/data/data/com.termux/files/usr/bin/sh
# Localhost-only microbenchmark to measure pool latency without Cloudflare hop.
set -e

if [ -f ~/.hp-server.env ]; then
  set -a
  . ~/.hp-server.env
  set +a
fi

CJ=$(mktemp)
trap "rm -f $CJ" EXIT

# /api/dbcache/stats requires auth, but it's behind app.rofihosted.space.
# Cookie has Secure flag so we have to talk HTTPS via tunnel for the cookie
# to be sent. To bench raw subprocess vs pool, we'll just use sqlite3 directly
# vs hitting the pool through localhost HTTP with auth header re-injection.
# Simpler: spawn sqlite3 directly N times and time it.

echo "--- one-shot sqlite3 latency (baseline, current dbcache.zig pattern) ---"
total=0
DB=/data/data/com.termux/files/home/data/cache.db
for i in $(seq 1 10); do
  ms=$( { time sqlite3 "$DB" "SELECT COUNT(*) FROM visits;" >/dev/null; } 2>&1 \
        | awk '/real/ {gsub("[ms]"," ", $2); split($2,a," "); printf "%d", a[1]*60000 + a[2]*1000}' )
  if [ -z "$ms" ]; then
    # fallback for busybox time
    s=$(date +%s%3N)
    sqlite3 "$DB" "SELECT COUNT(*) FROM visits;" >/dev/null
    e=$(date +%s%3N)
    ms=$((e - s))
  fi
  total=$((total + ms))
  printf "  %2d: %sms\n" "$i" "$ms"
done
echo "average one-shot: $((total / 10))ms"

echo
echo "--- pool query latency through hp-server's worker, via raw HTTP ---"
echo "(requires logged-in cookie; using localhost won't work because cookie is Secure)"
echo "skipped; rely on Cloudflare benchmark instead"
