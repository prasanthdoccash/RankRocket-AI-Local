import datetime
import json
import hmac
import html
import os
import secrets
import sqlite3
import time
from functools import wraps

from flask import (
    Flask,
    g,
    jsonify,
    redirect,
    render_template_string,
    request,
    session,
    url_for,
)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
TRIAL_DAYS = int(os.environ.get("LICENSE_TRIAL_DAYS", "30"))
CURRENT_APP_VERSION = os.environ.get("LICENSE_CURRENT_APP_VERSION", "1.1.0")
RELEASE_TOKEN = os.environ.get("LICENSE_RELEASE_TOKEN")
GOOGLE_PLAY_PACKAGE_NAME = os.environ.get(
    "GOOGLE_PLAY_PACKAGE_NAME", "com.portableai.portable_ai_flutter"
)
GOOGLE_PLAY_SERVICE_ACCOUNT_JSON = os.environ.get("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON")
GOOGLE_PLAY_PRODUCT_DAYS = {
    "rankrocket_monthly": 30,
    "rankrocket_annual": 365,
}

app = Flask(__name__)
app.secret_key = os.environ.get("LICENSE_SECRET_KEY") or secrets.token_hex(16)
app.config["DB_PATH"] = os.environ.get(
    "LICENSE_DB", os.path.join(BASE_DIR, "license.db")
)

_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O/1/I


def init_db():
    conn = sqlite3.connect(app.config["DB_PATH"])
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS devices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            device_id TEXT UNIQUE NOT NULL,
            device_code TEXT UNIQUE NOT NULL,
            platform TEXT,
            model TEXT,
            os_version TEXT,
            app_version TEXT,
            first_seen TEXT,
            last_seen TEXT,
            trial_started_at TEXT,
            trial_used INTEGER DEFAULT 0,
            license_expires_at TEXT,
            notes TEXT
        );
        CREATE TABLE IF NOT EXISTS licenses (
             id INTEGER PRIMARY KEY AUTOINCREMENT,
             license_key TEXT UNIQUE NOT NULL,
             device_id TEXT,
             issued_at TEXT,
             expires_at TEXT,
             duration_days INTEGER,
             notes TEXT
         );
         CREATE TABLE IF NOT EXISTS           google_play_purchases (
             id INTEGER PRIMARY KEY AUTOINCREMENT,
             purchase_token TEXT UNIQUE NOT NULL,
             device_id TEXT NOT NULL,
             product_id TEXT NOT NULL,
             verified_at TEXT NOT NULL,
             order_id TEXT
         );
         CREATE TABLE IF NOT EXISTS releases (
             id INTEGER PRIMARY KEY AUTOINCREMENT,
             version TEXT NOT NULL,
             build_number TEXT NOT NULL,
             platform TEXT NOT NULL,
             commit_hash TEXT,
             workflow_run TEXT,
             created_at TEXT NOT NULL,
             UNIQUE(version, build_number, platform)
         );
        """
    )
    conn.commit()
    latest = conn.execute("SELECT version FROM releases ORDER BY id DESC LIMIT 1").fetchone()
    if latest:
        global CURRENT_APP_VERSION
        CURRENT_APP_VERSION = latest[0]
    conn.close()


def get_db():
    db = getattr(g, "_db", None)
    if db is None:
        db = g._db = sqlite3.connect(app.config["DB_PATH"])
        db.row_factory = sqlite3.Row
    return db


@app.teardown_appcontext
def _close_db(_exc):
    db = getattr(g, "_db", None)
    if db is not None:
        db.close()


def _now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def _parse_iso(value):
    return datetime.datetime.fromisoformat(value)


def _make_device_code():
    return "".join(secrets.choice(_ALPHABET) for _ in range(8))


def _device_state(dev, now=None):
    """Return (status, expires_at_iso_or_None, days_left)."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    if dev["license_expires_at"]:
        exp = _parse_iso(dev["license_expires_at"])
        if exp > now:
            return "active", exp.isoformat(), (exp - now).days
        return "expired", None, 0
    if dev["trial_started_at"]:
        trial_end = _parse_iso(dev["trial_started_at"]) + datetime.timedelta(
            days=TRIAL_DAYS
        )
        if trial_end > now:
            return "trial", trial_end.isoformat(), (trial_end - now).days
        return "expired", None, 0
    return "needs_license", None, 0


