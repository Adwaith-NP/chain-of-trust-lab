#!/bin/bash
# The attacker's console. Run it after shelling into the instance:
#
#     docker compose exec attacker bash
#     ./attack.sh
#
# Apache and the harvester are already running (the container starts them).
# This just shows status and then tails harvested.log, so every username and
# password a victim submits to the fake social.lab appears here live.
cd "$(dirname "$0")"

echo "======================================================================"
echo " ATTACKER CONSOLE - fake social.lab login (SEED PKI lab, MITM demo)"
echo "======================================================================"
if [ -f server/cert.pem ]; then
    echo " Rogue certificate in use (self-signed, not from the lab CA):"
    openssl x509 -in server/cert.pem -noout -subject -issuer | sed 's/^/   /'
else
    echo " No certificate yet - run ./make_cert.sh"
fi
echo
echo " To send victims here, poison Alice's /etc/hosts from the host:"
echo "   ./attacker/spoof.sh on     (adds '172.28.0.66 social.lab' to alice)"
echo " To stop the attack, remove that line again:"
echo "   ./attacker/spoof.sh off"
echo
echo " Certificate: ./attacker/mode.sh warn    self-signed  -> browser warns"
echo "              ./attacker/mode.sh trusted  forged (stolen CA key) -> no warning"
echo
echo " Captured logins (waiting - Ctrl-C to stop watching):"
echo "----------------------------------------------------------------------"
touch harvested.log
tail -n 100 -F harvested.log
