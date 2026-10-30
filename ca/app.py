"""CA Lab web portal.

Flask app in front of an OpenSSL certificate authority (demoCA).

- The operator logs in and registers a company: name, domain and server IP.
  The portal creates a one-time enrollment code (only its hash is stored)
  and a message to send to the company over a secure channel.
- On the company's server, enroll.sh creates the private key locally and
  sends only a certificate request plus the code. The CA signs it if the
  code is valid and unused, the request comes from the registered IP, and
  the lab DNS points the domain at that IP. The CA, not the request,
  decides what the certificate says.

Run `./setup_ca.sh` once before starting this app.
"""

import hashlib
import ipaddress
import os
import re
import secrets
import socket
import sqlite3
import ssl
import subprocess
import threading
from datetime import datetime, timedelta, timezone
from functools import wraps
from pathlib import Path

from flask import (Flask, abort, flash, redirect, render_template, request,
                   send_file, session, url_for)
from werkzeug.serving import make_server
from werkzeug.wrappers import Request, Response

BASE_DIR = Path(__file__).resolve().parent
CA_DIR = BASE_DIR / "demoCA"
CA_CERT = CA_DIR / "cacert.pem"
DB_PATH = BASE_DIR / "ca_portal.db"
OPENSSL_CNF = BASE_DIR / "openssl.cnf"
ENROLL_DIR = BASE_DIR / "enrollments"
ENROLL_SCRIPT = BASE_DIR / "enroll.sh"
SERVER_CERT = BASE_DIR / "server" / "cert.pem"
SERVER_KEY = BASE_DIR / "server" / "key.pem"

# The only name this site answers to; requests for its IP, localhost or
# any other name are refused.
SITE_DOMAIN = os.environ.get("SITE_DOMAIN", "ca.lab")

# How long a one-time enrollment code stays usable.
CODE_HOURS = int(os.environ.get("ENROLL_CODE_HOURS", "24"))

