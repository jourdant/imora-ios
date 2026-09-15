#!/usr/bin/env python3
"""Verify screenshot-selection counts using the production status implementation."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="imora-screenshots-") as scratch:
    binary = Path(scratch) / "checks"
    sources = ["Imora/Core/Models/MediaCounts.swift", "Imora/Core/Backup/BackupLibraryStatus.swift",
               "Tests/BackupRegression/ScreenshotSelection.swift"]
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    *[str(root / source) for source in sources], "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
