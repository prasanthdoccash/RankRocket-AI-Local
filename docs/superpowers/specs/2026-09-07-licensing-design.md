# RankRocket AI — Licensing System Design

**Date:** 2026-09-07
**Status:** Approved (design)
**Server:** https://ai.rankrocket.online

## 1. Overview

Add a licensing system to the RankRocket AI (Uncensored Local AI) Flutter app so that:

- Every install gets a **30-day free trial** from first launch.
- **Reinstalls do not restart the trial** — enforced server-side using a stable
  device ID that survives app uninstall.
- After expiry (trial or license) the app shows a licensing screen asking the
  user to obtain a license from **rpfinser24@gmail.com**.
- The developer manages everything from a password-protected **admin panel** on
  the server: see every registered phone, generate **device-bound license keys**,
  and **extend usage**.
- The feature applies to **both Android and iOS** through the shared Flutter
  codebase (one implementation, two platforms).

## 2. Architecture

```
Flutter app (Android/iOS)                    Developer PC (browser)
        │  HTTPS                                  │
        ▼                                         ▼
   https://ai.rankrocket.online        https://ai.rankrocket.online/admin
        │                                         │
        ▼                                         ▼
   nginx (TLS) ──► gunicorn ──► Flask license_server ──► SQLite (license.db)
```

- Client calls public JSON API (`/api/v1/...`).
- Developer uses session-authenticated web admin (`/admin`).
- Single SQLite database, auto-created on first run.

## 3. Components

### 3.1 License Server (`license_server/`)

Standalone Flask app, no relation to RankRocket `app.py`.

```
license_server/
  app.py
  requirements.txt          # Flask, gunicorn, waitress
  .env.example              # committed template
  .env                      # runtime secrets (gitignored)
  license.db                # runtime (gitignored)
  tests/test_api.py         # pytest
  deploy.sh                 # scp + systemd restart (VPS)
  license.service           # systemd unit template
```

**Config (env vars):**

| Var | Purpose |
|-----|---------|
| `LICENSE_ADMIN_PASSWORD` | Password for `/admin` |
| `LICENSE_SECRET_KEY` | Flask session signing key |
| `LICENSE_TRIAL_DAYS` | Default `30` |
| `LICENSE_PORT` | Gunicorn/waitress port (default `8900`) |

**Database schema:**

```
devices
  id            INTEGER PK
  device_id     TEXT UNIQUE     -- stable ID (ANDROID_ID / Keychain UUID)
  device_code   TEXT UNIQUE     -- short human-friendly code shown to user
  platform      TEXT            -- android | ios
  model         TEXT
  os_version    TEXT
  app_version   TEXT
  first_seen    TEXT (ISO)
  last_seen     TEXT (ISO)
  trial_started_at  TEXT
  trial_used    INTEGER (0/1)
  license_expires_at TEXT NULL
  notes         TEXT

licenses
  id            INTEGER PK
  license_key   TEXT UNIQUE     -- RR-XXXX-XXXX-XXXX
  device_id     TEXT            -- bound device
  issued_at     TEXT
  expires_at    TEXT
  duration_days INTEGER
  notes         TEXT
```

**License key format:** `RR-XXXX-XXXX-XXXX`, uppercase alphanumeric, generated
with `secrets`. Keys are **device-bound**: on `activate`, an unbound key binds to
the device that first presents it; a key already bound to another device is
rejected.

**Device code format:** 8-character uppercase alphanumeric code (e.g.
`RR2F9K4Q`), generated with `secrets` at first registration and stored on the
`devices` row. It is displayed in the app's licensing screen so the user can
email it to rpfinser24@gmail.com, and it is what the developer types into the
admin panel to generate a key for that device.

**Public API:**

| Endpoint | Purpose |
|----------|---------|
| `GET /api/v1/status?device_id=` | Returns current state (trial/active/expired/needs_license/unknown), `device_code`, `expires_at`, `days_left`, server `message` |
| `POST /api/v1/register` | Body `{device_id, platform, model, os_version, app_version}`. New device → grants trial (30 days, `trial_used=0`). Existing device with `trial_used=1` and no license → `needs_license` (reinstall = no new trial). Updates `last_seen`/`app_version`. |
| `POST /api/v1/activate` | Body `{device_id, license_key}`. Validates + binds key. Returns `active` + `expires_at` on success, friendly errors otherwise. |

**Admin (Flask session, password from env):**

| Route | Purpose |
|-------|---------|
| `GET /admin/login`, `POST /admin/login`, `GET /admin/logout` | Auth |
| `GET /admin` | Dashboard — table of every device: code, model, platform, app version, first/last seen, status, expiry, actions |
| `POST /admin/generate-key` | `{device_code, duration_days, notes}` → creates device-bound key, **displays it once** to copy/email to the user |
| `POST /admin/device/<id>/extend` | `{days}` → adds days to `license_expires_at` |
| `POST /admin/device/<id>/revoke` | Clears license → forces `needs_license` |
| `POST /admin/device/<id>/reset-trial` | Resets `trial_used` (support edge case) |

### 3.2 Flutter Client

New/changed files (shared code = Android + iOS):

- `lib/config.dart` — `licenseServerUrl` from `String.fromEnvironment('LICENSE_SERVER_URL', defaultValue: 'https://ai.rankrocket.online')`.
- `lib/models/license_state.dart` — enum `LicenseStatus { loading, trial, active, expired, needsLicense, offline, serverError }` + `LicenseInfo` (status, deviceCode, expiresAt, daysLeft, message).
- `lib/services/license_service.dart` — GetX `GetxService`:
  - Hive box `license` caches `{device_id, device_code, status, expires_at}`.
  - `init()`: resolve stable device ID → load cache → call `GET /status` (8s timeout) → update cache/state. Unreachable server → fall back to cached state (see §5).
  - `activate(key)` → `POST /activate`.
