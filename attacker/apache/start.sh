#!/bin/bash
# Attacker container start-up - the container's main process.
#   1. mint the self-signed social.lab cert if it isn't there yet
#   2. the harvester app on 127.0.0.1:8000 (only Apache reaches it)
#   3. Apache: HTTPS as social.lab, with the rogue cert, in front of the app
#   4. tail the logs AND harvested.log, so captured logins show up in
#      `docker compose logs -f attacker`
cd /app

[ -f server/cert.pem ] || bash make_cert.sh

touch harvested.log /var/log/attacker-app.log
python app.py >> /var/log/attacker-app.log 2>&1 &

# A restart can leave Apache's pid file behind.
rm -f /var/run/apache2/apache2.pid

a2enmod -q ssl proxy proxy_http headers rewrite
a2dissite -q 000-default 2>/dev/null
ln -sf /app/apache/attacker.conf /etc/apache2/sites-enabled/attacker.conf
apachectl start

echo "[attacker] serving a fake social.lab on :443 with a self-signed cert."
echo "[attacker] waiting for logins (they print below and go to harvested.log)."
exec tail -n 0 -F harvested.log /var/log/apache2/error.log /var/log/attacker-app.log
