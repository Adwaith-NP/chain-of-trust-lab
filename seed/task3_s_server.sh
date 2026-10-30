#!/bin/bash
# SEED Task 3 - Deploying the certificate in an HTTPS web server (openssl s_server)
# Run from the project folder on the Mac:  seed/task3_s_server.sh
source "$(dirname "$0")/lib.sh"
set -e

[ -f social/seed/server.crt ] || { echo "Run seed/task2_server_cert.sh first."; exit 1; }

step "Task 3 - An HTTPS web server with openssl s_server"

step "Step 1 - DNS: SEEDPKILab2020.com points to the web server"
note "Handout: a line in /etc/hosts. The lab has its own DNS server, so one record"
note "there is enough for every lab machine:"
on dns "./add_record.sh seedpkilab2020.com 172.28.0.20 SEEDPKILab2020 'SEED PKI lab website'"
on alice "getent hosts seedpkilab2020.com"
note "The Mac doesn't use the lab DNS: seed/mac_hosts.sh adds the name to its /etc/hosts."
pause

step "Step 2 - Configure and start the web server"
note "s_server wants the private key and the certificate in one file:"
on social "cp seed/server.key seed/server.pem && cat seed/server.crt >> seed/server.pem"
echo
note "When it runs (it asks for server.key's passphrase), open:"
note "  Chrome on the Mac:   https://seedpkilab2020.com:4433"
note "  Alice's Firefox:     https://seedpkilab2020.com:4433"
note "Chrome first says the issuer is unknown: the Mac doesn't trust our CA yet."
note "Alice's Firefox already does (the lab's Firefox policy)."
note "Step 3 - seed/mac_trust_ca.sh makes the Mac trust the CA; then reload in Chrome."
note "Step 4.2 - also open https://localhost:4433: same server, but the"
note "certificate names only seedpkilab2020.com."
note "Step 4.1 - seed/task3_modify_byte.sh. Ctrl+C stops this server."
on social "openssl s_server -cert seed/server.pem -accept 4433 -www"
