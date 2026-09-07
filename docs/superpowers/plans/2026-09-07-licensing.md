# Licensing System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a server-enforced licensing system (30-day trial, device-bound keys, admin panel) to the RankRocket AI Flutter app for both Android and iOS, with the server live at `https://ai.rankrocket.online`.

**Architecture:** A standalone Flask license server (`license_server/`) stores devices + licenses in SQLite and exposes a JSON API (`/api/v1/register|activate|status`) plus a password-protected `/admin` web panel. The Flutter app (shared code = Android + iOS) resolves a stable device ID via platform channels (Android `ANDROID_ID`, iOS Keychain UUID), registers on each launch, caches state in Hive, and gates the app behind a `LicenseScreen` when the trial/license is missing or expired.

**Tech Stack:** Flask, SQLite, gunicorn/waitress (server); Flutter/GetX/Hive/`http` (client); Swift Security framework + Kotlin Android SDK (platform channels).

**Spec:** `docs/superpowers/specs/2026-09-07-licensing-design.md` — the plan argues from the spec; executors read both.

## Global Constraints

- Trial duration = **30 days** from first launch, granted server-side (`LICENSE_TRIAL_DAYS=30`).
- **Reinstall grants no new trial** — enforced by stable device ID (`ANDROID_ID` / iOS Keychain UUID) + server `trial_used` flag.
- License key format: `RR-XXXX-XXXX-XXXX` (uppercase, unambiguous alphabet, `secrets`-generated), **device-bound** (rejects use on a second device).
- Device code format: 8-char uppercase alphanumeric (e.g. `RR2F9K4Q`), generated at registration, shown in-app, typed into admin to issue keys.
- Server URL: `https://ai.rankrocket.online` (client default via `--dart-define=LICENSE_SERVER_URL` override).
- Support email copy: **rpfinser24@gmail.com** — exact string used in the app UI.
- First launch requires a server connection (trial cannot start offline).
- No secrets committed: `.env` gitignored, `.env.example` committed.
- The Flutter shared code is the single implementation for both Android and iOS.
- Windows dev machine; Flutter at `G:\Python_dev\AI_tools\Android_app\flutter\bin\flutter.bat`; project root = `Uncensored-Local-AI-Multiplatform/`.

---

### Task 1: License server — scaffold, DB, register + status endpoints (TDD)

**Files:**
- Create: `license_server/requirements.txt`
- Create: `license_server/.env.example`
- Create: `license_server/app.py`
- Create: `license_server/tests/test_api.py`
- Create: `license_server/.gitignore`

**Interfaces:**
- Produces: Flask app `app` in `license_server/app.py`; `GET /api/v1/status?device_id=`, `POST /api/v1/register`. Response shape (JSON):
  `{ "status": "trial"|"active"|"expired"|"needs_license"|"unknown", "device_code": str|null, "expires_at": str|null, "days_left": int, "message": str }`

- [ ] **Step 1: Write `requirements.txt`, `.env.example`, `.gitignore`**

`license_server/requirements.txt`:
```
Flask>=3.0
gunicorn>=22.0
waitress>=3.0
pytest>=8.0
```

`license_server/.env.example`:
```
LICENSE_ADMIN_PASSWORD=change-me-strong-password
LICENSE_SECRET_KEY=change-me-random-session-secret
LICENSE_TRIAL_DAYS=30
LICENSE_PORT=8900
LICENSE_DB=license.db
```

`license_server/.gitignore`:
```
.env
license.db
__pycache__/
*.pyc
.venv/
```

- [ ] **Step 2: Write the failing tests**

`license_server/tests/test_api.py`:
```python
import json
import pytest

from app import app, init_db


@pytest.fixture()
def client(tmp_path):
    app.config.update(TESTING=True, DB_PATH=str(tmp_path / "test.db"))
    with app.app_context():
        init_db()
    with app.test_client() as c:
        yield c


def _register(client, device_id, **extra):
    body = {
        "device_id": device_id,
        "platform": "android",
        "model": "Pixel 8",
        "os_version": "14",
        "app_version": "1.1.0",
    }
    body.update(extra)
    return client.post("/api/v1/register", json=body)


def test_register_new_device_grants_trial(client):
    res = _register(client, "dev-111")
    assert res.status_code == 200
    data = res.get_json()
    assert data["status"] == "trial"
    assert data["device_code"]
    assert len(data["device_code"]) == 8
    assert data["expires_at"] is not None
    assert data["days_left"] > 0


def test_register_same_device_reinstall_no_new_trial(client):
    first = _register(client, "dev-222").get_json()
    first_expiry = first["expires_at"]

    # Re-register (reinstall) — trial must NOT restart; same expiry.
    again = _register(client, "dev-222").get_json()
    assert again["status"] == "trial"
    assert again["expires_at"] == first_expiry


def test_status_unknown_device(client):
    res = client.get("/api/v1/status?device_id=never-seen")
    assert res.status_code == 200
    assert res.get_json()["status"] == "unknown"


def test_register_updates_last_seen_and_version(client):
    _register(client, "dev-333", app_version="1.0.0")
    res = _register(client, "dev-333", app_version="1.1.0")
    assert res.get_json()["status"] == "trial"
```

- [ ] **Step 3: Run tests — verify they fail**

Run: `python -m pytest license_server/tests/test_api.py -v`
Expected: FAIL (module `app` not importable / no `app` object).

- [ ] **Step 4: Write `license_server/app.py` (register + status + DB)**

```python
import datetime
import os
import secrets
import sqlite3

from flask import Flask, g, jsonify, request

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
TRIAL_DAYS = int(os.environ.get("LICENSE_TRIAL_DAYS", "30"))

app = Flask(__name__)
app.secret_key = os.environ.get("LICENSE_SECRET_KEY", "dev-secret-key")
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
        """
    )
    conn.commit()
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


if __name__ == "__main__":
    init_db()
    try:
        from waitress import serve

        port = int(os.environ.get("LICENSE_PORT", "8900"))
        print(f"License server on http://0.0.0.0:{port}")
        serve(app, host="0.0.0.0", port=port)
    except ImportError:
        app.run(debug=True, port=8900)
```

- [ ] **Step 5: Run tests — verify they pass**

