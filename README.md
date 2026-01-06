# CEC Scheduler 🔧

Schedule CEC commands (via the `cec-client` binary) to run at specific times of day.

---

## Quick start 💡

1. Install dependencies:

```bash
pip install -r requirements.txt
```

2. Copy `cec_schedule.example.yaml` to `cec_schedule.yaml` and edit it to match your device and desired times.

3. Test (dry-run):

```bash
python3 cec_scheduler.py --config cec_schedule.yaml --dry-run
```

4. Run for real:

```bash
python3 cec_scheduler.py --config cec_schedule.yaml
```

---

## Configuration format
See `cec_schedule.example.yaml` for examples. Key fields:

- `device` — logical device address (e.g. `0`)
- `cec_client_path` — optional path to the `cec-client` binary
- `commands` — list of commands with `time`, `command`, optional `days` and optional `name`

Time format: `HH:MM` or `HH:MM:SS`.

Note: scheduled times in the YAML are interpreted in the system's local timezone (not UTC).

Days: `mon,tue,wed,thu,fri,sat,sun` — omit to run every day.

Commands: either a single `command` string (legacy) or `commands` as a list of strings. Common values are `on` and `standby`. You may also pass raw `tx` pairs like `tx 40:44:41:00`. Example: `commands: ['standby', 'tx 40:44:41:00']` will run both commands in order.

---

## Installer script & systemd unit 🔧

An installer script `install.sh` and an example systemd unit `cec-scheduler.service` are included.

Quick install (installs to `/opt/cec-scheduler` by default):

```bash
# run as root
sudo bash install.sh --install-dir /opt/cec-scheduler --service-user pi
```

Options:
- `--install-dir DIR` (default: `/opt/cec-scheduler`) — where files are copied
- `--service-user USER` (default: current user) — which user the unit will run as
- `--config FILE` — path to an existing YAML config to install; otherwise the example config is copied
- `--no-start` — install and enable the unit but do not start it immediately

The installer does:
- copies `cec_scheduler.py` and the config to the install dir
- installs the systemd unit at `/etc/systemd/system/cec-scheduler.service` from the included template
- runs `systemctl daemon-reload` and `systemctl enable --now cec-scheduler.service` (unless `--no-start`)

You can inspect the example unit in `cec-scheduler.service` — replace `{{INSTALL_DIR}}` and `{{SERVICE_USER}}` if you edit it manually.

Logs:
- View logs with: `sudo journalctl -u cec-scheduler -f`
