#!/bin/bash
# Mint the attacker's SELF-SIGNED certificate for social.lab.
#
# This is the certificate the whole demo turns on. It names social.lab, so the
# browser's hostname check passes - but no CA signed it, so it does not chain
# to the lab Root CA that Alice's Firefox trusts. That mismatch is exactly what
# makes the browser raise a warning when DNS is spoofed to point here.
#
# (A real attacker cannot get the lab CA to sign a social.lab request: the CA
#  only signs for the operator who registered the domain in the CA portal.)
set -e
cd "$(dirname "$0")"

mkdir -p server
chmod 700 server

echo "[attacker] generating a self-signed certificate for social.lab ..."
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout server/key.pem -out server/cert.pem -days 365 \
    -subj "/O=Social Lab/CN=social.lab" \
    -addext "subjectAltName=DNS:social.lab" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1
chmod 600 server/key.pem

echo "[attacker] done. This cert is NOT signed by the lab CA on purpose:"
openssl x509 -in server/cert.pem -noout -subject -issuer | sed 's/^/           /'
echo "           issuer == subject  ->  self-signed  ->  the browser will warn."
