#!/bin/bash
# One-time CA setup.
# Creates the demoCA directory layout required by openssl.cnf [CA_default]
# and generates the root CA private key + self-signed certificate.
set -e
cd "$(dirname "$0")"

if [ -d demoCA ]; then
    echo "demoCA/ already exists."
    echo "If you want to start over:  rm -rf demoCA  and run this again."
    exit 1
fi

echo "[1/3] Creating the demoCA directory structure..."
mkdir -p demoCA/certs demoCA/crl demoCA/newcerts demoCA/private
chmod 700 demoCA/private
touch demoCA/index.txt          # database index file (empty to start)
echo 1000 > demoCA/serial       # the current serial number

echo "[2/3] Generating the root CA key and self-signed certificate..."
openssl req -new -x509 -config openssl.cnf \
    -keyout demoCA/private/cakey.pem \
    -out demoCA/cacert.pem \
    -days 3650 -nodes \
    -subj "/C=IN/ST=Kerala/O=CA Lab/CN=CA Lab Root CA"

echo "[3/3] Done. Root CA certificate:"
openssl x509 -in demoCA/cacert.pem -noout -subject -issuer -dates

echo
echo "Next: ./make_server_cert.sh  (HTTPS certificate for the portal)"
echo "Then: python app.py"
