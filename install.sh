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

# Dependency installation defaults
INSTALL_DEPS=1
VENV_DIR=""  # if set, deps will be installed into this venv and the service will use its python
PYTHON_BIN="/usr/bin/python3"

# Default venv will be created at $INSTALL_DIR/venv if not explicitly provided and deps are being installed
# This is applied after parsing CLI args so it respects a custom --install-dir
DEFAULT_VENV_SUBDIR="venv"

print_usage(){
  cat <<EOF
Usage: sudo bash install.sh [--install-dir DIR] [--service-user USER] [--config FILE] [--no-start] [--no-deps] [--venv VENV_DIR]

Defaults:
  --install-dir: /opt/cec-scheduler
  --service-user: current user ($SERVICE_USER)
  --config: uses repository's example config if not provided
  --no-start: do not start/enable the service immediately
  --no-deps: do not install Python dependencies (skip pip install)
  --venv: path to a virtualenv where dependencies will be installed; default is INSTALL_DIR/venv (created automatically)

Examples:
  sudo bash install.sh --install-dir /opt/cec-scheduler --service-user pi --config ./cec_schedule.yaml
  sudo bash install.sh --venv /opt/cec-scheduler/venv
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
    --no-deps)
      INSTALL_DEPS=0; shift 1;;
    --venv)
      VENV_DIR="$2"; shift 2;;
    -h|--help)
      print_usage; exit 0;;
    *)
      echo "Unknown arg: $1"; print_usage; exit 2;;
  esac
done

# If a venv path wasn't supplied and deps are enabled, default to INSTALL_DIR/venv
if [[ -z "$VENV_DIR" && $INSTALL_DEPS -eq 1 ]]; then
  VENV_DIR="$INSTALL_DIR/$DEFAULT_VENV_SUBDIR"
fi


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

# Install OS package dependencies (cec-utils) unless disabled via --no-deps
if [[ $INSTALL_DEPS -eq 1 ]]; then
  if command -v apt-get >/dev/null 2>&1; then
    if dpkg -s cec-utils >/dev/null 2>&1; then
      echo "CEC package 'cec-utils' already installed"
    else
      echo "Installing OS package dependency: cec-utils"
      # Non-interactive install
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y cec-utils
    fi
  else
    echo "apt-get not found; skipping installation of 'cec-utils'"
  fi
else
  echo "Skipping installation of OS package dependency 'cec-utils' (--no-deps)"
fi

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

# Install Python dependencies unless requested not to
if [[ $INSTALL_DEPS -eq 1 && -f "$INSTALL_DIR/requirements.txt" ]]; then
  echo "Installing Python dependencies..."
  if [[ -n "$VENV_DIR" ]]; then
    # Create venv if needed
    if [[ ! -d "$VENV_DIR" ]]; then
      echo "Creating virtualenv at $VENV_DIR"
      if ! command -v python3 >/dev/null 2>&1; then
        echo "python3 not found. Cannot create virtualenv."; exit 1
      fi
      python3 -m venv "$VENV_DIR"
    fi
    # Ensure the venv is owned by the service user so it can access/update if needed
    chown -R "$SERVICE_USER":"$SERVICE_USER" "$VENV_DIR"
    PYTHON_BIN="$VENV_DIR/bin/python"
    echo "Using venv python: $PYTHON_BIN"
    "$PYTHON_BIN" -m pip install -U pip
    "$PYTHON_BIN" -m pip install -r "$INSTALL_DIR/requirements.txt"
  else
    if ! command -v python3 >/dev/null 2>&1; then
      echo "python3 not found. Cannot install dependencies."; exit 1
    fi
    PYTHON_BIN=$(command -v python3)
    echo "Using system python: $PYTHON_BIN"
    "$PYTHON_BIN" -m pip install -r "$INSTALL_DIR/requirements.txt"
  fi
else
  echo "Skipping Python dependency installation."
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
sed -e "s|{{INSTALL_DIR}}|$INSTALL_DIR|g" -e "s|{{SERVICE_USER}}|$SERVICE_USER|g" -e "s|{{PYTHON_BIN}}|$PYTHON_BIN|g" "$SERVICE_TEMPLATE_FILE" > "$SERVICE_DEST"
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