def _payload(dev):
    status, exp, days = _device_state(dev)
    return jsonify(
        {
            "status": status,
            "device_code": dev["device_code"],
            "expires_at": exp,
            "days_left": days,
            "message": "",
        }
    )


@app.route("/api/v1/register", methods=["POST"])
def register():
    data = request.get_json(silent=True) or {}
    device_id = (data.get("device_id") or "").strip()
    if not device_id:
        return jsonify({"error": "device_id required"}), 400

    db = get_db()
    dev = db.execute(
        "SELECT * FROM devices WHERE device_id = ?", (device_id,)
    ).fetchone()

    if dev is None:
        now = _now_iso()
        db.execute(
            """INSERT INTO devices
               (device_id, device_code, platform, model, os_version,
                app_version, first_seen, last_seen, trial_started_at, trial_used,
                license_expires_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, NULL)""",
            (
                device_id,
                _make_device_code(),
                data.get("platform"),
                data.get("model"),
                data.get("os_version"),
                data.get("app_version"),
                now,
                now,
                now,
            ),
        )
        db.commit()
        dev = db.execute(
            "SELECT * FROM devices WHERE device_id = ?", (device_id,)
        ).fetchone()
    else:
        db.execute(
            """UPDATE devices
               SET last_seen = ?, app_version = ?, model = ?, os_version = ?
               WHERE device_id = ?""",
            (
                _now_iso(),
                data.get("app_version"),
                data.get("model"),
                data.get("os_version"),
                device_id,
            ),
        )
        db.commit()

    return _payload(dev)


@app.route("/api/v1/status", methods=["GET"])
def status():
    device_id = (request.args.get("device_id") or "").strip()
    db = get_db()
    dev = db.execute(
        "SELECT * FROM devices WHERE device_id = ?", (device_id,)
    ).fetchone()
    if dev is None:
        return jsonify(
            {
                "status": "unknown",
                "device_code": None,
                "expires_at": None,
                "days_left": 0,
                "message": "",
            }
        )
    return _payload(dev)


@app.route("/api/v1/releases", methods=["POST"])
def register_release():
    if not RELEASE_TOKEN or not hmac.compare_digest(
        request.headers.get("Authorization", ""), f"Bearer {RELEASE_TOKEN}"
    ):
        return jsonify({"error": "Unauthorized"}), 401
    data = request.get_json(silent=True) or {}
    version = (data.get("version") or "").strip()
    build_number = (data.get("build_number") or "").strip()
    platform = (data.get("platform") or "").strip().lower()
    if not version or not build_number or platform not in {"android", "ios"}:
        return jsonify({"error": "version, build_number and platform are required"}), 400
    db = get_db()
    db.execute(
        """INSERT OR IGNORE INTO releases
           (version, build_number, platform, commit_hash, workflow_run, created_at)
           VALUES (?, ?, ?, ?, ?, ?)""",
        (
            version,
            build_number,
            platform,
            data.get("commit"),
            data.get("workflow_run"),
            _now_iso(),
        ),
    )
    db.commit()
    global CURRENT_APP_VERSION
    CURRENT_APP_VERSION = version
    return jsonify({"status": "recorded", "version": version, "build_number": build_number})


def _google_play_service():
    if not GOOGLE_PLAY_SERVICE_ACCOUNT_JSON:
        return None
    from google.oauth2 import service_account
    from googleapiclient.discovery import build

    info = json.loads(GOOGLE_PLAY_SERVICE_ACCOUNT_JSON)
    credentials = service_account.Credentials.from_service_account_info(
        info, scopes=["https://www.googleapis.com/auth/androidpublisher"]
    )
    return build("androidpublisher", "v3", credentials=credentials, cache_discovery=False)


