#!/data/data/com.termux/files/usr/bin/sh
# End-to-end Phase D: built-in auth as a service. Create a project, signup
# a user, login, verify token, ensure invalid creds fail.
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

SUB="auth$(date +%s)"
echo "--- create static project (we just need the subdomain claim) ---"
RESP=$(curl -s -b "$CJ" \
  --data-urlencode "name=Auth test" \
  --data-urlencode "subdomain=$SUB" \
  --data-urlencode "runtime=static" \
  --data-urlencode "repo_url=" \
  "$BASE/api/projects/create")
PID=$(echo "$RESP" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
echo "project id: $PID"

echo
echo "--- signup ---"
SIGNUP=$(curl -s \
  -H 'Content-Type: application/json' \
  -d '{"email":"alice@example.com","password":"correctbattery"}' \
  "https://$SUB.rofihosted.space/auth/signup")
echo "$SIGNUP"
TOKEN=$(echo "$SIGNUP" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
echo "token prefix: $(echo "$TOKEN" | cut -c1-40)..."

echo
echo "--- duplicate signup should fail ---"
curl -s \
  -H 'Content-Type: application/json' \
  -d '{"email":"alice@example.com","password":"correctbattery"}' \
  "https://$SUB.rofihosted.space/auth/signup"
echo

echo
echo "--- login with wrong password ---"
curl -s -o /dev/null -w 'http=%{http_code}\n' \
  -H 'Content-Type: application/json' \
  -d '{"email":"alice@example.com","password":"wrong-pass"}' \
  "https://$SUB.rofihosted.space/auth/login"

echo
echo "--- login with correct password ---"
LOGIN=$(curl -s \
  -H 'Content-Type: application/json' \
  -d '{"email":"alice@example.com","password":"correctbattery"}' \
  "https://$SUB.rofihosted.space/auth/login")
echo "$LOGIN"
TOKEN2=$(echo "$LOGIN" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

echo
echo "--- verify the token from login ---"
curl -s -H "Authorization: Bearer $TOKEN2" "https://$SUB.rofihosted.space/auth/verify"
echo

echo
echo "--- verify with bogus token ---"
curl -s -o /dev/null -w 'http=%{http_code}\n' \
  -H "Authorization: Bearer abc.def.ghi" \
  "https://$SUB.rofihosted.space/auth/verify"

echo
echo "--- inspect the per-project DB ---"
sqlite3 ~/data/dbs/$PID.db "SELECT id, email, created_at, last_login FROM users;"

echo
echo "--- cleanup ---"
curl -s -b "$CJ" --data-urlencode "id=$PID" "$BASE/api/projects/delete" > /dev/null
rm -f ~/data/dbs/$PID.db
rm -rf ~/data/projects/$PID
