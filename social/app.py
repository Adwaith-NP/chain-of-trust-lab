"""Social Lab - a small photo-sharing site.

People log in, post photos with a caption, and like and comment on each
other's posts. Run ./install.sh once to create the database and the admin
account; until then every page says the server isn't installed.

The app listens on 127.0.0.1:8000 only. Apache (apache/) is the web server
in front of it: it does HTTPS for each site name and passes requests here.
"""

import os
import re
import secrets
import sqlite3
from datetime import datetime, timezone
from functools import wraps
from pathlib import Path

from flask import (Flask, abort, flash, g, redirect, render_template, request,
                   send_from_directory, session, url_for)
from werkzeug.security import check_password_hash, generate_password_hash

BASE_DIR = Path(__file__).resolve().parent
DB_PATH = BASE_DIR / "social.db"
UPLOAD_DIR = BASE_DIR / "uploads"

# The only names this site answers to; requests for its IP, localhost or
# any other name are refused (Apache refuses them first).
SITE_DOMAINS = os.environ.get(
    "SITE_DOMAINS", "social.lab seedpkilab2020.com").lower().split()

# Same lab login as the CA and DNS portals.
ADMIN_USER = os.environ.get("SOCIAL_ADMIN_USER", "admin").lower()
ADMIN_PASSWORD = os.environ.get("SOCIAL_ADMIN_PASSWORD", "admin123")

app = Flask(__name__)
app.secret_key = os.environ.get("SOCIAL_SECRET_KEY", "social-lab-dev-secret")
app.config["MAX_CONTENT_LENGTH"] = 8 * 1024 * 1024
app.config["SESSION_COOKIE_SECURE"] = True

USERNAME_RE = re.compile(r"^[a-z0-9_]{3,20}$")

# The stored file's extension comes from these signatures, never from the
# uploaded file name, so nothing but real images is ever served back.
IMAGE_SIGNATURES = [
    (b"\xff\xd8\xff", "jpg"),
    (b"\x89PNG\r\n\x1a\n", "png"),
    (b"GIF87a", "gif"),
    (b"GIF89a", "gif"),
]


def image_type(head):
    for signature, ext in IMAGE_SIGNATURES:
        if head.startswith(signature):
            return ext
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "webp"
    return None


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


# ---------------------------------------------------------------- database

def connect():
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys = ON")
    return db


def get_db():
    if "db" not in g:
        g.db = connect()
    return g.db


@app.teardown_appcontext
def close_db(exc):
    db = g.pop("db", None)
    if db is not None:
        db.close()


def init_db():
    db = connect()
    db.executescript("""
        CREATE TABLE IF NOT EXISTS users (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            username      TEXT NOT NULL UNIQUE,
            password_hash TEXT NOT NULL,
            created_at    TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS posts (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id    INTEGER NOT NULL REFERENCES users(id),
            filename   TEXT NOT NULL,
            caption    TEXT,
            created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS likes (
            user_id INTEGER NOT NULL REFERENCES users(id),
            post_id INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
            PRIMARY KEY (user_id, post_id)
        );
        CREATE TABLE IF NOT EXISTS comments (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            post_id    INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
            user_id    INTEGER NOT NULL REFERENCES users(id),
            body       TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
    """)
    db.close()


def create_user(username, password):
    """Returns False when the username is already taken."""
    db = connect()
    try:
        db.execute(
            "INSERT INTO users (username, password_hash, created_at) "
            "VALUES (?, ?, ?)",
            (username.lower(), generate_password_hash(password), now()))
        db.commit()
        return True
    except sqlite3.IntegrityError:
        return False
    finally:
        db.close()


@app.before_request
def only_own_domain():
    if request.host.split(":")[0].lower() not in SITE_DOMAINS:
        names = " or ".join(f"https://{d}" for d in SITE_DOMAINS)
        return (f"This server only answers as {names}\n", 421,
                {"Content-Type": "text/plain; charset=utf-8"})


@app.before_request
def require_install():
    if not DB_PATH.exists():
        return render_template("not_installed.html"), 503


@app.after_request
def no_sniff(response):
    response.headers["X-Content-Type-Options"] = "nosniff"
    return response


# ---------------------------------------------------------------- auth

def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if "user_id" not in session:
            return redirect(url_for("login"))
        g.user = get_db().execute(
            "SELECT id, username FROM users WHERE id = ?",
            (session["user_id"],)).fetchone()
        if g.user is None:  # account gone, e.g. after a database reset
            session.clear()
            return redirect(url_for("login"))
        return view(*args, **kwargs)
    return wrapped


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        user = get_db().execute(
            "SELECT * FROM users WHERE username = ?",
            (request.form.get("username", "").strip().lower(),)).fetchone()
        if user and check_password_hash(user["password_hash"],
                                        request.form.get("password", "")):
            session.clear()
            session["user_id"] = user["id"]
            return redirect(url_for("feed"))
        flash("Wrong username or password.")
    return render_template("login.html")


