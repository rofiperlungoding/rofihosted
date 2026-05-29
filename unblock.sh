#!/data/data/com.termux/files/usr/bin/bash
[ -f ~/.hp-server.env ] && { set -a; . ~/.hp-server.env; set +a; }
CJ=$(mktemp); trap "rm -f $CJ" EXIT
curl -s -c "$CJ" -o /dev/null \
    --data-urlencode "username=$HP_AUTH_USER" \
    --data-urlencode "password=$HP_AUTH_PASS" \
    "https://app.rofihosted.space/login/submit"
echo "=== unblocking 114.10.46.18 ==="
curl -s -b "$CJ" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "ip=114.10.46.18" \
    "https://app.rofihosted.space/api/security/unblock"
echo
echo "=== current blocklist ==="
curl -s -b "$CJ" "https://app.rofihosted.space/api/security" | python3 -c "
import sys,json
d = json.load(sys.stdin)
bl = d.get('blocklist',[])
print(f'{len(bl)} IPs blocked')
for b in bl:
    print(f'  {b[\"ip\"]}')
"
