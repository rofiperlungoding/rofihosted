#!/data/data/com.termux/files/usr/bin/sh
# End-to-end test of the webhook system.
# Spins up a tiny netcat receiver on 127.0.0.1:9999, registers a webhook
# pointing at it, fires a test event, verifies the receiver got it.
set -e

if [ -f ~/.hp-server.env ]; then
  set -a
  . ~/.hp-server.env
  set +a
fi

BASE="https://app.rofihosted.space"
CJ=$(mktemp)
RECV=$(mktemp)
trap "rm -f $CJ $RECV; kill %1 2>/dev/null || true" EXIT

curl -s -c "$CJ" \
  --data-urlencode "username=$HP_AUTH_USER" \
  --data-urlencode "password=$HP_AUTH_PASS" \
  -o /dev/null \
  "$BASE/login/submit"

echo "--- /api/webhooks (initial list) ---"
curl -s -b "$CJ" "$BASE/api/webhooks"
echo

# Spawn a tiny HTTP receiver in the background.
# Use python because nc on Termux can't easily speak HTTP.
python3 -c '
import socket, sys
s = socket.socket()
s.bind(("127.0.0.1", 9999))
s.listen(1)
sys.stdout.write("listening\n")
sys.stdout.flush()
conn, _ = s.accept()
data = b""
while True:
  chunk = conn.recv(4096)
  if not chunk: break
  data += chunk
  if b"\r\n\r\n" in data:
    headers, _, body = data.partition(b"\r\n\r\n")
    cl = 0
    for h in headers.split(b"\r\n"):
      if h.lower().startswith(b"content-length:"):
        cl = int(h.split(b":")[1].strip())
    while len(body) < cl:
      chunk = conn.recv(4096)
      if not chunk: break
      body += chunk
    sys.stdout.write("BODY:" + body.decode("utf-8", "replace") + "\n")
    sys.stdout.flush()
    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
    break
conn.close()
s.close()
' > "$RECV" 2>&1 &
PYPID=$!
sleep 1

echo "--- create webhook pointing at local receiver ---"
curl -s -b "$CJ" \
  --data-urlencode "name=local-test" \
  --data-urlencode "url=http://127.0.0.1:9999/hook" \
  --data-urlencode "events=blocklist_change" \
  "$BASE/api/webhooks/create"
echo

echo "--- fire blocklist_change by manually blocking and unblocking a test IP ---"
curl -s -b "$CJ" \
  --data-urlencode "ip=203.0.113.250" \
  --data-urlencode "reason=webhook test" \
  --data-urlencode "ttl=60" \
  "$BASE/api/security/block"
echo

# Wait briefly for webhook to fire
sleep 3
wait $PYPID 2>/dev/null || true

echo "--- receiver output ---"
cat "$RECV"
echo

echo "--- webhook list (should show fires=1) ---"
curl -s -b "$CJ" "$BASE/api/webhooks"
echo

echo "--- cleanup: unblock test IP and delete webhook ---"
curl -s -b "$CJ" --data-urlencode "ip=203.0.113.250" "$BASE/api/security/unblock" > /dev/null
HOOK_ID=$(curl -s -b "$CJ" "$BASE/api/webhooks" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
if [ -n "$HOOK_ID" ]; then
  curl -s -b "$CJ" --data-urlencode "id=$HOOK_ID" "$BASE/api/webhooks/delete" > /dev/null
  echo "deleted webhook $HOOK_ID"
fi
