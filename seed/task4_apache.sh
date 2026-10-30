#!/bin/bash
# SEED Task 4 - Deploying the certificate in an Apache-based HTTPS website
# Run from the project folder on the Mac:  seed/task4_apache.sh
source "$(dirname "$0")/lib.sh"
set -e

[ -f social/seed/server.crt ] || { echo "Run seed/task2_server_cert.sh first."; exit 1; }

step "Task 4 - An Apache HTTPS website for SEEDPKILab2020.com"
note "Apache runs on the web server (172.28.0.20), in front of the Social Lab app."
note "Its site files are in the project: social/apache/sites-available/."

step "1. The VirtualHost entries for SEEDPKILab2020.com (default-ssl.conf)"
on social "cat /etc/apache2/sites-available/default-ssl.conf"
note "000-default.conf comes first: requests by IP or for unknown names get 421."
pause

step "2. Test the configuration, enable SSL and the site"
on social "apachectl configtest"
on social "a2enmod ssl"
on social "a2ensite default-ssl"
pause

step "3. Restart Apache - it asks for server.key's passphrase"
note "Handout: sudo service apache2 restart. Here apache/restart.sh does"
note "apachectl stop + start; Apache keeps running in the background afterwards."
on social "apache/restart.sh"

step "4. Browse the site"
note "Chrome on the Mac:   https://seedpkilab2020.com   (http:// redirects there)"
note "Alice's Firefox:     https://seedpkilab2020.com"
note "https://172.28.0.20 is refused (421): the site answers only to its name."
on alice "curl -sS --cacert /usr/lib/mozilla/certificates/ca-lab-root.pem -o /dev/null -w 'https://seedpkilab2020.com/login -> %{http_code}, certificate verified\n' https://seedpkilab2020.com/login"
note "After the web server restarts, run seed/start_web.sh (it asks for the passphrase)."
