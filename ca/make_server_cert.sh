#!/bin/bash
# Issues an HTTPS certificate for the web portal itself, signed by our own CA.
# Run after ./setup_ca.sh. The Flask app picks it up automatically.
set -e
cd "$(dirname "$0")"

if [ ! -f demoCA/cacert.pem ]; then
    echo "The CA does not exist yet - run ./setup_ca.sh first."
    exit 1
fi

mkdir -p server

echo "[1/3] Generating the portal's private key and CSR..."
openssl genrsa -out server/key.pem 2048
openssl req -new -config openssl.cnf \
    -key server/key.pem -out server/csr.pem \
    -subj "/O=CA Lab/CN=ca.lab"

echo "[2/3] Signing it with the CA..."
cat > server/extensions.cnf <<'EOF'
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid, issuer
subjectAltName = DNS:ca.lab
EOF
openssl ca -batch -config openssl.cnf \
    -extfile server/extensions.cnf \
    -in server/csr.pem -out server/cert.pem

echo "[3/3] Done. Portal certificate:"
openssl x509 -in server/cert.pem -noout -subject -ext subjectAltName -enddate

echo
echo "python app.py will now serve HTTPS."