@app.route("/signup", methods=["GET", "POST"])
def signup():
    if request.method == "POST":
        username = request.form.get("username", "").strip().lower()
        password = request.form.get("password", "")
        if not USERNAME_RE.match(username):
            flash("Username: 3-20 characters - lowercase letters, digits or _.")
        elif len(password) < 6:
            flash("Password must be at least 6 characters.")
        elif not create_user(username, password):
            flash(f"The username {username} is taken.")
        else:
            flash("Account created - log in.")
            return redirect(url_for("login"))
    return render_template("signup.html")


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# ---------------------------------------------------------------- feed

@app.route("/")
@login_required
def feed():
    db = get_db()
    posts = db.execute("""
        SELECT p.id, p.user_id, p.filename, p.caption, p.created_at, u.username,
               (SELECT COUNT(*) FROM likes l WHERE l.post_id = p.id) AS like_count,
               EXISTS (SELECT 1 FROM likes l
                       WHERE l.post_id = p.id AND l.user_id = ?) AS liked
        FROM posts p JOIN users u ON u.id = p.user_id
        ORDER BY p.id DESC
        LIMIT 50
    """, (g.user["id"],)).fetchall()

    comments = {}
    if posts:
        ids = [p["id"] for p in posts]
        rows = db.execute(f"""
            SELECT c.post_id, c.body, u.username
            FROM comments c JOIN users u ON u.id = c.user_id
            WHERE c.post_id IN ({",".join("?" * len(ids))})
            ORDER BY c.id
        """, ids).fetchall()
        for row in rows:
            comments.setdefault(row["post_id"], []).append(row)

    return render_template("feed.html", posts=posts, comments=comments,
                           admin_user=ADMIN_USER)


def post_or_404(post_id):
    post = get_db().execute(
        "SELECT * FROM posts WHERE id = ?", (post_id,)).fetchone()
    if post is None:
        abort(404)
    return post


def back_to(post_id):
    return redirect(url_for("feed", _anchor=f"post-{post_id}"))


@app.route("/posts", methods=["POST"])
@login_required
def create_post():
    photo = request.files.get("photo")
    if not photo or not photo.filename:
        flash("Choose a photo to share.")
        return redirect(url_for("feed"))
    data = photo.read()
    ext = image_type(data[:12])
    if ext is None:
        flash("That file isn't a JPEG, PNG, GIF or WebP image.")
        return redirect(url_for("feed"))

    UPLOAD_DIR.mkdir(exist_ok=True)
    filename = f"{secrets.token_hex(12)}.{ext}"
    (UPLOAD_DIR / filename).write_bytes(data)
    db = get_db()
    db.execute(
        "INSERT INTO posts (user_id, filename, caption, created_at) "
        "VALUES (?, ?, ?, ?)",
        (g.user["id"], filename,
         request.form.get("caption", "").strip()[:500], now()))
    db.commit()
    return redirect(url_for("feed"))


@app.errorhandler(413)
def too_large(error):
    flash("That photo is too big - the limit is 8 MB.")
    return redirect(url_for("feed"))


@app.route("/posts/<int:post_id>/like", methods=["POST"])
@login_required
def toggle_like(post_id):
    post_or_404(post_id)
    db = get_db()
    removed = db.execute(
        "DELETE FROM likes WHERE user_id = ? AND post_id = ?",
        (g.user["id"], post_id)).rowcount
    if not removed:
        db.execute("INSERT INTO likes (user_id, post_id) VALUES (?, ?)",
                   (g.user["id"], post_id))
    db.commit()
    return back_to(post_id)


@app.route("/posts/<int:post_id>/comments", methods=["POST"])
@login_required
def add_comment(post_id):
    post_or_404(post_id)
    body = request.form.get("body", "").strip()[:500]
    if body:
        db = get_db()
        db.execute(
            "INSERT INTO comments (post_id, user_id, body, created_at) "
            "VALUES (?, ?, ?, ?)", (post_id, g.user["id"], body, now()))
        db.commit()
    return back_to(post_id)


@app.route("/posts/<int:post_id>/delete", methods=["POST"])
@login_required
def delete_post(post_id):
    post = post_or_404(post_id)
    if post["user_id"] != g.user["id"] and g.user["username"] != ADMIN_USER:
        abort(403)
    db = get_db()
    db.execute("DELETE FROM posts WHERE id = ?", (post_id,))
    db.commit()
    (UPLOAD_DIR / post["filename"]).unlink(missing_ok=True)
    return redirect(url_for("feed"))


@app.route("/uploads/<name>")
@login_required
def uploaded(name):
    return send_from_directory(UPLOAD_DIR, name)


# ---------------------------------------------------------------- serving

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8000)