def _extend_device_license(device_id, duration_days):
    db = get_db()
    dev = db.execute(
        "SELECT * FROM devices WHERE device_id = ?", (device_id,)
    ).fetchone()
    if dev is None:
        return None
    now = datetime.datetime.now(datetime.timezone.utc)
    base = now
    if dev["license_expires_at"]:
        current = _parse_iso(dev["license_expires_at"])
        if current > base:
            base = current
    expires = base + datetime.timedelta(days=duration_days)
    db.execute(
        "UPDATE devices SET license_expires_at = ? WHERE device_id = ?",
        (expires.isoformat(), device_id),
    )
    db.commit()
    return expires


@app.route("/api/v1/google-play/verify", methods=["POST"])
def verify_google_play_purchase():
    data = request.get_json(silent=True) or {}
    device_id = (data.get("device_id") or "").strip()
    product_id = (data.get("product_id") or "").strip()
    purchase_token = (data.get("purchase_token") or "").strip()
    if not device_id or not product_id or not purchase_token:
        return jsonify({"error": "device_id, product_id and purchase_token required"}), 400
    duration_days = GOOGLE_PLAY_PRODUCT_DAYS.get(product_id)
    if duration_days is None:
        return jsonify({"error": "Unknown Google Play product"}), 400
    service = _google_play_service()
    if service is None:
        return jsonify({"error": "Google Play verification is not configured"}), 503
    db = get_db()
    existing = db.execute(
        "SELECT * FROM google_play_purchases WHERE purchase_token = ?",
        (purchase_token,),
    ).fetchone()
    if existing is not None:
        if existing["device_id"] != device_id or existing["product_id"] != product_id:
            return jsonify({"error": "Purchase token is bound to another device or product"}), 409
        return _payload(db.execute(
            "SELECT * FROM devices WHERE device_id = ?", (device_id,)
        ).fetchone())
    try:
        response = service.purchases().subscriptionsv2().get(
            packageName=GOOGLE_PLAY_PACKAGE_NAME,
            token=purchase_token,
        ).execute()
        if response.get("subscriptionState") not in {
            "SUBSCRIPTION_STATE_ACTIVE",
            "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
        }:
            return jsonify({"error": "Google Play subscription is not active"}), 402
        line_items = response.get("lineItems") or []
        item = next(
            (entry for entry in line_items if entry.get("productId") == product_id),
            None,
        )
        if item is None or not item.get("expiryTime"):
            return jsonify({"error": "Google Play product or expiry not found"}), 402
        service.purchases().subscriptions().acknowledge(
            packageName=GOOGLE_PLAY_PACKAGE_NAME,
            subscriptionId=product_id,
            token=purchase_token,
            body={},
        ).execute()
    except Exception:
        return jsonify({"error": "Google Play purchase verification failed"}), 502
    db.execute(
        "INSERT INTO google_play_purchases (purchase_token, device_id, product_id, verified_at, order_id) VALUES (?, ?, ?, ?, ?)",
        (purchase_token, device_id, product_id, _now_iso(), response.get("latestOrderId")),
    )
    expires = _extend_device_license(device_id, duration_days)
    if expires is None:
        return jsonify({"error": "Unknown device"}), 404
    return _payload(db.execute(
        "SELECT * FROM devices WHERE device_id = ?", (device_id,)
    ).fetchone())


_activate_hits = {}


def _make_license_key():
    return "RR-" + "-".join(
        "".join(secrets.choice(_ALPHABET) for _ in range(4)) for _ in range(3)
    )


def _throttled(ip, limit=10, window=60):
    now = time.time()
    hits = [t for t in _activate_hits.get(ip, []) if now - t < window]
    if len(hits) >= limit:
        _activate_hits[ip] = hits
        return True
    hits.append(now)
    _activate_hits[ip] = hits
    return False