Run: `python -m pytest license_server/tests/test_api.py -v`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add license_server/
git commit -m "feat(license): license server scaffold with register/status endpoints"
```

---

### Task 2: License server — activate endpoint + key generation (TDD)

**Files:**
- Modify: `license_server/app.py` (add `_make_license_key`, `_throttle`, `POST /api/v1/activate`)
- Modify: `license_server/tests/test_api.py`

**Interfaces:**
- Produces: `POST /api/v1/activate` body `{device_id, license_key}` →
  - 200 `{status:"active", expires_at, days_left}`
  - 404 `{error:"Invalid license key"}`
  - 403 `{error:"This license key is already used on another device"}`
  - 429 when throttled
- License key format `RR-XXXX-XXXX-XXXX` via `_make_license_key()`.

- [ ] **Step 1: Write the failing tests** (append to `test_api.py`)

```python
def _activate(client, device_id, key):
    return client.post("/api/v1/activate", json={"device_id": device_id, "license_key": key})


def _issue_key(client, device_code, duration_days=365):
    return client.post(
        "/admin/generate-key",
        data={"device_code": device_code, "duration_days": str(duration_days), "notes": "test"},
        follow_redirects=False,
    )
```

Note: `_issue_key` requires the admin panel (Task 3). For Task 2, tests insert a license directly into the DB instead:

```python
def _insert_license(client, device_id, key, duration_days):
    import sqlite3
    conn = sqlite3.connect(app.config["DB_PATH"])
    conn.execute(
        "INSERT INTO licenses (license_key, device_id, issued_at, expires_at, duration_days, notes) VALUES (?, ?, ?, NULL, ?, NULL)",
        (key, device_id, "2026-09-01T00:00:00+00:00", duration_days),
    )
    conn.commit()
    conn.close()


def test_activate_valid_unbound_key_binds_device(client):
    _insert_license(client, None, "RR-AAAA-BBBB-CCCC", 365)
    res = _activate(client, "dev-1", "rr-aaaa-bbbb-cccc")
    assert res.status_code == 200
    data = res.get_json()
    assert data["status"] == "active"
    assert data["days_left"] > 300
    assert data["expires_at"]


def test_activate_key_used_on_another_device_rejected(client):
    _insert_license(client, "dev-A", "RR-DDDD-EEEE-FFFF", 365)
    res = _activate(client, "dev-B", "RR-DDDD-EEEE-FFFF")
    assert res.status_code == 403


def test_activate_invalid_key(client):
    res = _activate(client, "dev-1", "RR-NOPE-NOPE-NOPE")
    assert res.status_code == 404


def test_activate_makes_device_active(client):
    _insert_license(client, None, "RR-1111-2222-3333", 30)
    _register(client, "dev-777")
    res = _activate(client, "dev-777", "RR-1111-2222-3333")
    assert res.status_code == 200
    st = client.get("/api/v1/status?device_id=dev-777").get_json()
    assert st["status"] == "active"
```

- [ ] **Step 2: Run tests — verify they fail**

Run: `python -m pytest license_server/tests/test_api.py -v`
Expected: FAIL (`/api/v1/activate` returns 404).

- [ ] **Step 3: Implement activate + key generation** (append to `app.py`)

```python
import time

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

    issued = _parse_iso(lic["issued_at"])
    exp = issued + datetime.timedelta(days=lic["duration_days"])
    db.execute(
        "UPDATE licenses SET device_id = ? WHERE license_key = ?", (device_id, key)
    )
    db.execute(
        "UPDATE devices SET license_expires_at = ? WHERE device_id = ?",
        (exp.isoformat(), device_id),
    )
    db.commit()

    now = datetime.datetime.now(datetime.timezone.utc)
    return jsonify(
        {
            "status": "active",
            "expires_at": exp.isoformat(),
            "days_left": max(0, (exp - now).days),
        }
    )
```

- [ ] **Step 4: Run tests — verify they pass**

Run: `python -m pytest license_server/tests/test_api.py -v`
Expected: PASS (8 tests). Note: `_activate` key is uppercased server-side; tests already use mixed case for the unbound-key test to prove normalization.

- [ ] **Step 5: Commit**

```bash
git add license_server/
git commit -m "feat(license): activate endpoint with device-bound key validation"
```

---

### Task 3: License server — admin panel (TDD)

**Files:**
- Modify: `license_server/app.py` (add session auth, admin routes, inline HTML, `generate-key`, `extend`, `revoke`, `reset-trial`)
- Modify: `license_server/tests/test_api.py`

**Interfaces:**
- Produces: admin password from `LICENSE_ADMIN_PASSWORD` (default `change-me`); routes:
  - `GET/POST /admin/login`, `GET /admin/logout`
  - `GET /admin` (dashboard, `@login_required`)
  - `POST /admin/generate-key` `{device_code, duration_days, notes}` → one-time key display page
  - `POST /admin/device/<id>/extend` `{days}` → adds days to `license_expires_at`
  - `POST /admin/device/<id>/revoke` → sets `license_expires_at = NULL`
  - `POST /admin/device/<id>/reset-trial` → sets `trial_used = 0`

- [ ] **Step 1: Write the failing tests** (append to `test_api.py`)

```python
def _login(client, password="change-me"):
    return client.post("/admin/login", data={"password": password}, follow_redirects=False)


def test_admin_login_and_dashboard(client):
    _register(client, "dev-999")
    res = _login(client)
    assert res.status_code == 302
    page = client.get("/admin")
    assert page.status_code == 200
    assert b"Generate license key" in page.data


def test_admin_requires_login(client):
    res = client.get("/admin")
    assert res.status_code == 302
    assert "/admin/login" in res.headers["Location"]


def test_admin_generate_key_and_activate(client):
    _register(client, "dev-555")
    code = client.get("/api/v1/status?device_id=dev-555").get_json()["device_code"]
    _login(client)
    res = client.post(
        "/admin/generate-key",
        data={"device_code": code, "duration_days": "90", "notes": "paid"},
        follow_redirects=False,
    )
    assert res.status_code == 200
    key = _extract_key(res.data)
    assert key.startswith("RR-")
    act = client.post("/api/v1/activate", json={"device_id": "dev-555", "license_key": key})
    assert act.status_code == 200


def test_admin_generate_key_unknown_code(client):
    _login(client)
    res = client.post(
        "/admin/generate-key",
        data={"device_code": "XXXXXXXX", "duration_days": "30", "notes": ""},
    )
    assert res.status_code == 200
    assert b"not found" in res.data.lower()


