#!/bin/bash
# Web server start-up - the container's main process.
#   1. the Social Lab app on 127.0.0.1:8000 (only Apache can reach it)
#   2. Apache: HTTPS for social.lab and seedpkilab2020.com, in front of the app
#   3. the logs, so `docker compose logs social` shows them
cd /app

touch /var/log/social-app.log
python app.py >> /var/log/social-app.log 2>&1 &

# A container restart stops Apache uncleanly and can leave its pid file behind.
rm -f /var/run/apache2/apache2.pid

a2enmod -q ssl proxy proxy_http headers rewrite
a2ensite -q 000-default social-lab
# default-ssl (SEEDPKILab2020.com) is enabled by seed/task4_apache.sh; the
# sites-enabled folder is kept in the project, so that survives a rebuild.

if [ -e /etc/apache2/sites-enabled/default-ssl.conf ] && grep -qs ENCRYPTED seed/server.key; then
    # That site's key has a passphrase and nobody is here to type it, so
    # Apache starts without it; seed/start_web.sh restarts Apache with it.
    echo "Apache: starting without seedpkilab2020.com (its key needs a passphrase) - run seed/start_web.sh"
    APACHE_ARGUMENTS="-D NO_SEED" apachectl start
else
    apachectl start
fi

exec tail -n 0 -F /var/log/apache2/error.log /var/log/apache2/access.log /var/log/social-app.log
