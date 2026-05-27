#!/data/data/com.termux/files/usr/bin/sh
# Verify FTS5 is compiled into Termux's sqlite3
sqlite3 :memory: <<'EOF'
CREATE VIRTUAL TABLE t USING fts5(x);
INSERT INTO t VALUES ('hello world from termux sqlite');
INSERT INTO t VALUES ('another row about scanners and bots');
SELECT * FROM t WHERE t MATCH 'scanners';
.exit
EOF
