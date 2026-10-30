"""DNS Lab web portal + DNS server.

One process, two services:
- A Flask portal where the admin logs in and registers a domain name -> IP
  with company details (stored in SQLite).
- A small authoritative DNS server (dnslib, port 53 udp+tcp) that answers
  A queries straight from the same database, so a registered domain
  resolves immediately.
"""

import ipaddress
import os
import re
import sqlite3
import threading
from datetime import datetime, timezone
from functools import wraps
from pathlib import Path

from dnslib import QTYPE, RCODE, RR, A, DNSRecord
from dnslib.server import BaseResolver, DNSServer
from flask import (Flask, flash, redirect, render_template, request,
                   session, url_for)
from werkzeug.serving import make_server
from werkzeug.wrappers import Request, Response

BASE_DIR = Path(__file__).resolve().parent
DB_PATH = BASE_DIR / "dns_portal.db"
SERVER_CERT = BASE_DIR / "server" / "cert.pem"
SERVER_KEY = BASE_DIR / "server" / "key.pem"

# The only name the portal answers to; requests for its IP, localhost or
# any other name are refused. The DNS server also always resolves this name
# to SELF_IP, so the portal is reachable before any record is registered.
SITE_DOMAIN = os.environ.get("SITE_DOMAIN", "dns.lab")
SELF_IP = os.environ.get("DNS_SELF_IP", "172.28.0.53")

