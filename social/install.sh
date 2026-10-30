#!/bin/bash
# Social Lab server installer.
#   ./install.sh          set up the server, then offer the HTTPS steps
#   ./install.sh https    only print the HTTPS steps
set -e
cd "$(dirname "$0")"

DOMAIN="social.lab"
SERVER_IP="172.28.0.20"

https_steps() {
cat <<EOF
HTTPS for $DOMAIN - what has to be set up (by hand)
=================================================================
Social Lab only opens at https://$DOMAIN - never over plain HTTP,
by IP or by any other name - so it stays closed until these are done.
The server keeps its own private key; nobody else ever sees it.
The operator registers the name in DNS and has the CA sign the
server's certificate request.

Automatic route instead: the operator registers $DOMAIN in the CA portal
and sends you a one-time code with three commands; run them here. They do
steps 1-3 and 5-10 below for you, and the key still never leaves.

ON THIS SERVER   (from the host: docker compose exec social bash)
  1. Private key - stays on this server, never shared:
       openssl genrsa -out server/key.pem 2048
       chmod 600 server/key.pem
  2. Certificate signing request (CSR) - public, safe to hand over:
       openssl req -new -key server/key.pem -out server/social.csr -subj "/O=Social Lab/CN=$DOMAIN"
  3. Give server/social.csr to the CA operator.

IN THE DNS PORTAL   (operator - https://dns.lab)
  4. Register the domain:
       domain   $DOMAIN
       IP       $SERVER_IP
       company  Social Lab (+ contact details)
     Check it from this server:  getent hosts $DOMAIN

AT THE CA   (operator - on the host, in the project folder)
  5. Hand the CSR to the CA:
       cp social/server/social.csr ca/social.csr
  6. Create ca/social-ext.cnf - the certificate must name the domain:
       basicConstraints = CA:FALSE
       keyUsage = critical, digitalSignature, keyEncipherment
       extendedKeyUsage = serverAuth
       subjectKeyIdentifier = hash
       authorityKeyIdentifier = keyid, issuer
       subjectAltName = DNS:$DOMAIN
     (only the name - the site refuses its IP and localhost anyway)
  7. Review and sign it - answer y twice; it is recorded in ca/demoCA/index.txt:
       docker compose exec ca openssl ca -config openssl.cnf -extfile social-ext.cnf -in social.csr -out social.crt
  8. Return the certificate, plus the CA's public certificate for checking:
       cp ca/social.crt social/server/cert.pem
       cp ca/demoCA/cacert.pem social/server/ca-root.pem
     (ca/social.csr, ca/social-ext.cnf and ca/social.crt can then be deleted)

BACK ON THIS SERVER
  9. The certificate must match the private key - both lines identical:
       openssl x509 -noout -pubkey -in server/cert.pem | sha256sum
       openssl pkey -pubout -in server/key.pem | sha256sum
 10. The certificate must chain to the lab CA - expect "OK":
       openssl verify -CAfile server/ca-root.pem server/cert.pem
 11. Restart (on the host); Apache then serves $DOMAIN on 443 and
     sends every plain-HTTP visitor there:
       docker compose restart social
 12. Test in Alice's Firefox: type  $DOMAIN  - it should land on
     https://$DOMAIN with a padlock and no warning (her Firefox already
     trusts the lab CA). Opening https://$SERVER_IP is refused on purpose.
EOF
}

if [ "$1" = "https" ]; then
    https_steps
    exit 0
fi

echo "== Social Lab - server install =="
echo

echo "[1/5] Checking requirements..."
python3 -c "import flask" 2>/dev/null || { echo "      flask is missing: pip install -r requirements.txt"; exit 1; }
command -v openssl >/dev/null || { echo "      openssl is missing"; exit 1; }
echo "      python3, flask and openssl found"

echo "[2/5] Creating data folders..."
mkdir -p uploads server
chmod 700 server
echo "      uploads/  photos people share"
echo "      server/   HTTPS key and certificate (private)"

echo "[3/5] Creating the database and the admin account..."
python3 - <<'PY'
import app
app.init_db()
if app.create_user(app.ADMIN_USER, app.ADMIN_PASSWORD):
    print(f"      account '{app.ADMIN_USER}' created - same login as the CA and DNS portals")
else:
    print(f"      account '{app.ADMIN_USER}' already exists - left unchanged")
PY

echo "[4/5] Demo content (members alice, bob, carol, dave + photos)..."
read -r -p "      Add it now? [Y/n] " seed_answer || seed_answer=""
case "$seed_answer" in
    [nN]*) echo "      Skipped. Add it any time with:  python3 seed_demo.py" ;;
    *)     python3 seed_demo.py ;;
esac

echo "[5/5] Done. The site opens only at https://$DOMAIN, so HTTPS comes next."
echo "      Until then, http://$DOMAIN says it's closed."
echo

read -r -p "Show the HTTPS setup steps now? [Y/n] " answer || answer=""
case "$answer" in
    [nN]*) echo "Show the HTTPS steps any time with:  ./install.sh https" ;;
    *)     echo; https_steps ;;
esac
