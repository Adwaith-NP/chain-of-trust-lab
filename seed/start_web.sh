#!/bin/bash
# After the web server restarts, Apache comes up without SEEDPKILab2020.com:
# that site's key has a passphrase and nobody was there to type it. This
# restarts Apache with every site - type the passphrase when asked.
source "$(dirname "$0")/lib.sh"
set -e

step "Start Apache with SEEDPKILab2020.com"
on social "apache/restart.sh"