- `lib/services/device_info_service.dart` — add `getStableDeviceId()`, `getDeviceModel()`, `getOsVersion()`, `getAppVersion()`, `getPlatform()` via the existing `rankrocket/device` method channel.
- `lib/screens/license_screen.dart` — full-screen gate:
  - Branding header.
  - **Device code** (large, monospace, copy button).
  - Instruction: *"Email rpfinser24@gmail.com with this code to get your license key."*
  - License key input + **Activate** button + error area.
  - Offline variant: *"Cannot verify license — check your internet connection."*
- `lib/screens/license_trial_banner.dart` — optional banner in home: *"Trial: N days left"*.

**Gate integration:** `main.dart` initializes `LicenseService` after Hive init
(with a startup timeout so a slow network never hangs the splash). Home route
checks status: `needsLicense`/`expired` → show `LicenseScreen`; `trial`/`active`
→ show home (plus trial banner).

### 3.3 Platform Channels (stable device ID)

Existing channel `rankrocket/device` (`getTotalRam`) is extended:

- **Android** (`android/app/src/main/kotlin/.../MainActivity.kt`):
  - `getStableDeviceId` → `Settings.Secure.ANDROID_ID` (survives app reinstall, resets only on factory reset).
  - `getDeviceModel` → `Build.MODEL`.
  - `getOsVersion` → `Build.VERSION.RELEASE`.
  - `getAppVersion` → `packageManager.getPackageInfo(...).versionName`.
- **iOS** (`ios/Runner/AppDelegate.swift`):
  - `getStableDeviceId` → UUID persisted in the **Keychain** via the Security framework (survives app uninstall); fallback `identifierForVendor`.
  - `getDeviceModel` → `UIDevice.current.model` (+ machine identifier).
  - `getOsVersion` → `UIDevice.current.systemVersion`.
  - `getAppVersion` → `Bundle.main` version.

### 3.4 Deployment

Follow the existing Stocks deploy pattern (AGENTS.md):

1. Ship `license_server/` to Ganga VPS at `/opt/license_server`, create venv,
   `pip install -r requirements.txt`.
2. `.env` with a strong `LICENSE_ADMIN_PASSWORD` and `LICENSE_SECRET_KEY`.
3. systemd unit `license.service` → gunicorn on `127.0.0.1:8900`.
4. nginx server block for `ai.rankrocket.online` → proxy to `127.0.0.1:8900`,
   certbot for TLS.
5. `deploy.sh` = rsync/scp + `systemctl restart license`.
6. Local Windows development/testing: run with waitress on `localhost:8900`,
   point the app at it via `--dart-define=LICENSE_SERVER_URL=http://<LAN-IP>:8900`.

## 4. Behavior Flows

| Scenario | Result |
|----------|--------|
| First launch, online | Register → **trial**, 30 days from `trial_started_at` |
| Reinstall, same device ID | Server sees `trial_used=1` → **needs_license** → `LicenseScreen` immediately |
| Trial expires | Next launch `status=expired` → `LicenseScreen` |
| User emails code → developer generates key → user activates | `active`, expiry from key duration |
| License expires | `status=expired` → `LicenseScreen` |
| Offline, cached license still valid | Allow app (offline grace) |
| Offline, no cache or expired | `LicenseScreen` with offline notice |

**First launch requires a server connection** (trial is granted server-side). This
is a deliberate consequence of the reinstall policy.

## 5. Error Handling

- Server timeouts (8s) → cached fallback.
- `activate` failures → human-readable messages (invalid key, key used on another device, server unreachable).
- Server unreachable on first launch → offline `LicenseScreen` (cannot start trial offline).
- All network paths wrapped so the app never hangs on the splash screen.

## 6. Security

- HTTPS only (nginx TLS).
- Admin password from env; Flask session cookies signed with `LICENSE_SECRET_KEY`.
- Keys generated with `secrets`, device-bound, shown once.
- `.env` gitignored; `.env.example` committed. No secrets in the repo.
- Simple in-memory throttle on `/activate` (per-IP, ~10/min).

## 7. Testing

**Server (pytest):**
- New device registers → trial granted with `trial_used=0`.
- Same `device_id` re-registers (reinstall) → `needs_license`, no new trial.
- Activate unbound key → binds to device, `active`.
- Activate key already bound to another device → rejected.
- Extend adds days; revoke forces `needs_license`.
- Status transitions trial → active → expired.

**Flutter:**
- Unit test: `LicenseService` JSON parsing + cache fallback with a mocked HTTP client.
- Widget test: `LicenseScreen` shows device code and activates a key.

**Manual E2E:** run server locally (waitress), run app on emulator with
`--dart-define=LICENSE_SERVER_URL=http://<LAN-IP>:8900`, verify
trial → expiry (temporarily shorten `LICENSE_TRIAL_DAYS`) → activate.

## 8. Non-Goals

- No in-app payment (manual email + admin-panel flow only).
- No subscriptions / auto-renewal.
- No analytics beyond device registration data.
- No App Store / TestFlight integration.
- No web build of the licensing screen.

## 9. Out of Scope (this spec)

The iOS cloud-build pipeline (deployment target 16.4, Podfile, ATS, icons,
`.github/workflows/build-ios-ipa.yml`, `docs/ios-build.md`) and the two new
`INDIAN LAW` catalog models were already implemented in a prior task and are
untouched by this design.