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

    # Re-register (reinstall) â€” trial must NOT restart; same expiry.
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


def _activate(client, device_id, key):
    return client.post("/api/v1/activate", json={"device_id": device_id, "license_key": key})


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


def _login(client, password="change-me"):
    return client.post("/admin/login", data={"password": password}, follow_redirects=False)


def test_admin_login_and_dashboard(client):
    _register(client, "dev-999")
    res = _login(client)
    assert res.status_code == 302
    page = client.get("/admin")
    assert page.status_code == 200
    assert b"Generate license key" in page.data
    assert b'<form method="post"' in page.data
    assert b"<table>" in page.data


def test_admin_requires_login(client):
    res = client.get("/admin")
    assert res.status_code == 302
    assert "/admin/login" in res.headers["Location"]


def test_admin_login_page_renders_form(client):
    page = client.get("/admin/login")
    assert page.status_code == 200
    assert b'<form method="post">' in page.data


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
    assert b'<p class="key">' in res.data
    assert key.encode() in res.data
    act = client.post("/api/v1/activate", json={"device_id": "dev-555", "license_key": key})
    assert act.status_code == 200


def test_admin_dashboard_escapes_device_fields(client):
    _register(client, "dev-esc", model="<script>alert(1)</script>", platform='p"><img src=x onerror=alert(1)>')
    _login(client)
    page = client.get("/admin")
    assert page.status_code == 200
    assert b"<script>alert(1)</script>" not in page.data
    assert b"&lt;script&gt;alert(1)&lt;/script&gt;" in page.data
    assert b'<img src=x onerror=alert(1)>' not in page.data
    assert b"&lt;img src=x onerror=alert(1)&gt;" in page.data


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