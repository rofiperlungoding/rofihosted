#!/data/data/com.termux/files/usr/bin/sh
# Configure transactional email (Brevo HTTP API) for hp-server.
#
# Upserts BREVO_API_KEY, MAIL_FROM_EMAIL, MAIL_FROM_NAME into ~/.hp-server.env
# WITHOUT clobbering any other keys (MISTRAL_API_KEY, TG_*, R2_*, auth creds).
#
#   ./set-email.sh <brevo-api-key> <from-email> [from-name]
#
# The from-email MUST be a Brevo-verified sender (Senders & IPs page) or an
# address on a domain you've authenticated in Brevo (SPF + DKIM). On a fresh
# account, your signup email is auto-verified; use that until you verify the
# rofihosted.space domain.
set -e

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <brevo-api-key> <from-email> [from-name]" >&2
  echo >&2
  echo "Get the API key: Brevo dashboard -> SMTP & API -> API Keys -> Generate" >&2
  echo "It starts with 'xkeysib-'." >&2
  exit 1
fi

API_KEY="$1"
FROM_EMAIL="$2"
FROM_NAME="${3:-rofihosted}"

ENV_FILE=~/.hp-server.env
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

# upsert KEY VALUE: drop any existing definition (export or plain) then append.
upsert() {
  key="$1"
  val="$2"
  tmp="$ENV_FILE.tmp.$$"
  grep -vE "^(export[[:space:]]+)?${key}=" "$ENV_FILE" > "$tmp" 2>/dev/null || true
  printf "export %s='%s'\n" "$key" "$val" >> "$tmp"
  mv "$tmp" "$ENV_FILE"
}

upsert BREVO_API_KEY   "$API_KEY"
upsert MAIL_FROM_EMAIL "$FROM_EMAIL"
upsert MAIL_FROM_NAME  "$FROM_NAME"
chmod 600 "$ENV_FILE"
echo "[+] Email config saved to $ENV_FILE"

# Sanity-check the key against the Brevo account endpoint.
echo "[+] Verifying API key ..."
HTTP=$(curl -s -o /tmp/brevo_acct.$$ -w "%{http_code}" \
  --request GET --url "https://api.brevo.com/v3/account" \
  --header "accept: application/json" \
  --header "api-key: $API_KEY" || echo "000")
if [ "$HTTP" = "200" ]; then
  echo "[+] API key valid."
else
  echo "[!] API key check returned HTTP $HTTP (see /tmp/brevo_acct.$$). Saved anyway."
fi
rm -f /tmp/brevo_acct.$$ 2>/dev/null || true

# Optional live send to the from-address itself.
printf "[?] Send a test email to %s now? [y/N] " "$FROM_EMAIL"
read ans
case "$ans" in
  y|Y)
    BODY=$(printf '{"sender":{"name":"%s","email":"%s"},"to":[{"email":"%s"}],"subject":"rofihosted email armed","htmlContent":"<p>Transactional email is wired up on your phone server.</p>"}' \
      "$FROM_NAME" "$FROM_EMAIL" "$FROM_EMAIL")
    CODE=$(printf '%s' "$BODY" | curl -s -o /dev/null -w "%{http_code}" \
      --request POST --url "https://api.brevo.com/v3/smtp/email" \
      --header "accept: application/json" \
      --header "content-type: application/json" \
      --header "api-key: $API_KEY" \
      --data-binary @-)
    echo "[+] Test send HTTP $CODE (201 = queued)."
    ;;
  *) echo "[i] Skipped test send." ;;
esac

echo "[+] Restart hp-server to load the new config: ~/start-zig-server.sh"
