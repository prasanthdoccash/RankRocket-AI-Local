# RankRocket AI — License Admin Guide

Operator documentation for the RankRocket AI licensing system: how the license
server runs, how to manage devices and keys from the admin panel, how the trial
+ reinstall policy works, how to run it locally, and the end-to-end manual test.

## How it works (short version)

- Every install gets a **30-day free trial** from first launch.
- **Reinstalls do NOT restart the trial.** The trial is granted **server-side**,
  keyed to a **stable device ID** that survives uninstall (Android
  `Settings.Secure.ANDROID_ID` / iOS Keychain-persisted UUID). On first launch
  the app registers with the server and the server decides the state.
- After the trial (or a license) expires, the app shows a licensing screen that
  asks the user to email their **device code** to **rpfinser24@gmail.com** to
  get a license key.
- The developer generates **device-bound** license keys from the admin panel.
  A key only works on the one device it was issued for.

## Server

- **Production URL:** `https://ai.rankrocket.online`
- **Admin panel:** `https://ai.rankrocket.online/admin` (password from
  `LICENSE_ADMIN_PASSWORD`).
- The Flask server reads all config from the process environment
  (`LICENSE_ADMIN_PASSWORD`, `LICENSE_SECRET_KEY`, `LICENSE_TRIAL_DAYS`,
  `LICENSE_PORT`, `LICENSE_DB`). There is no dotenv loader in `app.py`; the
  systemd unit loads `/opt/license_server/.env` via `EnvironmentFile`.

## Admin panel

Browse to `https://ai.rankrocket.online/admin` and log in with the admin
password.

### Dashboard

A table of every registered device, newest first, with columns:

- **Code** — the 8-character device code the user sees in the app and emails you.
- **Platform** — `android` / `ios`.
- **Model** — device model string.
- **Version** — the app version that last registered.
- **Status** — `trial` / `active` / `expired` / `needs_license`.
- **Expires** — the effective expiry (trial end **or** license expiry),
  whichever applies.
- **First seen / Last seen** — registration and last-activity dates.
- **Actions** — per-device **Extend**, **Revoke**, and **Reset trial** buttons.

### Generate a license key

1. Get the user's **device code** (they read it from the app's licensing screen,
   or you find it in the dashboard).
2. In the **Generate license key** box type the device code, the **duration in
   days** (default `365`), and optional notes (e.g. a payment id).
3. Click **Generate key**. A one-time key page shows the key in the format
   **`RR-XXXX-XXXX-XXXX`** and says it activates **only on that device code**.
   Email this key to the user.
4. The key is bound to that device. It is shown **once**; if you lose it,
   generate a new one.

### Extend / Revoke / Reset trial

- **Extend** — adds the given number of days to a device's effective expiry.
  Days are stacked on top of the later of the current license expiry, trial
  end, or now, so extending always pushes the expiry forward.
- **Revoke** — clears the device's license (`license_expires_at = NULL`). The
  device is forced back to `needs_license` (or its trial, if still running).
- **Reset trial** — clears `trial_used` and `trial_started_at`. Note that this
  does **not** grant a fresh trial on reinstall: `register` grants trials only
  on first registration, so the device returns to the `needs_license` state.
  Use only for support edge cases.

## Trial + reinstall policy

- Trial is **30 days** (`LICENSE_TRIAL_DAYS`, default `30`) from first launch,
  granted server-side on registration.
- Because the trial is tied to a **stable device ID**, uninstalling and
  reinstalling the app does **not** reset the trial. The server still sees the
  device already used its trial and refuses a new one — the app goes straight
  to the license screen.
- First launch requires a working server connection (the trial cannot start
  offline).

## Running locally (Windows)

```powershell
cd license_server
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt
$env:LICENSE_ADMIN_PASSWORD = "change-me-strong-password"
$env:LICENSE_SECRET_KEY = "change-me-random-session-secret"
$env:LICENSE_TRIAL_DAYS = "30"
$env:LICENSE_PORT = "8900"
python app.py
```

The server prints `License server on http://0.0.0.0:8900` and serves via
waitress on `http://localhost:8900`. The admin panel is then at
`http://localhost:8900/admin`.

To point a device/emulator at your local server instead of production, run the
Flutter app with:

```bash
flutter run --dart-define=LICENSE_SERVER_URL=http://<LAN-IP>:8900
```

> `LICENSE_ADMIN_PASSWORD` and `LICENSE_SECRET_KEY` are required for real use.
> If `LICENSE_SECRET_KEY` is unset, the server generates a **random session key
> at startup** — sessions won't survive a restart, fine for dev only.

## Deploying to the VPS

1. Create `/opt/license_server/.env` on the VPS once (never committed) with at
   least:
   ```bash
   LICENSE_ADMIN_PASSWORD=change-me-strong-password
   LICENSE_SECRET_KEY=change-me-random-session-secret
   ```
2. From `license_server/`, run:
   ```bash
   ./deploy.sh
   ```
   `deploy.sh` uses the `Ganga-ssh` SSH alias. It rsyncs `license_server/` to
   `/opt/license_server` (excluding `.env`, `license.db`, `__pycache__`),
   creates/updates the venv and installs requirements, then installs and
   restarts the systemd unit `license.service` and prints its active state.
3. The systemd unit runs gunicorn on `127.0.0.1:8900`, loading
   `/opt/license_server/.env` via `EnvironmentFile`.
4. nginx serves `https://ai.rankrocket.online` → `127.0.0.1:8900` (see
   `license_server/nginx-ai.conf.example`); TLS via certbot:
   ```bash
   sudo cp nginx-ai.conf.example /etc/nginx/sites-available/ai.rankrocket.online
   sudo ln -s /etc/nginx/sites-available/ai.rankrocket.online /etc/nginx/sites-enabled/
   sudo nginx -t
   sudo systemctl reload nginx
   sudo certbot --nginx -d ai.rankrocket.online
   ```

## Security notes

- `LICENSE_ADMIN_PASSWORD` and `LICENSE_SECRET_KEY` are required in `.env`.
- If the secret is unset, the server generates a random session key at startup
  (sessions reset on restart — dev only).
- License keys are generated with Python's `secrets`, are device-bound, and are
  shown once. Activating a key already bound to another device is rejected.
- `/api/v1/activate` is throttled per-IP (~10 attempts / minute).
- `.env` and `license.db` are excluded from rsync, so server state is never
  overwritten by a deploy.

## End-to-end manual test

1. Run the server locally and shorten the trial:
   ```powershell
   $env:LICENSE_TRIAL_DAYS = "1"
   $env:LICENSE_ADMIN_PASSWORD = "test-password"
   $env:LICENSE_SECRET_KEY = "test-secret"
   cd license_server; python app.py
   ```
2. Get your PC's LAN IP (e.g. `ipconfig` → IPv4) and run the app on an emulator:
   ```bash
   flutter run --dart-define=LICENSE_SERVER_URL=http://<LAN-IP>:8900
   ```
3. On first launch the app registers → **trial** starts (1 day). Verify the
   "Trial: N days left" banner and the device code.
4. Set `LICENSE_TRIAL_DAYS` back to `0` (or edit the device's expiry) and relaunch
   to force **expiry** → the licensing screen appears.
5. Open `http://localhost:8900/admin`, log in, find the device, and **Generate
   key** using its device code.
6. Type the key into the app and tap **Activate** → status becomes **active** and
   the app unlocks.
7. (Optional) Test reinstall policy: uninstall/reinstall, same device ID → the
   app should immediately show the licensing screen with no new trial.
