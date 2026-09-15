#!/usr/bin/env python3
"""Exercise the production backup condition policy without a test target."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="imora-conditions-") as scratch:
    binary = Path(scratch) / "checks"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    str(root / "Imora/Core/Backup/BackupConditions.swift"),
                    str(root / "Tests/BackupRegression/Conditions.swift"),
                    "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
