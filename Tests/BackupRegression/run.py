#!/usr/bin/env python3
"""Run real uploader/journal/index code against a controlled, local URLProtocol.

Only URLSession configuration and storage locations are substituted in a
temporary source copy. Assertions fail if those injection points change.
No Photos library, real server, or application data is used.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="imora-regression-build-") as scratch:
    scratch = Path(scratch)
    source = (root / "Imora/Core/Backup/BackgroundUploader.swift").read_text()
    substitutions = {
        "private let journal = UploadJournal()": 'private let journal = UploadJournal(directory: testDirectory.appending(path: "journal"))',
        "let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)": "let config = URLSessionConfiguration.ephemeral\n        config.protocolClasses = [ControlledProtocol.self]",
        '''static let bodyDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "imora/uploads")''': 'static let bodyDirectory = testDirectory.appending(path: "bodies")',
    }
    for old, new in substitutions.items():
        assert source.count(old) == 1, f"Injection point changed: {old}"
        source = source.replace(old, new)
    (scratch / "BackgroundUploader.swift").write_text(source)
    sources = [scratch / "BackgroundUploader.swift"] + [
        root / f"Imora/Core/Backup/{name}.swift"
        for name in ("UploadJournal", "BackupIndex", "BackupIntentStore")
    ] + [root / "Tests/BackupRegression/Checks.swift"]
    executable = scratch / "checks"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    *map(str, sources), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=90)
