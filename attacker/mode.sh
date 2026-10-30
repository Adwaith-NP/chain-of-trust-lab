#!/bin/bash
# Pick which certificate the fake social.lab serves, then reload Apache.
# Run from the project root ON THE HOST.
#
#   ./attacker/mode.sh warn      OPTION 1: self-signed cert  -> browser WARNS
#   ./attacker/mode.sh trusted   OPTION 2: forged CA-signed cert -> NO warning
#   ./attacker/mode.sh status    show which cert is live and its issuer
#
# "trusted" needs the forged cert first: run ./attacker/forge_cert.sh (it uses
# the stolen CA key). This only changes the live cert; both the self-signed and
# the forged certs stay on disk, so you can switch back and forth freely.
set -e
cd "$(dirname "$0")/.."

# Three cert folders: the one Apache actually serves (live), the self-signed
# cert (option 1), and the forged CA-signed cert (option 2). Switching just
# copies one pair into "live" - both originals stay on disk.
LIVE="attacker/live"
SELF="attacker/server"
FORGED="attacker/server-forged"

# Tell Apache (inside the attacker container) to re-read its certs WITHOUT
# dropping connections: "apachectl -k graceful". "|| true" so a momentary
# hiccup doesn't abort the script.
reload() { docker compose exec -T attacker apachectl -k graceful 2>/dev/null || true; }

case "$1" in
  warn)
    # Option 1. Make sure the self-signed cert exists (mint it in the container
    # if not), copy it into live/, and reload. Result: browser warns.
    [ -f "$SELF/cert.pem" ] || docker compose exec -T attacker bash make_cert.sh
    mkdir -p "$LIVE"
    cp "$SELF/cert.pem" "$LIVE/cert.pem"; cp "$SELF/key.pem" "$LIVE/key.pem"
    reload
    echo "MODE: warn - serving the SELF-SIGNED cert. Spoofed visitors get a warning."
    ;;
  trusted)
    # Option 2. If we haven't forged a cert yet, do it now (forge_cert.sh steals
    # the CA key and signs social.lab). Then serve that forged cert and reload.
    # Result: it chains to the trusted root, so NO warning.
    if [ ! -f "$FORGED/cert.pem" ]; then
      echo "No forged cert yet - minting one with the stolen CA key ..."
      ./attacker/forge_cert.sh
    fi
    mkdir -p "$LIVE"
    cp "$FORGED/cert.pem" "$LIVE/cert.pem"; cp "$FORGED/key.pem" "$LIVE/key.pem"
    reload
    echo "MODE: trusted - serving the FORGED CA-signed cert. NO browser warning."
    echo "With the hosts spoof on, Alice sees a padlock and nothing looks wrong."
    ;;
  status)
    # Read-only: report which cert is live and whether it is self-signed.
    if [ -f "$LIVE/cert.pem" ]; then
      echo "Live certificate the fake social.lab is serving:"
      openssl x509 -in "$LIVE/cert.pem" -noout -subject -issuer | sed 's/^/  /'
      # A quick, reliable self-signed test: hash the subject name and the issuer
      # name. If they're the same hash, the cert signed itself (option 1); if
      # they differ, something else issued it (option 2, the forged cert).
      subj=$(openssl x509 -in "$LIVE/cert.pem" -noout -subject_hash)
      iss=$(openssl x509 -in "$LIVE/cert.pem" -noout -issuer_hash)
      if [ "$subj" = "$iss" ]; then
        echo "  -> self-signed (issuer == subject): OPTION 1, browser warns."
      else
        echo "  -> issued by a different CA: OPTION 2 (forged). No warning if that CA is the lab root."
      fi
    else
      echo "No live cert yet - start the attacker or run ./attacker/mode.sh warn"
    fi
    ;;
  *)
    echo "usage: $0 {warn|trusted|status}"
    exit 1
    ;;
esac