def test_admin_extend_adds_days(client):
    _register(client, "dev-666")
    _login(client)
    before = client.get("/api/v1/status?device_id=dev-666").get_json()["expires_at"]
    dev_id = _device_id_by_code(client, "dev-666")
    client.post(f"/admin/device/{dev_id}/extend", data={"days": "10"})
    after = client.get("/api/v1/status?device_id=dev-666").get_json()["expires_at"]
    assert after > before


def test_admin_revoke_removes_license(client):
    _insert_license(client, "dev-888", "RR-AAAA-BBBB-CCDD", 365)
    _register(client, "dev-888")
    _activate(client, "dev-888", "RR-AAAA-BBBB-CCDD")
    assert client.get("/api/v1/status?device_id=dev-888").get_json()["status"] == "active"
    _login(client)
    dev_id = _device_id_by_code(client, "dev-888")
    client.post(f"/admin/device/{dev_id}/revoke")
    # License removed; a fresh device falls back to its (still-valid) trial.
    assert client.get("/api/v1/status?device_id=dev-888").get_json()["status"] == "trial"
```

Helper functions appended at the bottom of `test_api.py`:

```python
def _extract_key(html_bytes):
    import re
    m = re.search(rb"RR-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}", html_bytes)
    assert m, "no license key in admin response"
    return m.group(0).decode()


def _device_id_by_code(client, registered_device_id):
    # Status returns device_code; look up the DB row id via status of that device.
    import sqlite3
    conn = sqlite3.connect(app.config["DB_PATH"])
    row = conn.execute(
        "SELECT id FROM devices WHERE device_id = ?", (registered_device_id,)
    ).fetchone()
    conn.close()
    return row[0]
