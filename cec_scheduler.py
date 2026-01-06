#!/usr/bin/env python3
"""cec_scheduler.py

Schedules CEC commands (via the `cec-client` binary) based on a YAML
configuration file.

Requirements:
  pip install pyyaml apscheduler

Usage:
  python3 cec_scheduler.py --config cec_schedule.yaml
  python3 cec_scheduler.py --config cec_schedule.yaml --dry-run

Config format (YAML):

device: 0
cec_client_path: /usr/bin/cec-client  # optional, default: cec-client
commands:
  - time: "15:00"
    command: "on"
  - time: "20:00"
    command: "standby"
    days: [mon,tue,wed,thu,fri]

Fields:
  - time: "HH:MM" or "HH:MM:SS"
  - command: string (e.g. on, standby, tx 44:41:...)
  - days: optional list of days (mon,tue,...,sun). If omitted, runs every day.

"""

from __future__ import annotations

import argparse
import logging
import signal
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Dict, List, Optional

import yaml
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger

# Optional systemd journal handler (if python-systemd is installed)
try:
    from systemd.journal import JournaldLogHandler  # type: ignore
except Exception:
    JournaldLogHandler = None  # type: ignore

# SysLogHandler is in the stdlib; used as a fallback
from logging.handlers import SysLogHandler

LOG = logging.getLogger("cec_scheduler")


@dataclass
class ScheduledCommand:
    time: str  # "HH:MM" or "HH:MM:SS"
    commands: List[str]
    days: Optional[List[str]] = None
    name: Optional[str] = None


