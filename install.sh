#!/usr/bin/env bash
set -euo pipefail

# install.sh - installs the CEC Scheduler into a directory and registers a systemd service
# Usage:
#   sudo bash install.sh [--install-dir /opt/cec-scheduler] [--service-user pi] [--config /path/to/cec_schedule.yaml] [--no-start]

INSTALL_DIR=/opt/cec-scheduler
SERVICE_USER=$(whoami)
CONFIG_SRC=""
START_SERVICE=1
SERVICE_NAME=cec-scheduler
SERVICE_TEMPLATE_FILE=cec-scheduler.service

print_usage(){
  cat <<EOF
Usage: sudo bash install.sh [--install-dir DIR] [--service-user USER] [--config FILE] [--no-start]

Defaults:
  --install-dir: /opt/cec-scheduler
  --service-user: current user ($SERVICE_USER)
  --config: uses repository's example config if not provided
  --no-start: do not start/enable the service immediately

Example:
  sudo bash install.sh --install-dir /opt/cec-scheduler --service-user pi --config ./cec_schedule.yaml
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      INSTALL_DIR="$2"; shift 2;;
    --service-user)
      SERVICE_USER="$2"; shift 2;;
    --config)
      CONFIG_SRC="$2"; shift 2;;
    --no-start)
      START_SERVICE=0; shift 1;;
    -h|--help)
      print_usage; exit 0;;
    *)
      echo "Unknown arg: $1"; print_usage; exit 2;;
  esac
done

# Must be run as root for copying to /opt and writing to /etc/systemd/system
if [[ $EUID -ne 0 ]]; then
  echo "This installer must be run as root. Use sudo."
  exit 1
fi

# Check systemctl
if ! command -v systemctl >/dev/null 2>&1; then
  echo "systemctl not found. This installer requires systemd."
  exit 1
fi

echo "Installing CEC Scheduler to: $INSTALL_DIR"

# Create install dir
mkdir -p "$INSTALL_DIR"

# Copy python script
cp -v cec_scheduler.py "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/cec_scheduler.py"

# Copy config
if [[ -n "$CONFIG_SRC" ]]; then
  if [[ ! -f "$CONFIG_SRC" ]]; then
    echo "Config file '$CONFIG_SRC' not found."; exit 1
  fi
  cp -v "$CONFIG_SRC" "$INSTALL_DIR/cec_schedule.yaml"
else
  if [[ -f "cec_schedule.example.yaml" ]]; then
    cp -v cec_schedule.example.yaml "$INSTALL_DIR/cec_schedule.yaml"
  else
    echo "No example config found in repository and no --config provided."; exit 1
  fi
fi

# Copy requirements (optional)
if [[ -f requirements.txt ]]; then
  cp -v requirements.txt "$INSTALL_DIR/"
fi

# Prepare systemd service file (from template in repo)
if [[ ! -f "$SERVICE_TEMPLATE_FILE" ]]; then
  echo "Service template '$SERVICE_TEMPLATE_FILE' not found in repo."
  exit 1
fi

SERVICE_DEST=/etc/systemd/system/${SERVICE_NAME}.service

# Backup existing unit if present
if [[ -f "$SERVICE_DEST" ]]; then
  echo "Backing up existing unit to ${SERVICE_DEST}.bak"
  cp -v "$SERVICE_DEST" "${SERVICE_DEST}.bak"
fi

# Replace placeholders and write
sed -e "s|{{INSTALL_DIR}}|$INSTALL_DIR|g" -e "s|{{SERVICE_USER}}|$SERVICE_USER|g" "$SERVICE_TEMPLATE_FILE" > "$SERVICE_DEST"
chmod 644 "$SERVICE_DEST"

# Reload systemd and enable/start
systemctl daemon-reload
if [[ $START_SERVICE -eq 1 ]]; then
  systemctl enable --now "$SERVICE_NAME".service
  echo "Service enabled and started: $SERVICE_NAME"
else
  systemctl enable "$SERVICE_NAME".service
  echo "Service installed and enabled (not started): $SERVICE_NAME"
fi

cat <<EOF
Installation complete.
- Installed files to: $INSTALL_DIR
- Config: $INSTALL_DIR/cec_schedule.yaml
- To view logs: sudo journalctl -u $SERVICE_NAME -f
If you need to change the config, edit the file and restart:
  sudo systemctl restart $SERVICE_NAME
EOF
