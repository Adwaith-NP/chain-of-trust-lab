#!/bin/bash
# The Mac doesn't use the lab's DNS server. Adding the lab's names to the
# Mac's /etc/hosts sends them to this Mac, where Docker publishes the sites.
# Asks for your Mac password (sudo).
source "$(dirname "$0")/lib.sh"
set -e

step "Point the lab's names at this Mac (/etc/hosts)"
missing=""
for name in ca.lab dns.lab social.lab seedpkilab2020.com; do
    if ! awk -v n="$name" '!/^[[:space:]]*#/ { for (i = 2; i <= NF; i++) if ($i == n) f = 1 } END { exit !f }' /etc/hosts; then
        missing="$missing $name"
    fi
done

if [ -z "$missing" ]; then
    note "Every name is already there."
else
    mac "echo '127.0.0.1$missing' | sudo tee -a /etc/hosts"
fi
note "From the Mac: https://ca.lab:5001  https://dns.lab:5002  https://social.lab"
note "              https://seedpkilab2020.com  https://seedpkilab2020.com:4433 (Task 3)"
