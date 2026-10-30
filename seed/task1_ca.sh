#!/bin/bash
# SEED Task 1 - Becoming a Certificate Authority (CA)
# Run from the project folder on the Mac:  seed/task1_ca.sh
source "$(dirname "$0")/lib.sh"
set -e

step "Task 1 - Becoming a Certificate Authority (CA)"
note "Everything here runs on the CA machine, in its /app folder (ca/ in the project)."

step "1. The configuration file openssl.cnf - its [CA_default] section"
on ca "sed -n '/^\[ CA_default \]/,/^policy/p' openssl.cnf"
note "policy = policy_anything is the handout's less strict policy: a customer's"
note "name fields don't have to match the CA's own."
pause

step "2. The folders and files that section asks for"
if [ ! -d ca/demoCA ]; then
    note "There is no CA yet. setup_ca.sh creates the folders, index.txt, serial and"
    note "the root key + certificate; it asks for a passphrase for the CA key."
    on ca "./setup_ca.sh"
fi
on ca "ls -l demoCA"
on ca 'echo "serial: $(cat demoCA/serial)  (the next certificate gets this number)"; echo "index.txt: $(wc -l < demoCA/index.txt) certificates issued so far"'
pause

step "3. The CA's self-signed root certificate"
note "setup_ca.sh made it with the handout's command (plus -days and -subj):"
note "  openssl req -new -x509 -keyout demoCA/private/cakey.pem -out demoCA/cacert.pem -config openssl.cnf"
note "The handout's ca.key is demoCA/private/cakey.pem and ca.crt is demoCA/cacert.pem:"
note "the names openssl.cnf expects, so 'openssl ca' needs no -cert/-keyfile options."
on ca "openssl x509 -in demoCA/cacert.pem -noout -subject -issuer -dates"
note "Subject and issuer are the same: the CA signed its own certificate (self-signed)."
on ca "openssl x509 -in demoCA/cacert.pem -noout -ext basicConstraints,keyUsage"
note "CA:TRUE and 'Certificate Sign': this certificate may sign other certificates."
pause

step "4. The CA's private key is protected by a passphrase"
if grep -q ENCRYPTED ca/demoCA/private/cakey.pem; then
    note "It already is:"
else
    note "It was made without one. Encrypting it now with AES-256: choose a passphrase"
    note "and keep it - every certificate the CA signs from now on needs it."
    on ca "openssl pkey -in demoCA/private/cakey.pem -aes256 -out demoCA/private/cakey.new && mv demoCA/private/cakey.new demoCA/private/cakey.pem && chmod 600 demoCA/private/cakey.pem"
fi
on ca "head -1 demoCA/private/cakey.pem"
note "From now on the CA portal starts locked. Unlock it on its dashboard"
note "(https://ca.lab) with this passphrase; it is kept in memory only."
