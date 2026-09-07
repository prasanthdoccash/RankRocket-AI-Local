# RankRocket AI License Server

A small Flask server that issues and manages device-bound licenses for the RankRocket
local-AI app. It runs locally (Windows, waitress) for development and is deployed to
the Ganga VPS behind nginx at `https://ai.rankrocket.online`.

## Layout

- `app.py` — Flask app: `/register`, `/status`, `/activate`, `/admin` (+ generate/extend/revoke/reset)
- `tests/` — pytest suite (`conftest.py` sets up a temp DB)
- `deploy.sh` — one-shot VPS deploy (rsync + venv + systemd restart)
- `license.service` — systemd unit (gunicorn on `127.0.0.1:8900`)
- `nginx-ai.conf.example` — nginx server block for `ai.rankrocket.online`

## Local run (Windows)

```powershell
cd license_server
python -m venv .venv
.venv\Scripts\pip install -r requirements.txt
$env:LICENSE_ADMIN_PASSWORD = "change-me-strong-password"
$env:LICENSE_SECRET_KEY = "change-me-random-session-secret"
python app.py
```

The server prints `License server on http://0.0.0.0:8900` and serves via waitress on
`http://localhost:8900`. The port comes from `LICENSE_PORT` (default `8900`).

> Env vars: the app reads everything from the process environment (no dotenv loader),
> so set them in your shell before running `python app.py`. `.env.example` lists the
> supported variables and is the template for the server-side `/opt/license_server/.env`
> file (which gunicorn loads via `EnvironmentFile` in `license.service`).
> `LICENSE_ADMIN_PASSWORD` and `LICENSE_SECRET_KEY` are required for a real deployment.
> If `LICENSE_SECRET_KEY` is unset the server falls back to a randomly generated
> session key at startup, so sessions reset on every restart — fine for dev only.

## Testing

From the `license_server/` directory:

```bash
python -m pytest tests/ -v
```

Or from the project root:

```bash
python -m pytest license_server/tests/ -v
```

## VPS deploy

Prerequisites on the VPS:

- The `Ganga-ssh` SSH alias configured in `~/.ssh/config`.
- An `/opt/license_server/.env` created manually once with at least:

```bash
LICENSE_ADMIN_PASSWORD=change-me-strong-password
LICENSE_SECRET_KEY=change-me-random-session-secret
```

Then run:

```bash
./deploy.sh
```

`deploy.sh` rsyncs `license_server/` to `/opt/license_server` (excluding `.env`,
`license.db`, and `__pycache__`), creates/updates the `.venv` and installs
`requirements.txt`, then copies `license.service` into systemd, enables it, restarts it,
and prints `active`. The service runs gunicorn (`-w 2 -b 127.0.0.1:8900 app:app`).

## nginx

On the VPS, expose the service at `https://ai.rankrocket.online`:

```bash
sudo cp nginx-ai.conf.example /etc/nginx/sites-available/ai.rankrocket.online
sudo ln -s /etc/nginx/sites-available/ai.rankrocket.online /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
sudo certbot --nginx -d ai.rankrocket.online
```

## Admin workflow

Browse to `https://ai.rankrocket.online/admin` (or `http://localhost:8900/admin`
locally) and log in with `LICENSE_ADMIN_PASSWORD`. From the dashboard you can:

- See all registered devices (status, trial/activated/expired state).
- Generate a device-bound license key for a specific device code.
- Extend an activation, revoke a device, or reset a device's trial.

How the device-bound flow works (register → activate with a device-specific key) and
the full admin walkthrough are documented in the Flutter repo:
`docs/licensing-admin.md`.

## Security notes

- `LICENSE_SECRET_KEY` and `LICENSE_ADMIN_PASSWORD` are required in `/opt/license_server/.env`.
- If `LICENSE_SECRET_KEY` is unset the server generates a random session key at startup
  (sessions won't survive restarts).
- `deploy.sh` excludes `.env` and `license.db` from rsync so server state is never
  overwritten by a deploy.