@app.route("/api/v1/activate", methods=["POST"])
def activate():
    if _throttled(request.remote_addr or "local"):
        return jsonify({"error": "Too many attempts. Try again later."}), 429

    data = request.get_json(silent=True) or {}
    device_id = (data.get("device_id") or "").strip()
    key = (data.get("license_key") or "").strip().upper()
    if not device_id or not key:
        return jsonify({"error": "device_id and license_key required"}), 400

    db = get_db()
    lic = db.execute(
        "SELECT * FROM licenses WHERE license_key = ?", (key,)
    ).fetchone()
    if lic is None:
        return jsonify({"error": "Invalid license key"}), 404
    if lic["device_id"] and lic["device_id"] != device_id:
        return jsonify(
            {"error": "This license key is already used on another device"}
        ), 403

    now = datetime.datetime.now(datetime.timezone.utc)
    dev = db.execute(
        "SELECT * FROM devices WHERE device_id = ?", (device_id,)
    ).fetchone()
    if dev is None:
        db.execute(
            """INSERT INTO devices
               (device_id, device_code, first_seen, last_seen, trial_used,
                license_expires_at)
               VALUES (?, ?, ?, ?, 0, NULL)""",
            (device_id, _make_device_code(), _now_iso(), _now_iso()),
        )
        db.commit()
        dev = db.execute(
            "SELECT * FROM devices WHERE device_id = ?", (device_id,)
        ).fetchone()

    base = now
    if dev["license_expires_at"]:
        base = max(base, _parse_iso(dev["license_expires_at"]))
    if dev["trial_started_at"]:
        base = max(
            base,
            _parse_iso(dev["trial_started_at"]) + datetime.timedelta(days=TRIAL_DAYS),
        )
    exp = base + datetime.timedelta(days=lic["duration_days"])
    db.execute(
        "UPDATE licenses SET device_id = ? WHERE license_key = ?", (device_id, key)
    )
    db.execute(
        "UPDATE devices SET license_expires_at = ? WHERE device_id = ?",
        (exp.isoformat(), device_id),
    )
    db.commit()

    return jsonify(
        {
            "status": "active",
            "device_code": dev["device_code"],
            "expires_at": exp.isoformat(),
            "days_left": max(0, (exp - now).days),
        }
    )


ADMIN_PASSWORD = os.environ.get("LICENSE_ADMIN_PASSWORD", "change-me")

_PAGE = """<!doctype html><html><head><meta charset="utf-8">
<title>RankRocket AI Licenses</title>
<style>
 body{font-family:system-ui,Segoe UI,Arial;background:#0e1420;color:#e6ebf2;margin:0}
 a{color:#48cae4}
 .wrap{max-width:1100px;margin:0 auto;padding:20px}
 h1{font-size:22px} table{width:100%;border-collapse:collapse;font-size:13px}
 th,td{padding:8px 10px;border-bottom:1px solid #26324a;text-align:left}
 th{color:#90e0ef;text-transform:uppercase;font-size:11px;letter-spacing:.5px}
 .ok{color:#52e0a4}.warn{color:#ffb454}.bad{color:#ff6b6b}
 input,button{padding:8px 10px;border-radius:6px;border:1px solid #26324a;background:#141b2d;color:#e6ebf2;margin:2px}
 button{background:#0077b6;border:none;cursor:pointer}
 form{display:inline}.key{font-family:monospace;font-size:16px;letter-spacing:1px;color:#52e0a4}
 .box{background:#141b2d;border:1px solid #26324a;border-radius:12px;padding:16px;margin:16px 0}
 .msg{color:#52e0a4}.err{color:#ff6b6b}
</style></head><body><div class="wrap">
<h1>RankRocket AI &mdash; License Admin</h1>
{{ extra|safe }}
</div></body></html>"""


