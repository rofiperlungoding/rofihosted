#!/data/data/com.termux/files/usr/bin/sh
set -a
. ~/.hp-server.env
set +a
echo "key loaded, len=${#MISTRAL_API_KEY}"
curl -sS --max-time 15 -X POST \
  -H "Authorization: Bearer $MISTRAL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"mistral-small-latest","max_tokens":20,"messages":[{"role":"user","content":"reply with the single word OK"}]}' \
  https://api.mistral.ai/v1/chat/completions
echo
