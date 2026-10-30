#!/bin/bash
# SEED Task 3, Step 4.1 - Modify a single byte of server.pem
# Run from the project folder on the Mac:
#   seed/task3_modify_byte.sh        change a byte of the certificate
#   seed/task3_modify_byte.sh key    change a byte of the private key
source "$(dirname "$0")/lib.sh"
set -e

MODE=${1:-cert}
[ -f social/seed/server.pem ] || { echo "Run seed/task3_s_server.sh first (it makes server.pem)."; exit 1; }

step "Task 3, Step 4.1 - Change one byte of server.pem ($MODE)"
note "server.pem holds the encrypted private key, then the certificate. A copy,"
note "server_modified.pem, gets one byte changed - server.pem itself stays as it"
note "was, so there is nothing to restore afterwards."
on social "python3 tools/modify_byte.py $MODE"

if [ "$MODE" = "cert" ]; then
    note "The certificate still reads fine, but the CA's signature no longer matches it:"
    on social "openssl verify -CAfile seed/ca.crt seed/server_modified.pem || true"
    note "Start the server with it and reload https://seedpkilab2020.com:4433 - the"
    note "browser rejects the certificate because the signature check fails"
    note "(Firefox: SEC_ERROR_BAD_SIGNATURE). Ctrl+C stops the server."
    on social "openssl s_server -cert seed/server_modified.pem -accept 4433 -www"
else
    note "The key no longer decrypts with its passphrase, so the server cannot start:"
    on social "openssl s_server -cert seed/server_modified.pem -accept 4433 -www || true"
fi
