#!/data/data/com.termux/files/usr/bin/sh
# Set TG_BOT_TOKEN / TG_CHAT_ID for uptime alerts.
ENV_FILE=~/.hp-server.env

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <bot-token> <chat-id>"
  echo
  echo "How to get these:"
  echo "  1. In Telegram, message @BotFather, /newbot, follow steps -> get token"
  echo "  2. Message your new bot anything, then visit:"
  echo "     https://api.telegram.org/bot<TOKEN>/getUpdates"
  echo "     to get chat_id from the JSON response"
  exit 1
fi

# Preserve auth creds
HP_USER="admin"
HP_PASS="changeme"
if [ -f "$ENV_FILE" ]; then
  HP_USER=$(grep -oE "HP_AUTH_USER='[^']+'" "$ENV_FILE" | sed "s/HP_AUTH_USER='//;s/'$//" || echo admin)
  HP_PASS=$(grep -oE "HP_AUTH_PASS='[^']+'" "$ENV_FILE" | sed "s/HP_AUTH_PASS='//;s/'$//" || echo changeme)
fi

cat > "$ENV_FILE" <<EOF
export HP_AUTH_USER='$HP_USER'
export HP_AUTH_PASS='$HP_PASS'
export TG_BOT_TOKEN='$1'
export TG_CHAT_ID='$2'
EOF
chmod 600 "$ENV_FILE"
echo "[+] Telegram credentials saved"
echo "[+] Test send:"
curl -s -o /dev/null -w "test send: %{http_code}\n" \
  "https://api.telegram.org/bot$1/sendMessage" \
  -d "chat_id=$2" \
  -d "text=🟢 hp-server telegram alerts armed at $(date)"
echo "[+] restart hp-server: ~/start-zig-server.sh"
