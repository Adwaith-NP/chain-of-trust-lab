#!/bin/bash
# CA Lab - certificate enrollment
#
# Run it on the server that needs the certificate:
#     bash enroll.sh [folder]          (default folder: ./server)
#
# What it does - and nothing else:
#   1. asks for your one-time enrollment code and shows what it is for
#   2. creates a private key in the folder; the key never leaves this machine
#   3. sends the CA only a certificate request (CSR) and the code
#   4. checks the signed certificate, then saves it next to the key
#
# It needs ca-root.pem - the CA certificate whose fingerprint you checked -
# in the current folder, and talks to the CA only through that certificate.
set -euo pipefail

CA_URL="https://ca.lab"
ROOT="$PWD/ca-root.pem"
DIR="${1:-server}"

fail() { echo "error: $*" >&2; exit 1; }

for tool in curl openssl sha256sum; do
    command -v "$tool" >/dev/null || fail "$tool is not installed"
done
[ -f "$ROOT" ] || fail "ca-root.pem not found here - do step 1 of the instructions first"

# POST to the CA. The code goes in on stdin, so it never appears on a
# command line; extra curl -F fields can follow. Prints the CA's answer,
# or its reason for refusing and exits.
ask_ca() {
    local path=$1 out status
    shift
    out=$(mktemp)
    status=$(printf '%s' "$CODE" | curl -sS --cacert "$ROOT" -o "$out" \
        -w '%{http_code}' -F 'code=<-' "$@" "$CA_URL$path") \
        || { rm -f "$out"; fail "could not reach $CA_URL"; }
    if [ "$status" != "200" ]; then
        echo "The CA refused: $(cat "$out")" >&2
        rm -f "$out"
        exit 1
    fi
    cat "$out"
    rm -f "$out"
}

echo "== CA Lab certificate enrollment =="
read -r -s -p "One-time enrollment code: " CODE || true
echo
[ -n "$CODE" ] || fail "no code given"

INFO=$(ask_ca /enroll/check)
DOMAIN=$(printf '%s\n' "$INFO" | sed -n 's/^domain=//p')
[[ "$DOMAIN" =~ ^[a-z0-9.-]+$ ]] || fail "unexpected answer from the CA"
echo
printf '%s\n' "$INFO" | sed -e 's/^company=/  Company:   /' -e 's/^domain=/  Domain:    /' \
    -e 's/^ip=/  Server:    /' -e 's/^expires=/  Code valid until /'
echo
read -r -p "Request a certificate for $DOMAIN? [y/N] " answer || answer=""
case "$answer" in [yY]*) ;; *) echo "Stopped - nothing was created."; exit 0 ;; esac

mkdir -p "$DIR"
chmod 700 "$DIR"
if [ -e "$DIR/key.pem" ] || [ -e "$DIR/cert.pem" ]; then
    read -r -p "$DIR/ already has a key or certificate - replace them? [y/N] " answer || answer=""
    case "$answer" in [yY]*) ;; *) echo "Stopped - existing files left as they were."; exit 0 ;; esac
fi
# New files only replace the old ones once everything has checked out.
trap 'rm -f "$DIR/key.new" "$DIR/cert.new" "$DIR/request.csr"' EXIT
umask 077

echo "[1/3] Creating the private key in $DIR/ (it stays on this machine)..."
openssl genrsa -out "$DIR/key.new" 2048 2>/dev/null
openssl req -new -key "$DIR/key.new" -subj "/CN=$DOMAIN" -out "$DIR/request.csr"

echo "[2/3] Sending the certificate request to the CA..."
ask_ca /enroll -F "csr=<$DIR/request.csr" > "$DIR/cert.new"

echo "[3/3] Checking the certificate..."
[ "$(openssl x509 -in "$DIR/cert.new" -noout -pubkey | sha256sum)" = \
  "$(openssl pkey -in "$DIR/key.new" -pubout | sha256sum)" ] \
    || fail "the certificate doesn't match the private key"
openssl verify -CAfile "$ROOT" "$DIR/cert.new" >/dev/null \
    || fail "the certificate doesn't chain to the CA"
openssl x509 -in "$DIR/cert.new" -noout -ext subjectAltName | grep -qF "DNS:$DOMAIN" \
    || fail "the certificate doesn't name $DOMAIN"
mv "$DIR/key.new" "$DIR/key.pem"
mv "$DIR/cert.new" "$DIR/cert.pem"
cp "$ROOT" "$DIR/ca-root.pem"

echo
echo "Done. Saved in $DIR/:"
echo "  key.pem      private key - never share it"
echo "  cert.pem     certificate for $DOMAIN, signed by CA Lab"
echo "  ca-root.pem  CA Lab's certificate"
openssl x509 -in "$DIR/cert.pem" -noout -subject -serial -enddate | sed 's/^/  /'
echo
echo "Restart your web server so it uses the new certificate."
