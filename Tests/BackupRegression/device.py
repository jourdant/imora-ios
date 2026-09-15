#!/usr/bin/env python3
"""Run an installed opt-in Debug probe; creates marked Photos/server fixtures."""
import argparse
from pathlib import Path
import re
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("mode", choices=["handoff", "progress", "cancel-after-expiry", "concurrent-restart", "relaunch"])
parser.add_argument("--device", required=True)
parser.add_argument("--bundle", required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--verify-only", action="store_true", help="Validate an existing trace without touching the device")
args = parser.parse_args()
base = ["xcrun", "devicectl", "device"]
copy = base + ["copy", "from", "--device", args.device, "--domain-type", "appDataContainer",
               "--domain-identifier", args.bundle, "--source", "Library/Application Support/imora/backup-expiry-debug.txt",
               "--destination", str(args.output)]
args.output.parent.mkdir(parents=True, exist_ok=True)
if not args.verify_only:
    subprocess.run(copy, capture_output=True)
old = args.output.read_text() if args.output.exists() else ""
launch = base + ["process", "launch", "--device", args.device, "--terminate-existing", args.bundle]
if not args.verify_only:
    subprocess.run(launch + [f"--backup-expiry-debug={args.mode}"], check=True)


def ordered(text, markers):
    position = 0
    for marker in markers:
        found = text.find(marker, position)
        if found < 0:
            return False
        position = found + len(marker)
    return True


def passed(text):
    held = re.findall(r"held task=(\d+) point=(\w+) sent=(\d+) total=(\d+)", text)
    count = 3 if args.mode == "concurrent-restart" else 1
    if len(held) != count or len({row[0] for row in held}) != count:
        return False
    for task, point, sent, total in held:
        if args.mode in ("progress", "relaunch") and not (point == "progress" and 0 < int(sent) < int(total)):
            return False
        markers = [f"held task={task} ", f"waiter-detached task={task} expired=true had-continuation=true",
                   f"expiry-returned task={task} state=1"]
        if args.mode == "cancel-after-expiry":
            markers += ["explicit-cancel-requested", f"upload-failed task={task} http=0 error=-999",
                        "restart-after-cancel-requested"]
            retries = re.findall(r"receipt-persisted task=(\d+) http=201 orphan=false", text)
            if len(retries) != 1 or retries[0] == task or f"receipt-persisted task={task} " in text:
                return False
            markers += [f"receipt-persisted task={retries[0]} http=201 orphan=false", "orphan-index-applied success=true"]
        else:
            if "upload-failed" in text:
                return False
            if args.mode == "concurrent-restart":
                markers += ["restart-while-transfers-held"]
            if args.mode == "relaunch":
                markers += ["ready-for-termination", "observer-initialized", f"resume-after-relaunch task={task} state=1"]
                old_process = re.search(r"ready-for-termination pid=(\d+)", text)
                new_process = re.search(r"observer-initialized pid=(\d+)", text)
                if not old_process or not new_process or old_process[1] == new_process[1]:
                    return False
                receipt_process = re.search(rf"receipt-persisted task={task} [^\n]*process=(\d+)", text)
                if not receipt_process or receipt_process[1] != new_process[1]:
                    return False
            else:
                markers += [f"resume-after-expiry task={task} state=1"]
            markers += [f"receipt-persisted task={task} http=201 orphan=true"]
        if not ordered(text, markers):
            return False
    applied = set(re.findall(r"orphan-index-applied success=true asset=(\S+)", text))
    receipts = set(re.findall(r"receipt-persisted[^\n]* asset=(\S+)", text))
    # Concurrent receipt replays may apply the same durable receipt more than
    # once before acknowledgement; validate unique assets, not callback count.
    return len(applied) == count and applied == receipts and text.count("receipt-persisted") == count


if args.verify_only:
    report = args.output.read_text()
    if "INCONCLUSIVE" in report or f"start mode={args.mode};" not in report or not passed(report):
        raise SystemExit("INCONCLUSIVE/FAILED: trace does not satisfy the assertions")
    print(f"PASS: {args.mode}; existing trace validated without device operations")
    sys.exit(0)

deadline = time.monotonic() + 180
previous = ""
terminated = False
while time.monotonic() < deadline:
    result = subprocess.run(copy, capture_output=True)
    if result.returncode == 0:
        report = args.output.read_text()
        if report != old and f"start mode={args.mode};" in report:
            if report != previous:
                print(report[len(previous):] if report.startswith(previous) else report, flush=True)
                previous = report
            if "INCONCLUSIVE" in report or "orphan-index-applied success=false" in report:
                raise SystemExit("INCONCLUSIVE/FAILED; retained report and left app running")
            if args.mode == "relaunch" and not terminated:
                ready = re.search(r"ready-for-termination pid=(\d+)", report)
                if ready:
                    if "receipt-persisted" in report:
                        raise SystemExit("INCONCLUSIVE: upload completed before termination")
                    subprocess.run(base + ["process", "signal", "--device", args.device,
                                           "--pid", ready[1], "--signal", "SIGKILL"], check=True)
                    terminated = True
                    print(f"Killed test process {ready[1]}; launching an observer process", flush=True)
                    subprocess.run(launch + ["--backup-expiry-debug=observe-relaunch"], check=True)
            if passed(report):
                print(f"PASS: {args.mode}; validated ordered task-specific events")
                subprocess.run(launch, check=True)
                break
    time.sleep(3)
else:
    raise SystemExit("INCONCLUSIVE: timed out waiting for a complete passing trace")
