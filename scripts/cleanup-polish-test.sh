#!/data/data/com.termux/files/usr/bin/sh
set -e
if [ -f ~/.hp-server.env ]; then set -a; . ~/.hp-server.env; set +a; fi
CJ=$(mktemp); trap "rm -f $CJ" EXIT
curl -s -c "$CJ" --data-urlencode "username=$HP_AUTH_USER" --data-urlencode "password=$HP_AUTH_PASS" -o /dev/null https://app.rofihosted.space/login/submit

# Find and delete the Polish test project
PID=$(curl -s -b "$CJ" https://app.rofihosted.space/api/projects | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
for p in d.get("projects", []):
    if p.get("name") == "Polish test":
        print(p["id"])
        break
')
if [ -n "$PID" ]; then
  echo "Deleting Polish test ($PID)..."
  curl -s -b "$CJ" --data-urlencode "id=$PID" https://app.rofihosted.space/api/projects/delete
  echo
  rm -rf ~/data/projects/$PID 2>/dev/null
  rm -f ~/data/dbs/$PID.db 2>/dev/null
  echo "cleanup done"
else
  echo "Polish test not found"
fi