# Lab credentials - override with environment variables if you want.
ADMIN_USER = os.environ.get("DNS_ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("DNS_ADMIN_PASSWORD", "admin123")
DNS_PORT = int(os.environ.get("DNS_PORT", "53"))
# Queries for names we don't own are forwarded here, so clients using this
# server as their resolver can still reach the normal internet.
UPSTREAM_DNS = os.environ.get("UPSTREAM_DNS", "8.8.8.8")

app = Flask(__name__)
app.secret_key = os.environ.get("DNS_SECRET_KEY", "dns-lab-dev-secret")
app.config["SESSION_COOKIE_SECURE"] = True


@app.before_request
def only_own_domain():
    if request.host.split(":")[0].lower() != SITE_DOMAIN:
        return (f"This server only answers as https://{SITE_DOMAIN}\n", 421,
                {"Content-Type": "text/plain; charset=utf-8"})

DOMAIN_RE = re.compile(
    r"^(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))+$")


# ---------------------------------------------------------------- database

def get_db():
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    return db


def init_db():
    with get_db() as db:
        db.execute("""
            CREATE TABLE IF NOT EXISTS records (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                domain     TEXT NOT NULL UNIQUE,
                ip         TEXT NOT NULL,
                company    TEXT NOT NULL,
                email      TEXT,
                details    TEXT,
                created_at TEXT NOT NULL
            )
        """)


def lookup_ip(domain):
    with get_db() as db:
        row = db.execute(
            "SELECT ip FROM records WHERE domain = ?", (domain,)).fetchone()
    if row:
        return row["ip"]
    return SELF_IP if domain == SITE_DOMAIN else None


# ---------------------------------------------------------------- DNS server

class PortalResolver(BaseResolver):
    """Authoritative for the records table; forwards everything else upstream."""

    def resolve(self, request, handler):
        qname = str(request.q.qname).rstrip(".").lower()
        ip = lookup_ip(qname)
        if ip is not None:
            reply = request.reply()
            if request.q.qtype in (QTYPE.A, QTYPE.ANY):
                reply.add_answer(
                    RR(request.q.qname, QTYPE.A, rdata=A(ip), ttl=60))
            # Known domain but another query type: empty NOERROR reply.
            return reply
        # Not one of ours: ask the upstream resolver on the client's behalf.
        try:
            raw = request.send(UPSTREAM_DNS, 53, timeout=3)
            return DNSRecord.parse(raw)
        except Exception:
            reply = request.reply()
            reply.header.rcode = RCODE.SERVFAIL
            return reply


def start_dns_server():
    resolver = PortalResolver()
    DNSServer(resolver, address="0.0.0.0", port=DNS_PORT).start_thread()
    DNSServer(resolver, address="0.0.0.0", port=DNS_PORT, tcp=True).start_thread()
    print(f" * DNS server listening on port {DNS_PORT} (udp + tcp)")


# ---------------------------------------------------------------- auth

def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if not session.get("logged_in"):
            return redirect(url_for("login"))
        return view(*args, **kwargs)
    return wrapped


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        if (request.form.get("username") == ADMIN_USER
                and request.form.get("password") == ADMIN_PASSWORD):
            session["logged_in"] = True
            return redirect(url_for("dashboard"))
        flash("Wrong username or password.")
    return render_template("login.html")


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# ---------------------------------------------------------------- portal

@app.route("/")
@login_required
def dashboard():
    with get_db() as db:
        records = db.execute(
            "SELECT * FROM records ORDER BY domain").fetchall()
    return render_template("dashboard.html", records=records)


@app.route("/records", methods=["POST"])
@login_required
def add_record():
    domain = request.form.get("domain", "").strip().lower().rstrip(".")
    ip = request.form.get("ip", "").strip()
    company = request.form.get("company", "").strip()
    email = request.form.get("email", "").strip()
    details = request.form.get("details", "").strip()

    if not DOMAIN_RE.match(domain):
        flash(f"'{domain}' is not a valid domain name (e.g. example.lab).")
        return redirect(url_for("dashboard"))
    try:
        ipaddress.ip_address(ip)
    except ValueError:
        flash(f"'{ip}' is not a valid IP address.")
        return redirect(url_for("dashboard"))
    if not company:
        flash("Company name is required.")
        return redirect(url_for("dashboard"))

    try:
        with get_db() as db:
            db.execute(
                "INSERT INTO records (domain, ip, company, email, details, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (domain, ip, company, email, details,
                 datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")))
    except sqlite3.IntegrityError:
        flash(f"{domain} is already registered.")
        return redirect(url_for("dashboard"))

    flash(f"{domain} now resolves to {ip}.")
    return redirect(url_for("dashboard"))


@app.route("/records/<int:record_id>/delete", methods=["POST"])
@login_required
def delete_record(record_id):
    with get_db() as db:
        row = db.execute("SELECT domain FROM records WHERE id = ?",
                         (record_id,)).fetchone()
        db.execute("DELETE FROM records WHERE id = ?", (record_id,))
    if row:
        flash(f"{row['domain']} removed.")
    return redirect(url_for("dashboard"))


init_db()

def http_front(https_ready):
    """Port 80 takes plain HTTP from anyone, but only to send the visitor on
    to https://SITE_DOMAIN - it never serves the portal itself."""
    @Request.application
    def front(req):
        if not https_ready:
            return Response(
                f"The DNS portal only runs over HTTPS at https://{SITE_DOMAIN},\n"
                "which isn't set up yet.\n", status=503, mimetype="text/plain")
        target = f"https://{SITE_DOMAIN}{req.path}"
        if req.query_string:
            target += "?" + req.query_string.decode()
        return redirect(target, code=301)

    return make_server("0.0.0.0", 80, front)


if __name__ == "__main__":
    start_dns_server()
    # use_reloader=False: the reloader forks a second process, which would
    # try to bind ports 53 and 80 again.
    if SERVER_CERT.exists() and SERVER_KEY.exists():
        print(f" * HTTPS on port 443 as {SITE_DOMAIN} only; port 80 redirects there")
        front = http_front(https_ready=True)
        threading.Thread(target=front.serve_forever, daemon=True).start()
        app.run(host="0.0.0.0", port=443, debug=True, use_reloader=False,
                ssl_context=(str(SERVER_CERT), str(SERVER_KEY)))
    else:
        print(" * No certificate - the portal stays closed until "
              "./make_dns_cert.sh (project root) is run", flush=True)
        http_front(https_ready=False).serve_forever()