# Lab credentials - override with environment variables if you want.
ADMIN_USER = os.environ.get("CA_ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("CA_ADMIN_PASSWORD", "admin123")

DOMAIN_RE = re.compile(
    r"^(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))+$")

app = Flask(__name__)
app.secret_key = os.environ.get("CA_SECRET_KEY", "ca-lab-dev-secret")
app.config["SESSION_COOKIE_SECURE"] = True


@app.before_request
def only_own_domain():
    if request.host.split(":")[0].lower() != SITE_DOMAIN:
        return (f"This server only answers as https://{SITE_DOMAIN}\n", 421,
                {"Content-Type": "text/plain; charset=utf-8"})


def utcnow():
    return datetime.now(timezone.utc)


def stamp(moment):
    return moment.strftime("%Y-%m-%d %H:%M UTC")


def plain(body, status=200):
    return Response(body.rstrip("\n") + "\n", status=status,
                    mimetype="text/plain")


# ---------------------------------------------------------------- database

def get_db():
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    return db


def init_db():
    with get_db() as db:
        db.execute("""
            CREATE TABLE IF NOT EXISTS enrollments (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                company    TEXT NOT NULL,
                email      TEXT,
                domain     TEXT NOT NULL,
                ip         TEXT NOT NULL,
                details    TEXT,
                code_hash  TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                status     TEXT NOT NULL,  -- waiting, signing, issued, cancelled
                created_at TEXT NOT NULL,
                used_at    TEXT,
                used_from  TEXT,
                serial     TEXT
            )
        """)


def enrollment_or_404(enrollment_id):
    with get_db() as db:
        e = db.execute("SELECT * FROM enrollments WHERE id = ?",
                       (enrollment_id,)).fetchone()
    if e is None:
        abort(404)
    return e


def state_of(e):
    if (e["status"] == "waiting"
            and datetime.fromisoformat(e["expires_at"]) <= utcnow()):
        return "expired"
    return e["status"]


# ---------------------------------------------------------------- openssl

def run_openssl(args):
    """Run an openssl command from the project directory (demoCA is relative)."""
    result = subprocess.run(
        ["openssl", *args],
        cwd=BASE_DIR,
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"openssl {args[0]} failed:\n{result.stderr}")
    return result.stdout


def ca_fingerprint():
    der = ssl.PEM_cert_to_DER_cert(CA_CERT.read_text().strip())
    digest = hashlib.sha256(der).hexdigest().upper()
    return ":".join(digest[i:i + 2] for i in range(0, len(digest), 2))


def sign_request(e, csr_pem):
    """Sign the company's request. The CA - not the request - decides what
    the certificate says: the registered domain, for a web server only."""
    work = ENROLL_DIR / str(e["id"])
    work.mkdir(parents=True, exist_ok=True)
    csr_path = work / "request.csr"
    ext_path = work / "extensions.cnf"
    cert_path = work / "cert.pem"
    csr_path.write_text(csr_pem)

    # Proves the requester holds the private key behind the request.
    try:
        run_openssl(["req", "-in", str(csr_path), "-noout", "-verify"])
    except RuntimeError:
        raise ValueError("the request's signature doesn't verify") from None
    details = run_openssl(["req", "-in", str(csr_path), "-noout", "-text"])
    bits = re.search(r"Public-Key: \((\d+) bit\)", details)
    if "rsaEncryption" in details and (not bits or int(bits.group(1)) < 2048):
        raise ValueError("RSA keys must be at least 2048 bits")

    ext_path.write_text(
        "basicConstraints = CA:FALSE\n"
        "keyUsage = critical, digitalSignature, keyEncipherment\n"
        "extendedKeyUsage = serverAuth\n"
        "subjectKeyIdentifier = hash\n"
        "authorityKeyIdentifier = keyid, issuer\n"
        f"subjectAltName = DNS:{e['domain']}\n")
    org = re.sub(r"[^A-Za-z0-9 ._-]", "", e["company"]).strip() or e["domain"]
    run_openssl(["ca", "-batch", "-notext", "-config", str(OPENSSL_CNF),
                 "-extfile", str(ext_path),
                 "-subj", f"/O={org}/CN={e['domain']}",
                 "-in", str(csr_path), "-out", str(cert_path)])
    serial = run_openssl(["x509", "-in", str(cert_path), "-noout",
                          "-serial"]).strip().split("=", 1)[1]
    return cert_path.read_text(), serial


# ---------------------------------------------------------------- codes

def new_code():
    """Returns (code, its hash, expiry). Only the hash is ever stored."""
    code = secrets.token_urlsafe(24)
    expires = utcnow() + timedelta(hours=CODE_HOURS)
    return (code, hashlib.sha256(code.encode()).hexdigest(),
            expires.isoformat(timespec="seconds"))


def enrollment_for_code(code):
    """Returns (enrollment, None) for a usable code, else (None, reason)."""
    code = code.strip()
    if not code:
        return None, "No enrollment code was given."
    with get_db() as db:
        e = db.execute("SELECT * FROM enrollments WHERE code_hash = ?",
                       (hashlib.sha256(code.encode()).hexdigest(),)).fetchone()
    if e is None:
        return None, "Unknown enrollment code - check it was pasted completely."
    state = state_of(e)
    if state != "waiting":
        return None, {
            "expired": "This enrollment code has expired - ask the CA operator for a new one.",
            "issued": "This enrollment code was already used - each code works once.",
            "signing": "This enrollment code is being used right now.",
            "cancelled": "This enrollment code was cancelled by the CA operator.",
        }[state]
    return e, None


def requester_problem(e):
    """The request must come from the registered server, and the lab DNS must
    point the domain at it - a small version of a real CA's domain check."""
    source = request.remote_addr
    if source != e["ip"]:
        return (f"This code only works from {e['ip']} - "
                f"this request came from {source}.")
    try:
        addresses = {info[4][0] for info in socket.getaddrinfo(e["domain"], None)}
    except socket.gaierror:
        addresses = set()
    if e["ip"] not in addresses:
        return (f"{e['domain']} doesn't point to {e['ip']} in DNS yet - "
                "ask the operator to register it in the DNS portal.")
    return None


def enrollment_message(e, code):
    """The text the operator sends to the company over a secure channel."""
    url = f"https://{SITE_DOMAIN}"
    expires = stamp(datetime.fromisoformat(e["expires_at"]))
    return f"""Certificate enrollment - CA Lab
Company:  {e['company']}
Domain:   {e['domain']}
The code below works once, until {expires}, and only from {e['ip']}.

Run these on your server ({e['ip']}), in your web server's folder.

1. Get the CA certificate (not trusted yet, hence -k) and check its fingerprint:
   curl -sSk {url}/ca-certificate -o ca-root.pem
   [ "$(openssl x509 -in ca-root.pem -noout -fingerprint -sha256 | cut -d= -f2)" = "{ca_fingerprint()}" ] && echo "OK - this is CA Lab" || echo "STOP - not CA Lab: delete ca-root.pem"

2. Download the enrollment script over the now-verified connection, and read it:
   curl -sS --cacert ca-root.pem {url}/enroll.sh -o enroll.sh
   cat enroll.sh

3. Run it. It saves the key and certificate in ./server and asks for the code:
   bash enroll.sh

   One-time code: {code or "(shown only once, when it was made)"}
"""


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


# ---------------------------------------------------------------- operator

@app.route("/")
@login_required
def dashboard():
    if not CA_CERT.exists():
        flash("The CA is not set up yet - run ./setup_ca.sh first.")
    with get_db() as db:
        rows = db.execute("SELECT * FROM enrollments ORDER BY id DESC").fetchall()
        try:
            legacy = db.execute(
                "SELECT company, ip, created_at FROM clients ORDER BY id").fetchall()
        except sqlite3.OperationalError:
            legacy = []
    enrollments = [
        dict(r, state=state_of(r),
             expires=stamp(datetime.fromisoformat(r["expires_at"])))
        for r in rows]
    return render_template(
        "dashboard.html", enrollments=enrollments, legacy=legacy,
        fingerprint=ca_fingerprint() if CA_CERT.exists() else None)


def show_code_once(enrollment_id, code):
    # The code itself is never stored; the message page shows it this once.
    session["new_code"] = {"id": enrollment_id, "code": code}
    return redirect(url_for("enrollment_page", enrollment_id=enrollment_id))


@app.route("/enrollments", methods=["POST"])
@login_required
def add_enrollment():
    company = " ".join(request.form.get("company", "").split())
    domain = request.form.get("domain", "").strip().lower().rstrip(".")
    ip = request.form.get("ip", "").strip()
    email = request.form.get("email", "").strip()
    details = request.form.get("details", "").strip()

    if not company:
        flash("Company name is required.")
        return redirect(url_for("dashboard"))
    if not DOMAIN_RE.match(domain):
        flash(f"'{domain}' is not a valid domain name (e.g. social.lab).")
        return redirect(url_for("dashboard"))
    try:
        ipaddress.ip_address(ip)
    except ValueError:
        flash(f"'{ip}' is not a valid IP address.")
        return redirect(url_for("dashboard"))
    if not CA_CERT.exists():
        flash("The CA is not set up yet - run ./setup_ca.sh first.")
        return redirect(url_for("dashboard"))

    with get_db() as db:
        taken = db.execute(
            "SELECT 1 FROM enrollments WHERE domain = ? AND status != 'cancelled'",
            (domain,)).fetchone()
    if taken:
        flash(f"{domain} is already registered - use New code on its row to enroll again.")
        return redirect(url_for("dashboard"))

    code, code_hash, expires = new_code()
    with get_db() as db:
        cur = db.execute(
            "INSERT INTO enrollments (company, email, domain, ip, details, "
            "code_hash, expires_at, status, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, 'waiting', ?)",
            (company, email, domain, ip, details, code_hash, expires,
             stamp(utcnow())))
    return show_code_once(cur.lastrowid, code)


@app.route("/enrollments/<int:enrollment_id>")
@login_required
def enrollment_page(enrollment_id):
    e = enrollment_or_404(enrollment_id)
    fresh = session.pop("new_code", None)
    code = fresh["code"] if fresh and fresh["id"] == enrollment_id else None
    state = state_of(e)
    message = enrollment_message(e, code) if state == "waiting" else None
    return render_template("enrollment.html", e=e, state=state, code=code,
                           message=message)


@app.route("/enrollments/<int:enrollment_id>/new-code", methods=["POST"])
@login_required
def renew_code(enrollment_id):
    e = enrollment_or_404(enrollment_id)
    with get_db() as db:
        clash = db.execute(
            "SELECT 1 FROM enrollments WHERE domain = ? AND id != ? "
            "AND status != 'cancelled'", (e["domain"], enrollment_id)).fetchone()
    if clash:
        flash(f"{e['domain']} has another active registration - use that one.")
        return redirect(url_for("dashboard"))
    code, code_hash, expires = new_code()
    with get_db() as db:
        db.execute(
            "UPDATE enrollments SET code_hash = ?, expires_at = ?, "
            "status = 'waiting' WHERE id = ?",
            (code_hash, expires, enrollment_id))
    return show_code_once(enrollment_id, code)


@app.route("/enrollments/<int:enrollment_id>/cancel", methods=["POST"])
@login_required
def cancel_enrollment(enrollment_id):
    with get_db() as db:
        db.execute(
            "UPDATE enrollments SET status = 'cancelled' "
            "WHERE id = ? AND status = 'waiting'", (enrollment_id,))
    flash("Enrollment code cancelled.")
    return redirect(url_for("dashboard"))


@app.route("/enrollments/<int:enrollment_id>/certificate")
@login_required
def enrollment_certificate(enrollment_id):
    e = enrollment_or_404(enrollment_id)
    path = ENROLL_DIR / str(enrollment_id) / "cert.pem"
    if not e["serial"] or not path.exists():
        abort(404)
    return send_file(path, as_attachment=True,
                     download_name=f"{e['domain']}.pem")


# ---------------------------------------------------------------- enrollment API

@app.route("/enroll.sh")
def enroll_script():
    # Public on purpose: the same readable script for every company; the
    # secret is the one-time code it asks for.
    return send_file(ENROLL_SCRIPT, mimetype="text/plain")


@app.route("/enroll/check", methods=["POST"])
def enroll_check():
    e, error = enrollment_for_code(request.form.get("code", ""))
    if error is None:
        error = requester_problem(e)
    if error:
        return plain(error, 403)
    expires = stamp(datetime.fromisoformat(e["expires_at"]))
    return plain(f"company={e['company']}\ndomain={e['domain']}\n"
                 f"ip={e['ip']}\nexpires={expires}")


@app.route("/enroll", methods=["POST"])
def enroll():
    e, error = enrollment_for_code(request.form.get("code", ""))
    if error is None:
        error = requester_problem(e)
    if error:
        return plain(error, 403)
    csr = request.form.get("csr", "")
    if "-----BEGIN CERTIFICATE REQUEST-----" not in csr or len(csr) > 20_000:
        return plain("No certificate request (CSR) was received.", 400)

    # Claim the code before signing, so two requests can't both use it.
    with get_db() as db:
        claimed = db.execute(
            "UPDATE enrollments SET status = 'signing' "
            "WHERE id = ? AND status = 'waiting'", (e["id"],)).rowcount
    if not claimed:
        return plain("This enrollment code is being used right now.", 409)
    try:
        cert_pem, serial = sign_request(e, csr)
    except (RuntimeError, ValueError) as exc:
        with get_db() as db:
            db.execute("UPDATE enrollments SET status = 'waiting' WHERE id = ?",
                       (e["id"],))
        return plain(f"The CA refused the request: {exc}", 400)
    with get_db() as db:
        db.execute(
            "UPDATE enrollments SET status = 'issued', used_at = ?, "
            "used_from = ?, serial = ? WHERE id = ?",
            (stamp(utcnow()), request.remote_addr, serial, e["id"]))
    return plain(cert_pem)


@app.route("/ca-certificate")
def ca_certificate():
    # Public on purpose: anyone may fetch the CA certificate to trust the CA.
    if not CA_CERT.exists():
        abort(404)
    return send_file(CA_CERT, as_attachment=True, download_name="cacert.pem")


def http_front(https_ready):
    """Port 80 takes plain HTTP from anyone, but only to send the visitor on
    to https://SITE_DOMAIN - it never serves the portal itself."""
    @Request.application
    def front(req):
        if not https_ready:
            return Response(
                f"The CA portal only runs over HTTPS at https://{SITE_DOMAIN},\n"
                "which isn't set up yet.\n", status=503, mimetype="text/plain")
        target = f"https://{SITE_DOMAIN}{req.path}"
        if req.query_string:
            target += "?" + req.query_string.decode()
        return redirect(target, code=301)

    return make_server("0.0.0.0", 80, front)


init_db()

if __name__ == "__main__":
    if SERVER_CERT.exists() and SERVER_KEY.exists():
        print(f" * HTTPS on port 443 as {SITE_DOMAIN} only; port 80 redirects there")
        # Debug mode runs this file twice (reloader parent + serving child);
        # only the serving child may bind port 80.
        if os.environ.get("WERKZEUG_RUN_MAIN") == "true":
            front = http_front(https_ready=True)
            threading.Thread(target=front.serve_forever, daemon=True).start()
        app.run(host="0.0.0.0", port=443, debug=True,
                ssl_context=(str(SERVER_CERT), str(SERVER_KEY)))
    else:
        print(" * No certificate - the portal stays closed until "
              "./make_server_cert.sh is run and ca is restarted", flush=True)
        http_front(https_ready=False).serve_forever()