def login_required(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not session.get("admin"):
            return redirect(url_for("admin_login"))
        return f(*args, **kwargs)

    return wrapper


_login_hits = {}


def _login_throttled(ip, limit=10, window=60):
    now = time.time()
    hits = [t for t in _login_hits.get(ip, []) if now - t < window]
    if len(hits) >= limit:
        _login_hits[ip] = hits
        return True
    return False


@app.route("/admin/login", methods=["GET", "POST"])
def admin_login():
    ip = request.remote_addr or "local"
    if request.method == "POST":
        if _login_throttled(ip):
            return render_template_string(
                _PAGE,
                extra='<div class="box err">Too many attempts. Try again later.</div>',
            )
        password = (request.form.get("password") or "").encode()
        if hmac.compare_digest(password, ADMIN_PASSWORD.encode()):
            session["admin"] = True
            return redirect(url_for("admin_dashboard"))
        _login_hits.setdefault(ip, []).append(time.time())
    return render_template_string(
        _PAGE,
        extra="""<div class="box"><form method="post">
        <input type="password" name="password" placeholder="Admin password" autofocus>
        <button>Login</button></form></div>""",
    )


@app.route("/admin/logout")
def admin_logout():
    session.clear()
    return redirect(url_for("admin_login"))


def _version_status(installed):
    if not installed:
        return '<span class="warn">Unknown</span>'
    if installed == CURRENT_APP_VERSION:
        return '<span class="ok">Up to date</span>'
    return f'<span class="warn">Update available ({html.escape(CURRENT_APP_VERSION)})</span>'


def _device_status_label(dev):
    status, exp, _days = _device_state(dev)
    css = {"active": "ok", "trial": "warn", "expired": "bad", "needs_license": "bad"}.get(
        status, ""
    )
    return f'<span class="{css}">{status}</span>'


@app.route("/admin")
@login_required
def admin_dashboard():
    db = get_db()
    rows = db.execute("SELECT * FROM devices ORDER BY id DESC").fetchall()
    releases = db.execute("SELECT * FROM releases ORDER BY id DESC LIMIT 20").fetchall()
    release_rows = "".join(
        f"<tr><td>{html.escape(r['version'])}</td>"
        f"<td>{html.escape(r['build_number'])}</td>"
        f"<td>{html.escape(r['platform'])}</td>"
        f"<td>{html.escape(r['commit_hash'] or '-')}</td>"
        f"<td>{html.escape(r['created_at'])}</td></tr>"
        for r in releases
    ) or '<tr><td colspan="5">No GitHub releases recorded yet.</td></tr>'
    tbody = ""
    for d in rows:
        tbody += (
            "<tr>"
            f"<td><b>{d['device_code']}</b></td>"
            f"<td>{html.escape(d['platform'] or '-')}</td>"
            f"<td>{html.escape(d['model'] or '-')}</td>"
             f"<td>{html.escape(d['app_version'] or '-')}</td>"
             f"<td>{_version_status(d['app_version'])}</td>"
             f"<td>{_device_status_label(d)}</td>"
            f"<td>{(_device_state(d)[1]) or '-'}</td>"
            f"<td>{d['first_seen'][:10] if d['first_seen'] else '-'}</td>"
            f"<td>{d['last_seen'][:10] if d['last_seen'] else '-'}</td>"
            "<td>"
            f'<form method="post" action="/admin/device/{d["id"]}/extend" style="display:inline-block">'
            '<input type="number" name="days" placeholder="30" size="3" min="1" required> days '
            '<button>Extend</button></form>'
            f'<form method="post" action="/admin/device/{d["id"]}/revoke" style="display:inline-block">'
            '<button>Revoke</button></form>'
            f'<form method="post" action="/admin/device/{d["id"]}/reset-trial" style="display:inline-block">'
            '<button>Reset trial</button></form>'
            "</td></tr>"
        )
    return render_template_string(
        _PAGE,
        extra=f"""<div class="box"><h3>Google Play subscriptions</h3>
         <p>Android product IDs and prices:</p>
         <ul><li><b>rankrocket_monthly</b> — ₹120 / 30 days</li>
         <li><b>rankrocket_annual</b> — ₹1,000 / 365 days</li></ul>
         <p>Verified purchases extend the device license automatically. Configure
         <code>GOOGLE_PLAY_PACKAGE_NAME</code> and
         <code>GOOGLE_PLAY_SERVICE_ACCOUNT_JSON</code> on the server before accepting payments.</p>
         </div>
         <div class="box"><h3>Generate license key</h3>
        <form method="post" action="/admin/generate-key">
        <input name="device_code" placeholder="Device code (8 chars)" required>
        <input type="number" name="duration_days" value="365" min="1" required> days
        <input name="notes" placeholder="notes (e.g. payment id)">
        <button>Generate key</button></form>
                 <p>Current generated version: <b>{html.escape(CURRENT_APP_VERSION)}</b></p>
         <p><a href="/admin/logout">Logout</a></p></div>
         <table><thead><tr><th>Code</th><th>Platform</th><th>Model</th>
         <th>Installed version</th><th>Version status</th><th>Status</th><th>Expires</th><th>First seen</th>
         <th>Last seen</th><th>Actions</th></tr></thead><tbody>{tbody}</tbody></table>
         <div class="box"><h3>Release history</h3>
         <table><thead><tr><th>Version</th><th>Build</th><th>Platform</th><th>Commit</th><th>Created</th></tr></thead>
         <tbody>{release_rows}</tbody></table></div>""",
    )


@app.route("/admin/generate-key", methods=["POST"])
@login_required
def admin_generate_key():
    db = get_db()
    code = (request.form.get("device_code") or "").strip().upper()
    try:
        duration_days = int(request.form.get("duration_days") or 0)
    except ValueError:
        duration_days = 0
    notes = request.form.get("notes") or ""
    dev = db.execute(
        "SELECT * FROM devices WHERE device_code = ?", (code,)
    ).fetchone()
    if dev is None:
        return render_template_string(
            _PAGE, extra='<div class="box err">Device code not found.</div>'
        )
    if duration_days < 1:
        return render_template_string(
            _PAGE, extra='<div class="box err">Invalid duration.</div>'
        )
    key = _make_license_key()
    db.execute(
        """INSERT INTO licenses
           (license_key, device_id, issued_at, expires_at, duration_days, notes)
           VALUES (?, ?, ?, NULL, ?, ?)""",
        (key, dev["device_id"], _now_iso(), duration_days, notes),
    )
    db.commit()
    return render_template_string(
        _PAGE,
        extra=f"""<div class="box msg"><h3>License key issued for {code}</h3>
        <p class="key">{key}</p>
        <p>Email this key to the user. It activates only on device {code}.</p>
        {('<p>Notes: ' + html.escape(notes) + '</p>') if notes else ''}
        <p><a href="/admin">Back to dashboard</a></p></div>""",
    )


@app.route("/admin/device/<int:device_row_id>/extend", methods=["POST"])
@login_required
def admin_extend(device_row_id):
    db = get_db()
    dev = db.execute("SELECT * FROM devices WHERE id = ?", (device_row_id,)).fetchone()
    if dev is None:
        return "not found", 404
    try:
        days = int(request.form.get("days") or 0)
    except ValueError:
        days = 0
    if days < 1:
        return "invalid days", 400
    now = datetime.datetime.now(datetime.timezone.utc)
    base = now
    if dev["license_expires_at"]:
        base = max(base, _parse_iso(dev["license_expires_at"]))
    if dev["trial_started_at"]:
        base = max(
            base,
            _parse_iso(dev["trial_started_at"]) + datetime.timedelta(days=TRIAL_DAYS),
        )
    new_exp = base + datetime.timedelta(days=days)
    db.execute(
        "UPDATE devices SET license_expires_at = ? WHERE id = ?",
        (new_exp.isoformat(), device_row_id),
    )
    db.commit()
    return redirect(url_for("admin_dashboard"))


@app.route("/admin/device/<int:device_row_id>/revoke", methods=["POST"])
@login_required
def admin_revoke(device_row_id):
    db = get_db()
    dev = db.execute("SELECT * FROM devices WHERE id = ?", (device_row_id,)).fetchone()
    if dev is None:
        return "not found", 404
    db.execute(
        "UPDATE devices SET license_expires_at = NULL WHERE id = ?",
        (device_row_id,),
    )
    db.commit()
    return redirect(url_for("admin_dashboard"))


@app.route("/admin/device/<int:device_row_id>/reset-trial", methods=["POST"])
@login_required
def admin_reset_trial(device_row_id):
    db = get_db()
    dev = db.execute("SELECT * FROM devices WHERE id = ?", (device_row_id,)).fetchone()
    if dev is None:
        return "not found", 404
    db.execute(
        "UPDATE devices SET trial_used = 0, trial_started_at = NULL WHERE id = ?",
        (device_row_id,),
    )
    db.commit()
    return redirect(url_for("admin_dashboard"))


# Ensure the production DB exists even when started via gunicorn (import path).
init_db()


if __name__ == "__main__":
    try:
        from waitress import serve

        port = int(os.environ.get("LICENSE_PORT", "8900"))
        print(f"License server on http://0.0.0.0:{port}")
        serve(app, host="0.0.0.0", port=port)
    except ImportError:
        app.run(debug=True, port=8900)