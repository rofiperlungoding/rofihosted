#!/data/data/com.termux/files/usr/bin/sh
set -eu
[ -f ~/.hp-server.env ] && { set -a; . ~/.hp-server.env; set +a; }
COOKIE=$(curl -sS -i \
  --data-urlencode "username=$HP_AUTH_USER" \
  --data-urlencode "password=$HP_AUTH_PASS" \
  https://app.rofihosted.space/login/submit \
  | awk -F'[=;]' '/^set-cookie: rofi_session=/ { print $2; exit }')
HDR="Cookie: rofi_session=$COOKIE"

echo "--- /api/dbcache/stats (initial, fresh restart) ---"
curl -sS -H "$HDR" https://app.rofihosted.space/api/dbcache/stats
echo

echo "--- /api/dbcache/sync (manual trigger) ---"
curl -sS -H "$HDR" --max-time 60 https://app.rofihosted.space/api/dbcache/sync
echo

echo "--- /api/dbcache/stats (after sync) ---"
curl -sS -H "$HDR" https://app.rofihosted.space/api/dbcache/stats
echo

echo "--- check db file ---"
ls -la ~/data/cache.db ~/data/cache.db-wal 2>&1
echo

echo "--- direct sqlite query (sample) ---"
sqlite3 ~/data/cache.db <<EOF
SELECT COUNT(*) AS rows FROM visits;
SELECT classification, COUNT(*) FROM visits GROUP BY classification ORDER BY 2 DESC LIMIT 5;
SELECT * FROM visits_fts WHERE visits_fts MATCH 'wp-admin' LIMIT 3;
.exit
EOF
