#!/data/data/com.termux/files/usr/bin/sh
echo "--- FTS5 search for 'wp' ---"
sqlite3 ~/data/cache.db <<'EOF'
.timer on
SELECT path, COUNT(*) FROM visits_fts WHERE visits_fts MATCH 'wp' GROUP BY path LIMIT 5;
EOF
echo
echo "--- FTS5 search for 'admin' ---"
sqlite3 ~/data/cache.db <<'EOF'
.timer on
SELECT path, COUNT(*) FROM visits_fts WHERE visits_fts MATCH 'admin' GROUP BY path LIMIT 5;
EOF
echo
echo "--- count by country ---"
sqlite3 ~/data/cache.db <<'EOF'
.timer on
SELECT country, COUNT(*) FROM visits WHERE country != '' GROUP BY country ORDER BY 2 DESC LIMIT 5;
EOF
