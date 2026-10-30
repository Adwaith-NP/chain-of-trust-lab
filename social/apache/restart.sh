#!/bin/bash
# Restart Apache with every enabled site. seedpkilab2020.com's key has a
# passphrase, so Apache asks for it now - just as "sudo service apache2
# restart" does on a normal server. A wrong passphrase only leaves that site
# out; social.lab keeps running.
PIDFILE=/var/run/apache2/apache2.pid
apachectl stop 2>/dev/null
for _ in $(seq 50); do [ -e "$PIDFILE" ] || break; sleep 0.2; done
rm -f "$PIDFILE"   # left behind if Apache wasn't running

if ! apachectl start; then
    echo "Apache could not start with seedpkilab2020.com (wrong passphrase?)."
    echo "Starting without it - run this again to retry."
    APACHE_ARGUMENTS="-D NO_SEED" apachectl start
fi
