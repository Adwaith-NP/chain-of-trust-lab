#!/bin/bash
# Add or update a DNS record from the command line - the same as the DNS
# portal's "Register a domain" form. The DNS server answers from the same
# database, so the name resolves at once.
#   docker compose exec dns ./add_record.sh seedpkilab2020.com 172.28.0.20 "SEEDPKILab2020"
set -e
cd "$(dirname "$0")"

if [ $# -lt 3 ]; then
    echo "usage: $0 <domain> <ip> <company> [details]"
    exit 1
fi

python3 - "$@" <<'PY'
import ipaddress
import sqlite3
import sys
from datetime import datetime, timezone

import app  # the portal's database location and domain-name rule

domain = sys.argv[1].strip().lower().rstrip(".")
ip, company = sys.argv[2].strip(), sys.argv[3].strip()
details = sys.argv[4] if len(sys.argv) > 4 else ""
if not app.DOMAIN_RE.match(domain):
    sys.exit(f"'{domain}' is not a valid domain name")
try:
    ipaddress.ip_address(ip)
except ValueError:
    sys.exit(f"'{ip}' is not a valid IP address")

db = sqlite3.connect(app.DB_PATH)
db.execute(
    "INSERT INTO records (domain, ip, company, email, details, created_at) "
    "VALUES (?, ?, ?, '', ?, ?) "
    "ON CONFLICT(domain) DO UPDATE SET ip = excluded.ip, "
    "company = excluded.company, details = excluded.details",
    (domain, ip, company, details,
     datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")))
db.commit()
print(f"{domain} -> {ip}  ({company})")
PY
