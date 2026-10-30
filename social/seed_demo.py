"""Demo content for Social Lab: members, photos, likes and comments.

Run it once after install.sh (it is offered there), on the host or in the
container - it only needs Python's standard library. The demo photos are
drawn procedurally and written to uploads/ as real PNGs, so they pass the
app's image-signature check like any other upload.

Members created (password is the name + 123): alice, bob, carol, dave.
Running it again does nothing once the members exist.
"""

import hashlib
import math
import secrets
import sqlite3
import struct
import zlib
from datetime import datetime, timedelta, timezone
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
DB_PATH = BASE_DIR / "social.db"
UPLOAD_DIR = BASE_DIR / "uploads"

DEMO_USERS = ["alice", "bob", "carol", "dave"]

W, H = 640, 420


def hash_password(password):
    """A pbkdf2 hash in the format werkzeug's check_password_hash accepts."""
    salt = secrets.token_hex(8)
    digest = hashlib.pbkdf2_hmac(
        "sha256", password.encode(), salt.encode(), 600_000)
    return f"pbkdf2:sha256:600000${salt}${digest.hex()}"


# ------------------------------------------------------------- PNG writing

def write_png(path, pixel):
    """Write a W x H RGB PNG; pixel(x, y) returns (r, g, b)."""
    raw = bytearray()
    for y in range(H):
        raw.append(0)  # no scanline filter
        for x in range(W):
            r, g, b = pixel(x, y)
            raw += bytes((max(0, min(255, int(r))),
                          max(0, min(255, int(g))),
                          max(0, min(255, int(b)))))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data)))

    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
        + chunk(b"IEND", b""))


