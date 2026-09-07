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