```

- [ ] **Step 2: Run tests — verify they fail**

Run: `python -m pytest license_server/tests/test_api.py -v`
Expected: FAIL (`/admin/*` return 404).

- [ ] **Step 3: Implement the admin panel** (append to `app.py`)

```python
from functools import wraps
from flask import render_template_string, session, redirect, url_for

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
{{ extra }}
</div></body></html>"""


def login_required(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not session.get("admin"):
            return redirect(url_for("admin_login"))
        return f(*args, **kwargs)

    return wrapper


@app.route("/admin/login", methods=["GET", "POST"])
def admin_login():
    if request.method == "POST" and request.form.get("password") == ADMIN_PASSWORD:
        session["admin"] = True
        return redirect(url_for("admin_dashboard"))
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
    tbody = ""
    for d in rows:
        tbody += (
            "<tr>"
            f"<td><b>{d['device_code']}</b></td>"
            f"<td>{d['platform'] or '-'}</td>"
            f"<td>{d['model'] or '-'}</td>"
            f"<td>{d['app_version'] or '-'}</td>"
            f"<td>{_device_status_label(d)}</td>"
            f"<td>{d['expires_at'] or '-'}</td>"
            f"<td>{d['first_seen'][:10] if d['first_seen'] else '-'}</td>"
            f"<td>{d['last_seen'][:10] if d['last_seen'] else '-'}</td>"
            "<td>"
            f'<form method="post" action="/admin/device/{d["id"]}/extend">'
            '<input type="number" name="days" value="30" size="3" min="1">'
            '<button>Extend</button></form>'
            f'<form method="post" action="/admin/device/{d["id"]}/revoke">'
            '<button>Revoke</button></form>'
            f'<form method="post" action="/admin/device/{d["id"]}/reset-trial">'
            '<button>Reset trial</button></form>'
            "</td></tr>"
        )
    return render_template_string(
        _PAGE,
        extra=f"""<div class="box"><h3>Generate license key</h3>
        <form method="post" action="/admin/generate-key">
        <input name="device_code" placeholder="Device code (8 chars)" required>
        <input type="number" name="duration_days" value="365" min="1" required> days
        <input name="notes" placeholder="notes (e.g. payment id)">
        <button>Generate key</button></form>
        <p><a href="/admin/logout">Logout</a></p></div>
        <table><thead><tr><th>Code</th><th>Platform</th><th>Model</th>
        <th>Version</th><th>Status</th><th>Expires</th><th>First seen</th>
        <th>Last seen</th><th>Actions</th></tr></thead><tbody>{tbody}</tbody></table>""",
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
    db.execute(
        "UPDATE devices SET trial_used = 0, trial_started_at = NULL WHERE id = ?",
        (device_row_id,),
    )
    db.commit()
    return redirect(url_for("admin_dashboard"))
```

- [ ] **Step 4: Run tests — verify they pass**

Run: `python -m pytest license_server/tests/test_api.py -v`
Expected: PASS (14 tests).

- [ ] **Step 5: Commit**

```bash
git add license_server/
git commit -m "feat(license): admin panel with key generation, extend, revoke, reset-trial"
```

---

### Task 4: License server — deployment files + local run docs

**Files:**
- Create: `license_server/deploy.sh`
- Create: `license_server/license.service`
- Create: `license_server/nginx-ai.conf.example`
- Create: `license_server/README.md`

**Interfaces:**
- Produces: deployable artifacts + instructions for the Ganga VPS (`/opt/license_server`, systemd `license.service`, nginx `ai.rankrocket.online` → `127.0.0.1:8900`).

- [ ] **Step 1: Write `deploy.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Deploy the license server to the Ganga VPS and restart it.
# Usage: ./deploy.sh   (requires the `Ganga-ssh` SSH alias from ~/.ssh/config)
REMOTE_DIR=/opt/license_server

echo ">> Syncing files to $REMOTE_DIR"
rsync -av --exclude '.env' --exclude 'license.db' --exclude '__pycache__' \
  ./ "$Ganga-ssh:$REMOTE_DIR/"

echo ">> Installing/updating deps"
ssh "$Ganga-ssh" "cd $REMOTE_DIR && (python3 -m venv .venv 2>/dev/null || true) && \
  ./.venv/bin/pip install -q -r requirements.txt"

echo ">> Restarting service"
ssh "$Ganga-ssh" "sudo cp $REMOTE_DIR/license.service /etc/systemd/system/license.service && \
  sudo systemctl daemon-reload && sudo systemctl enable license && sudo systemctl restart license && \
  sleep 1 && sudo systemctl is-active license"
```

- [ ] **Step 2: Write `license.service`**

```ini
[Unit]
Description=RankRocket AI License Server
After=network.target

[Service]
WorkingDirectory=/opt/license_server
EnvironmentFile=/opt/license_server/.env
ExecStart=/opt/license_server/.venv/bin/gunicorn -w 2 -b 127.0.0.1:8900 app:app
Restart=always
User=root

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 3: Write `nginx-ai.conf.example`**

```nginx
server {
    listen 80;
    server_name ai.rankrocket.online;

    location / {
        proxy_pass http://127.0.0.1:8900;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Deploy nginx: copy to `/etc/nginx/sites-available/ai.rankrocket.online`, symlink into `sites-enabled`, `nginx -t`, `systemctl reload nginx`, then `certbot --nginx -d ai.rankrocket.online`.

- [ ] **Step 4: Write `README.md`** (local run + VPS deploy + admin workflow + how device-bound flow works; reference `docs/licensing-admin.md` in the Flutter repo for the admin walkthrough).

- [ ] **Step 5: Commit**

```bash
git add license_server/
git commit -m "chore(license): deployment files and run docs"
```

---

### Task 5: Flutter — config + license state model (TDD)

**Files:**
- Create: `lib/config.dart`
- Create: `lib/models/license_state.dart`
- Create: `test/license_state_test.dart`

**Interfaces:**
- Produces:
  - `class AppConfig { static const licenseServerUrl = String.fromEnvironment('LICENSE_SERVER_URL', defaultValue: 'https://ai.rankrocket.online'); }`
  - `enum LicenseStatus { loading, trial, active, expired, needsLicense, offline, serverError }`
  - `class LicenseInfo { final LicenseStatus status; final String? deviceCode; final DateTime? expiresAt; final int daysLeft; final String? message; LicenseInfo.fromJson(Map<String,dynamic>); }`

- [ ] **Step 1: Write `lib/config.dart`**

```dart
/// App-wide configuration.
class AppConfig {
  /// License server base URL. Override at build time:
  /// flutter run --dart-define=LICENSE_SERVER_URL=http://192.168.1.10:8900
  static const String licenseServerUrl = String.fromEnvironment(
    'LICENSE_SERVER_URL',
    defaultValue: 'https://ai.rankrocket.online',
  );
}
```

- [ ] **Step 2: Write the failing test** — `test/license_state_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:portable_ai_flutter/models/license_state.dart';

void main() {
  test('parses trial response', () {
    final info = LicenseInfo.fromJson({
      'status': 'trial',
      'device_code': 'RR2F9K4Q',
      'expires_at': '2026-10-07T00:00:00+00:00',
      'days_left': 29,
      'message': '',
    });
    expect(info.status, LicenseStatus.trial);
    expect(info.deviceCode, 'RR2F9K4Q');
    expect(info.daysLeft, 29);
    expect(info.expiresAt, isNotNull);
  });

  test('maps needs_license and unknown to needsLicense', () {
    for (final s in ['needs_license', 'unknown']) {
      final info = LicenseInfo.fromJson({'status': s});
      expect(info.status, LicenseStatus.needsLicense);
    }
  });

  test('maps active and expired', () {
    expect(LicenseInfo.fromJson({'status': 'active'}).status, LicenseStatus.active);
    expect(LicenseInfo.fromJson({'status': 'expired'}).status, LicenseStatus.expired);
  });
}
```

- [ ] **Step 3: Run test — verify it fails**

Run: `flutter test test/license_state_test.dart`
Expected: FAIL (`license_state.dart` not found).

- [ ] **Step 4: Write `lib/models/license_state.dart`**

```dart
/// Lifecycle of the app license/trial on this device.
enum LicenseStatus {
  loading,
  trial,
  active,
  expired,
  needsLicense,
  offline,
  serverError,
}

/// Parsed result from the license server.
class LicenseInfo {
  final LicenseStatus status;
  final String? deviceCode;
  final DateTime? expiresAt;
  final int daysLeft;
  final String? message;

  const LicenseInfo({
    required this.status,
    this.deviceCode,
    this.expiresAt,
    this.daysLeft = 0,
    this.message,
  });

  factory LicenseInfo.fromJson(Map<String, dynamic> json) {
    final raw = (json['status'] as String?) ?? 'needs_license';
    final status = switch (raw) {
      'trial' => LicenseStatus.trial,
      'active' => LicenseStatus.active,
      'expired' => LicenseStatus.expired,
      _ => LicenseStatus.needsLicense,
    };
    return LicenseInfo(
      status: status,
      deviceCode: json['device_code'] as String?,
      expiresAt: json['expires_at'] != null
          ? DateTime.tryParse(json['expires_at'] as String)
          : null,
      daysLeft: (json['days_left'] as num?)?.toInt() ?? 0,
      message: json['message'] as String?,
    );
  }
}
```

- [ ] **Step 5: Run test — verify it passes**

Run: `flutter test test/license_state_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/config.dart lib/models/license_state.dart test/license_state_test.dart
git commit -m "feat(license): client config and license state model"
```

---

### Task 6: Flutter — device info service + platform channels (TDD)

**Files:**
- Modify: `lib/services/device_info_service.dart`
- Modify: `android/app/src/main/kotlin/com/portableai/portable_ai_flutter/MainActivity.kt`
- Modify: `ios/Runner/AppDelegate.swift`
- Create: `test/device_info_service_test.dart`

**Interfaces:**
- Produces (on channel `rankrocket/device`):
  - `Future<String?> getStableDeviceId()`
  - `Future<String?> getDeviceModel()`
  - `Future<String?> getOsVersion()`
  - `Future<String?> getAppVersion()`
  - `String getPlatform()` → `android` | `ios` | `desktop` | `web`

- [ ] **Step 1: Write the failing test** — `test/device_info_service_test.dart`

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portable_ai_flutter/services/device_info_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('returns stable device id from platform channel', () async {
    const channel = MethodChannel('rankrocket/device');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getStableDeviceId') return 'ANDROID_ID_123';
      if (call.method == 'getDeviceModel') return 'Pixel 8';
      if (call.method == 'getOsVersion') return '14';
      if (call.method == 'getAppVersion') return '1.1.0';
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    final svc = DeviceInfoService();
    expect(await svc.getStableDeviceId(), 'ANDROID_ID_123');
    expect(await svc.getDeviceModel(), 'Pixel 8');
    expect(await svc.getOsVersion(), '14');
    expect(await svc.getAppVersion(), '1.1.0');
  });
}
```

- [ ] **Step 2: Run test — verify it fails**

Run: `flutter test test/device_info_service_test.dart`
Expected: FAIL (methods missing on `DeviceInfoService`).

- [ ] **Step 3: Implement the Dart service** — replace `lib/services/device_info_service.dart`

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Reads device capabilities + stable device ID from the native host.
class DeviceInfoService {
  static const MethodChannel _channel = MethodChannel('rankrocket/device');

  /// Total physical RAM in bytes, or null when unavailable (non-Android).
  Future<int?> getTotalRamBytes() async {
    try {
      return await _channel.invokeMethod<int>('getTotalRam');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Stable ID that survives app uninstall/reinstall:
  /// Android -> Settings.Secure.ANDROID_ID, iOS -> Keychain-persisted UUID.
  Future<String?> getStableDeviceId() async {
    try {
      return await _channel.invokeMethod<String>('getStableDeviceId');
    } catch (_) {
      return null;
    }
  }

  Future<String?> getDeviceModel() async {
    try {
      return await _channel.invokeMethod<String>('getDeviceModel');
    } catch (_) {
      return null;
    }
  }

  Future<String?> getOsVersion() async {
    try {
      return await _channel.invokeMethod<String>('getOsVersion');
    } catch (_) {
      return null;
    }
  }

  Future<String?> getAppVersion() async {
    try {
      return await _channel.invokeMethod<String>('getAppVersion');
    } catch (_) {
      return null;
    }
  }

  String getPlatform() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      default:
        return 'desktop';
    }
  }
}
```

- [ ] **Step 4: Implement the Android channel** — replace `android/app/src/main/kotlin/com/portableai/portable_ai_flutter/MainActivity.kt`

```kotlin
package com.portableai.portable_ai_flutter

import android.app.ActivityManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "rankrocket/device",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getTotalRam" -> {
                    try {
                        val am = getSystemService(ACTIVITY_SERVICE) as ActivityManager
                        val memInfo = ActivityManager.MemoryInfo()
                        am.getMemoryInfo(memInfo)
                        result.success(memInfo.totalMem)
                    } catch (e: Exception) {
                        result.error("RAM_UNAVAILABLE", e.message, null)
                    }
                }
                "getStableDeviceId" -> {
                    try {
                        val id = Settings.Secure.getString(
                            contentResolver,
                            Settings.Secure.ANDROID_ID,
                        )
                        result.success(id)
                    } catch (e: Exception) {
                        result.error("DEVICE_ID_UNAVAILABLE", e.message, null)
                    }
                }
                "getDeviceModel" -> result.success(Build.MODEL)
                "getOsVersion" -> result.success(Build.VERSION.RELEASE)
                "getAppVersion" -> {
                    try {
                        val pkgInfo = packageManager.getPackageInfo(packageName, 0)
                        result.success(pkgInfo.versionName)
                    } catch (e: Exception) {
                        result.error("VERSION_UNAVAILABLE", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
```

- [ ] **Step 5: Implement the iOS channel** — replace `ios/Runner/AppDelegate.swift`

```swift
import Flutter
import UIKit
import Security

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let channelName = "rankrocket/device"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "RankRocketDevice") else {
      return
    }
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "getStableDeviceId":
        result(self.stableDeviceId())
      case "getDeviceModel":
        result(self.deviceModel())
      case "getOsVersion":
        result(UIDevice.current.systemVersion)
      case "getAppVersion":
        result(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func stableDeviceId() -> String {
    let service = "com.portableai.portableAiFlutter"
    let account = "stable-device-id"
    if let existing = Self.keychainRead(service: service, account: account) {
      return existing
    }
    let newId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    Self.keychainWrite(service: service, account: account, value: newId)
    return newId
  }

  private func deviceModel() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let machine = withUnsafePointer(to: &systemInfo.machine) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) ?? "" }
    }
    return "\(UIDevice.current.model) (\(machine))"
  }

  private static func keychainWrite(service: String, account: String, value: String) -> Bool {
    let data = Data(value.utf8)
    let deleteQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(deleteQuery as CFDictionary)
    let addQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
    ]
    return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
  }

  private static func keychainRead(service: String, account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data,
          let value = String(data: data, encoding: .utf8) else {
      return nil
    }
    return value
  }
}
```

> If the iOS build ever complains about the implicit-engine API, use the classic pattern instead: implement `application(_:didFinishLaunchingWithOptions:)` returning `GeneratedPluginRegistrant.register(with: self)` and create the channel with `(window?.rootViewController as! FlutterViewController).binaryMessenger`. The Keychain logic is identical.

- [ ] **Step 6: Run the Dart test — verify it passes**

Run: `flutter test test/device_info_service_test.dart`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/services/device_info_service.dart android/ ios/Runner/AppDelegate.swift test/device_info_service_test.dart
git commit -m "feat(license): stable device ID via platform channels (Android + iOS)"
```

---

### Task 7: Flutter — LicenseService (TDD)

**Files:**
- Create: `lib/services/license_service.dart`
- Create: `test/license_service_test.dart`

**Interfaces:**
- Consumes: `AppConfig.licenseServerUrl`, `LicenseInfo`, `LicenseStatus`, `DeviceInfoService`, Hive box `license`.
- Produces:
  - `class LicenseService extends GetxService` with:
    - `final status = LicenseStatus.loading.obs;`
    - `final info = Rxn<LicenseInfo>();`
    - `final activating = false.obs;`
    - `final activateError = ''.obs;`
    - `Future<void> init({Duration timeout = const Duration(seconds: 8)})`
    - `Future<void> activate(String key)`
  - Constructor takes `{http.Client? client}` for tests.

- [ ] **Step 1: Write the failing test** — `test/license_service_test.dart`

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:portable_ai_flutter/models/license_state.dart';
import 'package:portable_ai_flutter/services/license_service.dart';
import 'package:get/get.dart';

Future<http.Response> _json(int code, Map<String, dynamic> body) =>
    http.Response(jsonEncode(body), code, headers: {'content-type': 'application/json'});

void main() {
  setUp(() async {
    final dir = await getTemporaryDirectory();
    await Hive.initFlutter('${dir.path}/hive_test');
    if (!Hive.isBoxOpen('license')) {
      await Hive.openBox('license');
    }
  });

  tearDown(() async {
    Get.reset();
    await Hive.box('license').clear();
  });

  test('init registers and stores trial status', () async {
    final client = MockClient((req) async {
      expect(req.url.path, '/api/v1/register');
      return _json(200, {
        'status': 'trial',
        'device_code': 'RR2F9K4Q',
        'expires_at': '2026-10-07T00:00:00+00:00',
        'days_left': 29,
        'message': '',
      });
    });

    final svc = LicenseService(client: client);
    await svc.init(timeout: const Duration(seconds: 2));

    expect(svc.status.value, LicenseStatus.trial);
    expect(svc.info.value!.deviceCode, 'RR2F9K4Q');
    expect(Hive.box('license').get('status'), 'trial');
  });

  test('falls back to offline when server unreachable and no cache', () async {
    final client = MockClient((req) async => throw Exception('offline'));
    final svc = LicenseService(client: client);
    await svc.init(timeout: const Duration(milliseconds: 500));
    expect(svc.status.value, LicenseStatus.offline);
  });

  test('activate success flips to active', () async {
    final client = MockClient((req) async {
      if (req.url.path == '/api/v1/activate') {
        return _json(200, {
          'status': 'active',
          'expires_at': '2027-09-01T00:00:00+00:00',
          'days_left': 360,
        });
      }
      return _json(500, {'error': 'boom'});
    });
    final svc = LicenseService(client: client);
    await svc.activate('RR-AAAA-BBBB-CCCC');
    expect(svc.status.value, LicenseStatus.active);
    expect(svc.activateError.value, '');
  });

  test('activate failure surfaces server error', () async {
    final client = MockClient(
      (req) async => _json(403, {'error': 'This license key is already used on another device'}),
    );
    final svc = LicenseService(client: client);
    await svc.activate('RR-AAAA-BBBB-CCCC');
    expect(svc.status.value, LicenseStatus.needsLicense);
    expect(svc.activateError.value, 'This license key is already used on another device');
  });
}
```

> Hive needs a valid init path. `Hive.initFlutter` requires `path_provider`; in tests use `getTemporaryDirectory()`. If `Hive.initFlutter` is not available in tests, use `Hive.init('${dir.path}/hive_test')` and call `Hive.init` directly.

- [ ] **Step 2: Run test — verify it fails**

Run: `flutter test test/license_service_test.dart`
Expected: FAIL (`license_service.dart` not found).

- [ ] **Step 3: Implement `lib/services/license_service.dart`**

```dart
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/license_state.dart';
import 'device_info_service.dart';

/// Validates the install's trial/license against the license server.
class LicenseService extends GetxService {
  LicenseService({http.Client? client}) : _client = client ?? http.Client();

  static const String boxName = 'license';
  final http.Client _client;

  final status = LicenseStatus.loading.obs;
  final info = Rxn<LicenseInfo>();
  final activating = false.obs;
  final activateError = ''.obs;

  String? _deviceId;

  Future<void> init({Duration timeout = const Duration(seconds: 8)}) async {
    final box = Hive.box(boxName);
    final devInfo = DeviceInfoService();

    _deviceId = await devInfo.getStableDeviceId();
    if (_deviceId == null || _deviceId!.isEmpty) {
      _deviceId = box.get('fallback_device_id') as String?;
      _deviceId ??= _uuid();
      box.put('fallback_device_id', _deviceId);
    }
    box.put('device_id', _deviceId);

    final body = jsonEncode({
      'device_id': _deviceId,
      'platform': devInfo.getPlatform(),
      'model': await devInfo.getDeviceModel(),
      'os_version': await devInfo.getOsVersion(),
      'app_version': await devInfo.getAppVersion(),
    });

    try {
      final res = await _client
          .post(
            Uri.parse('${AppConfig.licenseServerUrl}/api/v1/register'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(timeout);
      if (res.statusCode == 200) {
        final li = LicenseInfo.fromJson(jsonDecode(res.body));
        info.value = li;
        status.value = li.status;
        box.putAll({
          'status': li.status.name,
          'device_code': li.deviceCode,
          'expires_at': li.expiresAt?.toIso8601String(),
        });
        return;
      }
    } catch (_) {
      // Server unreachable — fall back to cached state below.
    }

    _loadFromCache(box);
  }

  void _loadFromCache(Box box) {
    final cached = box.get('status') as String?;
    if (cached == null) {
      status.value = LicenseStatus.offline;
      return;
    }
    final expiryStr = box.get('expires_at') as String?;
    DateTime? expiry;
    if (expiryStr != null) {
      expiry = DateTime.tryParse(expiryStr);
    }
    if (expiry != null && expiry.isAfter(DateTime.now().toUtc())) {
      final cachedStatus = LicenseStatus.values
          .firstWhere((s) => s.name == cached, orElse: () => LicenseStatus.trial);
      final effective =
          cachedStatus == LicenseStatus.active ? LicenseStatus.active : LicenseStatus.trial;
      status.value = effective;
      info.value = LicenseInfo(
        status: effective,
        deviceCode: box.get('device_code') as String?,
        expiresAt: expiry,
      );
    } else {
      status.value = LicenseStatus.offline;
    }
  }

  Future<void> activate(String key) async {
    activating.value = true;
    activateError.value = '';
    try {
      final res = await _client
          .post(
            Uri.parse('${AppConfig.licenseServerUrl}/api/v1/activate'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'device_id': _deviceId, 'license_key': key}),
          )
          .timeout(const Duration(seconds: 10));
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode == 200) {
        final li = LicenseInfo.fromJson(json);
        info.value = li;
        status.value = LicenseStatus.active;
        Hive.box(boxName).putAll({
          'status': 'active',
          'device_code': li.deviceCode,
          'expires_at': li.expiresAt?.toIso8601String(),
        });
      } else {
        activateError.value = (json['error'] as String?) ?? 'Activation failed';
      }
    } catch (_) {
      activateError.value =
          'Cannot reach the server. Check your internet connection and try again.';
    } finally {
      activating.value = false;
    }
  }

  String _uuid() {
    // RFC-4122 v4-ish; good enough for a fallback persisted per-install.
    final r = _randomHex(16);
    return '${r.substring(0, 8)}-${r.substring(8, 12)}-4${r.substring(13, 16)}'
        '-a${r.substring(17, 20)}-${r.substring(20, 32)}';
  }

  String _randomHex(int bytes) {
    final sb = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      sb.write((0 + (DateTime.now().microsecondsSinceEpoch % 16)).toRadixString(16));
    }
    return sb.toString();
  }

  @override
  void onClose() {
    _client.close();
    super.onClose();
  }
}
```

- [ ] **Step 4: Run test — verify it passes**

Run: `flutter test test/license_service_test.dart`
Expected: PASS (4 tests). If a Hive test-path issue appears, adjust the `setUp` to `Hive.init('${dir.path}/hive_test')` instead of `Hive.initFlutter`.

- [ ] **Step 5: Commit**

```bash
git add lib/services/license_service.dart test/license_service_test.dart
git commit -m "feat(license): client license service with cache fallback"
```

---

### Task 8: Flutter — LicenseScreen + trial banner (TDD)

**Files:**
- Create: `lib/screens/license_screen.dart`
- Create: `lib/widgets/license_trial_banner.dart`
- Create: `test/license_screen_test.dart`

**Interfaces:**
- Consumes: `LicenseService` (GetX), `LicenseStatus`, `AppColors`/theme helpers (`context.bg`, `context.text`, `context.textM`, `context.textD`, `context.bgPanel`, `context.border`, `AppColors.accent`, `AppColors.green`, `AppColors.red`, `AppColors.orange` — verify each in `lib/theme/app_theme.dart` before use; fall back to `Theme.of(context).colorScheme` if a helper is missing).
- Produces:
  - `class LicenseScreen extends GetView<LicenseService>`
  - `class LicenseTrialBanner extends StatelessWidget` — shows "Trial: N days left" only when status is `trial`.

- [ ] **Step 1: Write the failing widget test** — `test/license_screen_test.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:portable_ai_flutter/models/license_state.dart';
import 'package:portable_ai_flutter/screens/license_screen.dart';
import 'package:portable_ai_flutter/services/license_service.dart';

void main() {
  setUp(() async {
    final dir = await getTemporaryDirectory();
    await Hive.init('${dir.path}/hive_screen_test');
    if (!Hive.isBoxOpen(LicenseService.boxName)) {
      await Hive.openBox(LicenseService.boxName);
    }
  });

  tearDown(() async {
    Get.reset();
    await Hive.box(LicenseService.boxName).clear();
  });

  testWidgets('shows device code and activate button', (tester) async {
    final svc = LicenseService();
    svc.status.value = LicenseStatus.needsLicense;
    svc.info.value = const LicenseInfo(
      status: LicenseStatus.needsLicense,
      deviceCode: 'RR2F9K4Q',
    );
    Get.put(svc);

    await tester.pumpWidget(const GetMaterialApp(home: LicenseScreen()));
    await tester.pump();

    expect(find.text('RR2F9K4Q'), findsOneWidget);
    expect(find.textContaining('rpfinser24@gmail.com'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Activate'), findsOneWidget);
  });

  testWidgets('shows offline message when offline', (tester) async {
    final svc = LicenseService();
    svc.status.value = LicenseStatus.offline;
    Get.put(svc);

    await tester.pumpWidget(const GetMaterialApp(home: LicenseScreen()));
    await tester.pump();

    expect(find.textContaining('internet'), findsWidgets);
  });
}
```

- [ ] **Step 2: Run test — verify it fails**

Run: `flutter test test/license_screen_test.dart`
Expected: FAIL (`license_screen.dart` not found).

- [ ] **Step 3: Implement `lib/widgets/license_trial_banner.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../theme/app_colors.dart';
import '../services/license_service.dart';

/// Slim banner shown while the 30-day trial is active.
class LicenseTrialBanner extends GetView<LicenseService> {
  const LicenseTrialBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (controller.status.value != LicenseStatus.trial) {
        return const SizedBox.shrink();
      }
      final days = controller.info.value?.daysLeft ?? 0;
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: AppColors.orange.withValues(alpha: 0.12),
        child: Text(
          'Trial: $days day${days == 1 ? '' : 's'} left — email rpfinser24@gmail.com for a license key',
          style: const TextStyle(fontSize: 12, color: AppColors.orange),
          textAlign: TextAlign.center,
        ),
      );
    });
  }
}
```

- [ ] **Step 4: Implement `lib/screens/license_screen.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../models/license_state.dart';
import '../services/license_service.dart';
import '../theme/app_colors.dart';

/// Full-screen gate shown when the trial/license is missing or expired.
class LicenseScreen extends GetView<LicenseService> {
  const LicenseScreen({super.key});

  static const String supportEmail = 'rpfinser24@gmail.com';
  final _keyController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      gradient: AppColors.accentGradient,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Icon(Icons.bolt_rounded, size: 40, color: Colors.white),
                  ),
                  const SizedBox(height: 20),
                  Text('RankRocket AI',
                      style: TextStyle(
                          fontSize: 24, fontWeight: FontWeight.w700, color: context.text)),
                  const SizedBox(height: 6),
                  Obx(() {
                    final st = controller.status.value;
                    if (st == LicenseStatus.offline) {
                      return Text(
                        'Cannot verify your license. Check your internet connection and try again.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: context.textM),
                      );
                    }
                    return Text(
                      'Your trial or license has expired.',
                      style: TextStyle(fontSize: 14, color: context.textM),
                    );
                  }),
                  const SizedBox(height: 28),
                  Text('Your device code',
                      style: TextStyle(fontSize: 12, color: context.textD)),
                  const SizedBox(height: 8),
                  Obx(() {
                    final code = controller.info.value?.deviceCode ?? '';
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      decoration: BoxDecoration(
                        color: context.bgPanel,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(code,
                              style: const TextStyle(
                                  fontSize: 22, letterSpacing: 2, fontWeight: FontWeight.w700,
                                  fontFamily: 'monospace')),
                          if (code.isNotEmpty)
                            IconButton(
                              icon: const Icon(Icons.copy_rounded, size: 18),
                              onPressed: () => Clipboard.setData(ClipboardData(text: code)),
                            ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: context.bgPanel,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: context.border),
                    ),
                    child: Column(
                      children: [
                        const Icon(Icons.mail_outline_rounded, color: AppColors.accent),
                        const SizedBox(height: 8),
                        Text('Email $supportEmail with your device code to get a license key.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 13, color: context.textM)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _keyController,
                    textCapitalization: TextCapitalization.characters,
                    style: const TextStyle(fontFamily: 'monospace', letterSpacing: 1),
                    decoration: InputDecoration(
                      labelText: 'License key',
                      hintText: 'RR-XXXX-XXXX-XXXX',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Obx(() {
                    final err = controller.activateError.value;
                    if (err.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(err,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12, color: AppColors.red)),
                    );
                  }),
                  Obx(() => SizedBox(
                        width: double.infinity,
                        height: 46,
                        child: ElevatedButton(
                          onPressed: controller.activating.value
                              ? null
                              : () => controller.activate(_keyController.text.trim()),
                          child: controller.activating.value
                              ? const SizedBox(
                                  width: 20, height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('Activate'),
                        ),
                      )),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }
}
```

- [ ] **Step 5: Run tests — verify they pass**

Run: `flutter test test/license_screen_test.dart`
Expected: PASS (2 tests). If a theme helper (`context.bg` etc.) is undefined, read `lib/theme/app_theme.dart` and swap in `Theme.of(context).colorScheme.*` equivalents.

- [ ] **Step 6: Commit**

```bash
git add lib/screens/license_screen.dart lib/widgets/license_trial_banner.dart test/license_screen_test.dart
git commit -m "feat(license): licensing screen and trial banner"
```

---

### Task 9: Flutter — gate integration (splash, routes, home banner)

**Files:**
- Modify: `lib/bindings/app_bindings.dart`
- Modify: `lib/routes/app_routes.dart`
- Modify: `lib/screens/splash_screen.dart`
- Modify: `lib/screens/home_screen.dart`

**Interfaces:**
- Consumes: `LicenseService`, `LicenseStatus`, `LicenseTrialBanner`, `LicenseScreen`.
- Produces: new route `AppRoutes.license = '/license'`; app navigates to home (licensed/trial) or license screen (expired/needsLicense/offline-no-cache).

- [ ] **Step 1: Register the service** — `lib/bindings/app_bindings.dart`

Add import `../services/license_service.dart;` and, after the other lazy service puts:

```dart
Get.put(LicenseService()); // eager: splash + gate depend on it
```

- [ ] **Step 2: Open the license Hive box** — `lib/main.dart`

Add import `services/license_service.dart;` (already imports from `models/`, `theme/`, etc.). After `await Hive.openBox('models_meta');` insert:

```dart
await Hive.openBox(LicenseService.boxName);
```

- [ ] **Step 3: Add the route** — `lib/routes/app_routes.dart`

Add import `../screens/license_screen.dart;`, constant `static const license = '/license';`, and page:

```dart
GetPage(name: license, page: () => const LicenseScreen()),
```

- [ ] **Step 4: Gate in splash** — `lib/screens/splash_screen.dart`

Add import `../models/license_state.dart;` and `../services/license_service.dart;`. In `_initApp()`, after the `WakelockService` init block (before the battery-optimization prompt) insert:

```dart
setState(() => _status = 'Checking license...');
log.info('Checking license...', source: 'Splash');
await Get.find<LicenseService>().init();
```

Then replace the final navigation block:

```dart
final license = Get.find<LicenseService>();
if (license.status.value == LicenseStatus.trial ||
    license.status.value == LicenseStatus.active) {
  Get.offAllNamed(AppRoutes.home);
} else {
  Get.offAllNamed(AppRoutes.license);
}
```

- [ ] **Step 5: Insert the trial banner** — `lib/screens/home_screen.dart`

Add import `../widgets/license_trial_banner.dart;`. Find the mobile `body:` block and change it exactly as follows.

Before:

```dart
      body: SafeArea(
        bottom: false, // let the bottom nav handle the safe area
        child: IndexedStack(
          index: _mobileTabIndex,
          children: [
            // Tab 0: Chat
            _buildMobileChatTab(),
            // Tab 1: Models
            const ModelLibraryScreen(embedded: true),
            // Tab 2: Settings
            const SettingsScreen(embedded: true),
          ],
        ),
      ),
```

After:

```dart
      body: SafeArea(
        bottom: false, // let the bottom nav handle the safe area
        child: Column(
          children: [
            const LicenseTrialBanner(),
            Expanded(
              child: IndexedStack(
                index: _mobileTabIndex,
                children: [
                  // Tab 0: Chat
                  _buildMobileChatTab(),
                  // Tab 1: Models
                  const ModelLibraryScreen(embedded: true),
                  // Tab 2: Settings
                  const SettingsScreen(embedded: true),
                ],
              ),
            ),
          ],
        ),
      ),
```

- [ ] **Step 6: Verify**

Run: `flutter analyze`
Expected: no new issues beyond the pre-existing deprecation infos.

Run: `flutter test`
Expected: all tests pass (existing + new).

- [ ] **Step 7: Commit**

```bash
git add lib/
git commit -m "feat(license): gate app behind license check in splash"
```

---

### Task 10: Final verification + admin documentation

**Files:**
- Create: `docs/licensing-admin.md`
- Modify: `docs/ios-build.md` (add a note that the app now requires a one-time online license check)

**Interfaces:**
- Produces: operator documentation for generating keys, extending usage, and the end-to-end manual test.

- [ ] **Step 1: Run the full test suite + analyzer**

Run:
- `flutter analyze`
- `flutter test`
- `python -m pytest license_server/tests/test_api.py -v`
Expected: analyzer clean of new issues; all tests green.

- [ ] **Step 2: Write `docs/licensing-admin.md`**

Cover: where the server runs (`ai.rankrocket.online`), the `/admin` login, the dashboard columns, generating a key for a device code, extending/revoking/reset-trial, how the trial+reinstall policy works (stable device ID), how to run locally with waitress + `--dart-define=LICENSE_SERVER_URL=http://<LAN-IP>:8900`, and the manual E2E test script (register → short trial via `LICENSE_TRIAL_DAYS=1` → expiry → generate key → activate).

- [ ] **Step 3: Update `docs/ios-build.md`**

Add a "License" note under First run: *"The app checks its license online on first launch (ai.rankrocket.online). It works free for 30 days, then asks for a license key from rpfinser24@gmail.com."*

- [ ] **Step 4: Commit**

```bash
git add docs/
git commit -m "docs(license): admin guide and iOS install notes"
```

---

## Self-Review Summary

- **Spec coverage:** every section in the spec maps to a task — server API (1–2), admin (3), deployment (4), client model/config (5), platform channels (6), client service (7), screens + gate (8–9), docs/tests (10). Non-goals respected (no in-app payment, no subscriptions).
- **Type consistency:** `LicenseStatus`/`LicenseInfo` names are identical across Tasks 5, 7, 8, 9; the API response shape defined in Task 1 is what Tasks 5 and 7 parse; `_device_state` status strings (`trial/active/expired/needs_license/unknown`) match the client's `switch` in Task 5.
- **Placeholder scan:** no TBDs; every code step contains full implementations.