#!/bin/bash
# Mint the attacker's SELF-SIGNED certificate for social.lab.  (Task 5)
#
# This is the certificate the whole demo turns on. It names social.lab, so the
# browser's hostname check passes - but no CA signed it, so it does not chain
# to the lab Root CA that Alice's Firefox trusts. That mismatch is exactly what
# makes the browser raise a warning when DNS is spoofed to point here.
#
# (A real attacker cannot get the lab CA to sign a social.lab request: the CA
#  only signs for the operator who registered the domain in the CA portal.)

# 'set -e' = stop the script the moment any command fails, instead of blindly
# carrying on. Safer than letting a half-made cert get used.
set -e
# Run from this script's own folder, whatever directory you called it from,
# so the relative paths below (server/...) always mean attacker/server/.
cd "$(dirname "$0")"

# Make the folder that will hold the key + cert, then lock it to the owner
# (700 = rwx for us, nothing for anyone else) because it holds a private key.
mkdir -p server
chmod 700 server

echo "[attacker] generating a self-signed certificate for social.lab ..."
# One openssl command does three things at once: makes a new RSA key, builds a
# certificate, and signs that certificate with the very key it just made (that
# is what "self-signed" means). Flag by flag:
#   req            work with a certificate request / certificate
#   -x509          output a finished self-signed certificate, not a CSR to send to a CA
#   -newkey rsa:2048  generate a fresh 2048-bit RSA key pair at the same time
#   -nodes         "no DES" = do NOT passphrase-encrypt the key, so Apache can
#                  start unattended (a real server key would be protected)
#   -keyout / -out where to write the private key and the certificate
#   -days 365      how long the certificate is valid
#   -subj          the identity fields, non-interactively; CN=social.lab is the
#                  name the browser matches against the address bar
#   -addext subjectAltName=DNS:social.lab
#                  modern browsers check the SAN, not the CN - so the real name
#                  the cert is valid for lives here
#   -addext basicConstraints=critical,CA:FALSE
#                  "this is a leaf/server cert, it may NOT sign other certs" -
#                  makes it look like a normal website certificate
#   -addext keyUsage / extendedKeyUsage=serverAuth
#                  declares it is a TLS server certificate
# (output is hidden; we print a clean summary ourselves below)
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout server/key.pem -out server/cert.pem -days 365 \
    -subj "/O=Social Lab/CN=social.lab" \
    -addext "subjectAltName=DNS:social.lab" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1
# Tighten the private key to owner-read/write only (600): keys must never be
# world-readable.
chmod 600 server/key.pem

echo "[attacker] done. This cert is NOT signed by the lab CA on purpose:"
# Print the cert's subject (who it is for) and issuer (who signed it). The
# 'sed' just indents each line so the output lines up under the message.
openssl x509 -in server/cert.pem -noout -subject -issuer | sed 's/^/           /'
# For a self-signed cert the issuer and subject are identical - the giveaway a
# browser uses to say "I don't know who vouched for this", i.e. the warning.
echo "           issuer == subject  ->  self-signed  ->  the browser will warn."