def lerp(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


# ------------------------------------------------------------- the scenes

def sunset(x, y):
    """Orange-to-purple sky, a low sun, a mountain ridge."""
    sky = lerp((253, 200, 48), (129, 52, 175), y / H)
    dx, dy = x - W * 0.62, y - H * 0.52
    if dx * dx + dy * dy < 48 * 48:
        sky = lerp(sky, (255, 244, 214), 0.9)
    ridge = H * 0.72 + 34 * math.sin(x / 53) + 18 * math.sin(x / 17 + 2)
    if y > ridge:
        shade = 36 + 26 * (y - ridge) / (H - ridge)
        return (shade * 0.9, shade * 0.62, shade)
    return sky


def ocean(x, y):
    """Blue sky over a wavy sea with a sun glint."""
    horizon = H * 0.45
    if y < horizon:
        return lerp((176, 224, 255), (64, 150, 238), y / horizon)
    t = (y - horizon) / (H - horizon)
    sea = lerp((50, 140, 200), (10, 55, 110), t)
    wave = math.sin(x / 14 + y / 5) + math.sin(x / 31 - y / 7)
    sea = lerp(sea, (235, 245, 255), 0.12 * max(0.0, wave - 1.2))
    if abs(x - W * 0.5) < 60 * (1 - t) and (x + y) % 7 < 2:
        sea = lerp(sea, (255, 240, 200), 0.5)
    return sea


def forest(x, y):
    """Layered green hills in morning mist."""
    color = lerp((225, 240, 230), (190, 220, 205), y / H)
    for i, (speed, base, tone) in enumerate(
            [(97, 0.42, (150, 190, 160)), (61, 0.58, (95, 150, 110)),
             (37, 0.74, (45, 100, 65))]):
        ridge = H * base + 26 * math.sin(x / speed + i * 2.1)
        if y > ridge:
            color = lerp(tone, (20, 60, 35), (y - ridge) / H)
    return color


def city(x, y):
    """A night skyline with lit windows."""
    sky = lerp((24, 28, 66), (8, 8, 22), y / H)
    block = x // 64
    height = H * (0.38 + 0.3 * (hash(("b", block)) % 100) / 100)
    if y > height:
        wx, wy = (x % 64) // 10, (y - int(height)) // 14
        lit = hash((block, wx, wy)) % 10 < 4
        if 2 < x % 64 < 60 and (x % 10) in (4, 5) and (y - int(height)) % 14 < 7 and lit:
            return (255, 214, 120)
        return (16, 16, 30)
    dx, dy = x - W * 0.2, (y - H * 0.16) * 1.4
    if dx * dx + dy * dy < 26 * 26:
        return (240, 238, 225)
    return sky


def aurora(x, y):
    """Northern lights and stars."""
    sky = lerp((6, 10, 30), (2, 4, 14), y / H)
    band = H * 0.4 + 56 * math.sin(x / 83) + 24 * math.sin(x / 29 + 1.4)
    glow = max(0.0, 1 - abs(y - band) / 95)
    color = lerp(sky, (60, 230, 150), glow * glow * 0.9)
    if glow < 0.3 and hash(("s", x, y)) % 1400 == 0:
        return (235, 235, 245)
    return color


def latte(x, y):
    """Looking down at a latte on a wooden table."""
    stripe = 12 * math.sin(x / 41) + y
    wood = lerp((126, 82, 48), (104, 64, 36), (int(stripe) % 48) / 48)
    dx, dy = x - W * 0.5, y - H * 0.5
    d = math.hypot(dx, dy)
    if d < 150:
        if d > 132:
            return (238, 236, 232)  # the cup's rim
        swirl = d / 24 + math.atan2(dy, dx) * 1.6
        return lerp((196, 142, 90), (242, 226, 206),
                    0.5 + 0.5 * math.sin(swirl))
    return wood


# (username, scene, caption, hours ago)
DEMO_POSTS = [
    ("alice", sunset, "Golden hour from the ridge 🌄", 50),
    ("bob", ocean, "Salt air and no deadlines 🌊", 44),
    ("carol", forest, "Morning mist on the trail", 31),
    ("dave", city, "The lab never sleeps and neither does this city 🌃", 26),
    ("alice", aurora, "Caught the lights last night! 💚", 9),
    ("carol", latte, "Debugging fuel ☕", 3),
]

DEMO_LIKES = {0: ["bob", "carol", "dave"], 1: ["alice", "carol"],
              2: ["alice", "bob", "dave"], 3: ["alice"],
              4: ["bob", "carol", "dave", "admin"], 5: ["alice", "dave"]}

DEMO_COMMENTS = [
    (0, "bob", "Unreal colours - where is this?"),
    (0, "carol", "Wallpaper material 😍"),
    (1, "alice", "Take me with you next time!"),
    (2, "dave", "That mist though."),
    (4, "bob", "Still jealous. Incredible shot."),
    (4, "carol", "Okay this wins the feed."),
    (5, "alice", "A heart would've been showing off, fair."),
]


def stamp(hours_ago):
    t = datetime.now(timezone.utc) - timedelta(hours=hours_ago)
    return t.strftime("%Y-%m-%d %H:%M UTC")


def main():
    if not DB_PATH.exists():
        raise SystemExit("social.db not found - run ./install.sh first.")
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys = ON")

    existing = {r["username"] for r in db.execute("SELECT username FROM users")}
    if existing & set(DEMO_USERS):
        print("Demo members already exist - nothing to do.")
        return

    print("Creating demo members:", ", ".join(DEMO_USERS))
    users = {}
    for name in DEMO_USERS:
        cur = db.execute(
            "INSERT INTO users (username, password_hash, created_at) "
            "VALUES (?, ?, ?)",
            (name, hash_password(name + "123"), stamp(72)))
        users[name] = cur.lastrowid
    for row in db.execute("SELECT id, username FROM users"):
        users.setdefault(row["username"], row["id"])

    UPLOAD_DIR.mkdir(exist_ok=True)
    post_ids = []
    for name, scene, caption, hours_ago in DEMO_POSTS:
        filename = f"{secrets.token_hex(12)}.png"
        print(f"  drawing {scene.__name__:>7} for {name} -> uploads/{filename}")
        write_png(UPLOAD_DIR / filename, scene)
        cur = db.execute(
            "INSERT INTO posts (user_id, filename, caption, created_at) "
            "VALUES (?, ?, ?, ?)",
            (users[name], filename, caption, stamp(hours_ago)))
        post_ids.append(cur.lastrowid)

    for index, names in DEMO_LIKES.items():
        for name in names:
            if name in users:
                db.execute(
                    "INSERT OR IGNORE INTO likes (user_id, post_id) "
                    "VALUES (?, ?)", (users[name], post_ids[index]))

    for index, name, body in DEMO_COMMENTS:
        db.execute(
            "INSERT INTO comments (post_id, user_id, body, created_at) "
            "VALUES (?, ?, ?, ?)",
            (post_ids[index], users[name], body,
             stamp(max(0, DEMO_POSTS[index][3] - 1))))

    db.commit()
    db.close()
    print(f"Done: {len(DEMO_POSTS)} photos, likes and comments are in. "
          f"Log in as alice / alice123 (or admin / admin123).")


if __name__ == "__main__":
    main()
