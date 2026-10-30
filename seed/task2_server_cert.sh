#!/bin/bash
# SEED Task 2 - Creating a certificate for SEEDPKILab2020.com
# Run from the project folder on the Mac:  seed/task2_server_cert.sh
source "$(dirname "$0")/lib.sh"
set -e

step "Task 2 - A certificate for SEEDPKILab2020.com"
note "Steps 1-2 run on the company's web server (social/ in the project),"
note "step 3 on the CA. The files go in seed/ on each machine."

if [ -f social/seed/server.key ] && [ -t 0 ]; then
    read -r -p "seed/server.key already exists - make a new key and certificate? [y/N] " answer
    case "$answer" in [yY]*) ;; *) echo "Nothing changed."; exit 0 ;; esac
fi
on social "mkdir -p seed && chmod 700 seed"

step "Step 1 - Generate the public/private key pair (web server)"
note "Handout: openssl genrsa -aes128 -out server.key 1024"
note "2048 bits instead of 1024: OpenSSL 3 refuses 1024-bit RSA keys"
note "('ee key too small'). -aes128 encrypts the key file with a passphrase you choose now."
on social "openssl genrsa -aes128 -out seed/server.key 2048"
note "The file is encrypted. To see the numbers inside (asks for the passphrase):"
on social "openssl rsa -in seed/server.key -noout -text | head -20"
pause

step "Step 2 - Generate a Certificate Signing Request (web server)"
note "Common Name: SEEDPKILab2020.com. The CSR carries the public key and the name,"
note "and is signed with the private key (asks for the passphrase)."
on social "openssl req -new -key seed/server.key -out seed/server.csr -subj '/C=IN/ST=Kerala/O=SEEDPKILab2020/CN=SEEDPKILab2020.com'"
on social "openssl req -in seed/server.csr -noout -subject -verify"
pause

step "Step 3 - The CA turns the request into a certificate"
note "The CSR travels to the CA. It is public; the private key stays on the web server."
mac "mkdir -p ca/seed && cp social/seed/server.csr ca/seed/server.csr"
note "Browsers today check only the Subject Alternative Name, not the Common Name,"
note "so the CA writes the name there as well:"
mac "printf '%s\n' 'basicConstraints = CA:FALSE' 'keyUsage = critical, digitalSignature, keyEncipherment' 'extendedKeyUsage = serverAuth' 'subjectKeyIdentifier = hash' 'authorityKeyIdentifier = keyid, issuer' 'subjectAltName = DNS:seedpkilab2020.com' > ca/seed/server-ext.cnf && cat ca/seed/server-ext.cnf"
note "Handout: openssl ca -in server.csr -out server.crt -cert ca.crt -keyfile ca.key -config openssl.cnf"
note "It asks for the CA key's passphrase, then to confirm twice (y)."
on ca "openssl ca -config openssl.cnf -extfile seed/server-ext.cnf -in seed/server.csr -out seed/server.crt"
note "The certificate goes back to the web server, with the CA's certificate (ca.crt) to check it:"
mac "cp ca/seed/server.crt social/seed/server.crt && cp ca/demoCA/cacert.pem social/seed/ca.crt"
on social "openssl x509 -in seed/server.crt -noout -subject -issuer -dates -ext subjectAltName"
on social "openssl verify -CAfile seed/ca.crt seed/server.crt"
note "If Apache already serves this site (Task 4), seed/start_web.sh loads the new certificate."
