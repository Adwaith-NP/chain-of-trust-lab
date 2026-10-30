#!/bin/bash
# Issues an HTTPS certificate for the DNS portal, signed by the CA instance.
# Run from the host (project root) while the compose project is up.
#
# Flow: the dns instance makes its own key + CSR, the CSR is handed to the
# ca instance, which signs it with `openssl ca` (recorded in demoCA/index.txt),
# and the certificate is handed back. The dns private key never leaves dns/.
set -e
cd "$(dirname "$0")"

if [ ! -f ca/demoCA/cacert.pem ]; then
    echo "The CA does not exist yet - run: docker compose exec ca ./setup_ca.sh"
    exit 1
fi

echo "[1/4] dns instance: generating private key + CSR..."
docker compose exec -T dns bash -c '
set -e
mkdir -p server
openssl genrsa -out server/key.pem 2048
openssl req -new -key server/key.pem -out server/csr.pem \
    -subj "/O=DNS Lab/CN=dns.lab"
'

echo "[2/4] Handing the CSR to the ca instance..."
cp dns/server/csr.pem ca/dns-portal.csr

echo "[3/4] ca instance: signing with the CA..."
docker compose exec -T ca bash -c '
set -e
cat > dns-portal-ext.cnf <<EOF
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid, issuer
subjectAltName = DNS:dns.lab
EOF
openssl ca -batch -config openssl.cnf \
    -extfile dns-portal-ext.cnf \
    -in dns-portal.csr -out dns-portal.crt
'

echo "[4/4] Handing the certificate back to the dns instance..."
cp ca/dns-portal.crt dns/server/cert.pem
rm -f ca/dns-portal.csr ca/dns-portal.crt ca/dns-portal-ext.cnf dns/server/csr.pem

docker compose exec -T dns openssl x509 -in server/cert.pem -noout \
    -subject -issuer -ext subjectAltName -enddate

echo
echo "Restarting the dns instance so it picks up HTTPS..."
docker compose restart dns
echo "Done: https://dns.lab"