def load_config(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    return cfg


def parse_time(t: str) -> tuple[int, int, int]:
    parts = t.split(":")
    if len(parts) not in (2, 3):
        raise ValueError(f"Invalid time format: {t}")
    h = int(parts[0])
    m = int(parts[1])
    s = int(parts[2]) if len(parts) == 3 else 0
    return h, m, s


def run_cec_client(cec_client_path: str, stdin_text: str, dry_run: bool = False) -> int:
    LOG.debug("Will run cec-client: %s; stdin: %s", cec_client_path, stdin_text.strip())
    if dry_run:
        print(f"DRY-RUN: {cec_client_path} -s -d 1 <<< {stdin_text!r}")
        return 0

    try:
        p = subprocess.run([cec_client_path, "-s", "-d", "1"], input=stdin_text, text=True, capture_output=True)
        LOG.debug("cec-client exited: %s", p.returncode)
        if p.stdout:
            LOG.debug("cec-client stdout: %s", p.stdout.strip())
        if p.stderr:
            LOG.debug("cec-client stderr: %s", p.stderr.strip())
        return p.returncode
    except FileNotFoundError:
        LOG.error("cec-client not found at %s", cec_client_path)
        return 127


def build_stdin_for_command(cmd: str, device: str) -> str:
    # Common short commands: 'on', 'standby'
    # If the command already contains the device, pass it through
    parts = cmd.strip().split()
    if parts[0] in ("on", "standby", "power") and len(parts) == 1:
        return f"{parts[0]} {device}\n"
    # allow 'tx 44:41:..' or any other cec-client input
    return cmd.strip() + "\n"


def schedule_commands(scheduler: BackgroundScheduler, cfg: Dict[str, Any], dry_run: bool = False):
    device = str(cfg.get("device", "0"))
    cec_client_path = str(cfg.get("cec_client_path", "cec-client"))

    raw_cmds = cfg.get("commands", [])
    if not raw_cmds:
        LOG.warning("No commands found in configuration")

    for idx, item in enumerate(raw_cmds):
        # Support either 'commands' (list) or legacy 'command' (string)
        raw_commands = item.get("commands")
        if raw_commands is None:
            if "command" in item:
                raw_commands = [item["command"]]
            else:
                LOG.warning("Skipping schedule item %s: no 'command' or 'commands' found", item)
                continue
        # Normalize to list of strings
        commands_list = [str(c) for c in raw_commands] if isinstance(raw_commands, (list, tuple)) else [str(raw_commands)]

        sc = ScheduledCommand(
            time=item["time"],
            commands=commands_list,
            days=item.get("days"),
            name=item.get("name") or (commands_list[0] if commands_list else f"cmd-{idx}"),
        )
        h, m, s = parse_time(sc.time)

        day_of_week = None
        if sc.days:
            # Expect days like: mon, tue, wed, thu, fri, sat, sun
            day_of_week = ",".join(sc.days)

        # Ensure the trigger uses the scheduler's timezone (local time)
        trigger = CronTrigger(hour=h, minute=m, second=s, day_of_week=day_of_week, timezone=scheduler.timezone)

        def job_wrapper(sc=sc, device=device, cec_client_path=cec_client_path, dry_run=dry_run):
            LOG.info("Executing scheduled job '%s' at %s (commands=%s)", sc.name, datetime.now().astimezone(), sc.commands)
            for cmd in sc.commands:
                LOG.info(" -> running command: %s", cmd)
                stdin = build_stdin_for_command(cmd, device)
                rc = run_cec_client(cec_client_path, stdin, dry_run=dry_run)
                if rc == 0:
                    LOG.info("Command '%s' triggered successfully for device %s at %s", cmd, device, datetime.now().astimezone())
                else:
                    LOG.warning("Command '%s' returned non-zero exit status %s", cmd, rc)

        scheduler.add_job(job_wrapper, trigger=trigger, id=f"job-{idx}", name=sc.name)
        LOG.info("Scheduled '%s' at %s (days: %s) commands: %s", sc.name, sc.time, sc.days or 'everyday', sc.commands)


def parse_args():
    p = argparse.ArgumentParser(description="Schedule CEC commands using cec-client and a YAML config.")
    p.add_argument("--config", "-c", required=True, help="Path to YAML configuration file")
    p.add_argument("--dry-run", action="store_true", help="Print commands instead of executing")
    p.add_argument("--loglevel", default="INFO", help="Logging level (DEBUG, INFO, WARNING, ERROR)")
    return p.parse_args()


def main():
    args = parse_args()
    logging.basicConfig(level=getattr(logging, args.loglevel.upper(), logging.INFO), format="%(asctime)s %(levelname)s %(message)s")

    # Also attach a Journal or SysLog handler so logs appear in `journalctl` reliably
    try:
        if JournaldLogHandler is not None:
            jh = JournaldLogHandler()
            jh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
            logging.getLogger().addHandler(jh)
            LOG.debug("Attached JournaldLogHandler for systemd journal logging")
        else:
            raise RuntimeError("JournaldLogHandler not available")
    except Exception:
        try:
            sh = SysLogHandler(address="/dev/log")
            sh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
            logging.getLogger().addHandler(sh)
            LOG.debug("Attached SysLogHandler (/dev/log) for system logging")
        except Exception:
            LOG.debug("No systemd journal or syslog available; using default logging handlers")

    cfg = load_config(args.config)

    # Use system local timezone for scheduling (so YAML times are local time, not UTC)
    local_tz = datetime.now().astimezone().tzinfo
    LOG.info("Using local timezone for scheduling: %s", local_tz)
    scheduler = BackgroundScheduler(timezone=local_tz)
    schedule_commands(scheduler, cfg, dry_run=args.dry_run)

    def shutdown(signum, frame):
        LOG.info("Shutting down scheduler (signal %s)", signum)
        scheduler.shutdown(wait=False)
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    scheduler.start()
    LOG.info("Scheduler started. Press Ctrl+C to exit.")

    try:
        # Keep the main thread alive.
        while True:
            signal.pause()
    except AttributeError:
        # Windows or systems without signal.pause
        import time

        while True:
            time.sleep(3600)


if __name__ == "__main__":
    main()
