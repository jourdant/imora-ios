# Backup regression checks

## Local, deterministic checks

On macOS with Xcode selected:

```sh
python3 Tests/BackupRegression/run.py
```

The runner compiles the current production `BackgroundUploader`, `UploadJournal`, `BackupIndex`, and `BackupIntentStore`. A temporary source copy substitutes an ephemeral URLSession with a controlled URLProtocol and temporary storage paths. Assertions ensure the injection points still match. All upload, cancellation, receipt, and index logic comes from the current source. No Debug probe code is compiled.

The same command also runs the backup-condition and screenshot-selection checks described below. A failure in any suite fails the command.

Checks cover:

- Expiry detaches the worker, preserves the transfer, and journals its completion.
- Explicit cancellation, cancellation after expiry, rejection of an expired run, and independent later runs.
- Twelve concurrent uploads and orphan receipts.
- Fifty cancellation/completion races and fifty immediate cancellations.
- HTTP rejection and connection loss without false success receipts.
- Receipt-write failure retaining the body for recovery.
- Durable journal reconstruction and acknowledgement; deferred replay when the consumer is unavailable.
- Live Photo motion/still receipt pairing across index reconstruction, idempotent application, and rejection of stale receipts for edited bytes.
- Index-write failure followed by successful replay when storage recovers.
- Account-scoped unfinished intent persistence, clearing, and refusal to overwrite unreadable storage.

The minimal DeviceAsset/BackupLibraryStatus/ProcessLease/API types are compile-time stand-ins. This suite does **not** exercise PhotoKit export, the full Live Photo upload pipeline, the BackupManager state machine, UI behavior, protected-device storage, or iOS background-session lifecycle.

## Physical-device checks

Requires an installed Debug build containing the opt-in `BackupExpiryDebug` helper, a signed-in account, full Photos access, and an idle, fully backed-up library. Each run creates marked copies of a recent image in Photos and uploads them to the configured server. Concurrent mode creates three copies dated January 1970 to put them before the backlog boundary. The original image is unchanged. Fixtures are not automatically deleted.

```sh
python3 Tests/BackupRegression/device.py cancel-after-expiry \
  --device DEVICE_UDID --bundle YOUR_APP_BUNDLE_ID \
  --output /tmp/imora-cancel-trace.txt
```

Modes:

| Mode | Check |
| --- | --- |
| `handoff` | Expire a registered, suspended upload; resume and consume its receipt. |
| `progress` | Suspend after partial progress, expire, resume, and consume its receipt. |
| `cancel-after-expiry` | Expire, explicitly cancel the detached upload, then retry with a fresh task. |
| `concurrent-restart` | Hold three backlog uploads, expire, restart backup before resuming them, and verify all three original tasks complete. |
| `relaunch` | Hold an upload after partial progress, expire, send SIGKILL to the test process, then launch an observer that rediscovers and resumes the retained task. |

The runner validates ordered, task-specific events and unique fixture receipts. Repeated index-application callbacks are allowed because receipt replay is idempotent. A successful run relaunches the app without test arguments. Failure or timeout retains the trace and leaves the app available for diagnosis; if a relaunch test stops while a transfer is held, launch with `--backup-expiry-debug=observe-relaunch` to recover it.

These probes call the production manager expiry method directly. They do not simulate BGTaskScheduler launch/expiration dispatch, natural OS scheduling, device locking, suspension under memory pressure, or a user swipe-to-force-quit. SIGKILL followed by an explicit launch is a controlled process-boundary test, not an assertion about those other lifecycle events.

The temporary device helper and hooks are separate from the local regression suite and can be removed without removing that suite. Release builds exclude the helper.

## Backup conditions

Run `python3 Tests/BackupRegression/conditions.py` to exercise the production policy's inclusive battery threshold, unknown readings, offline handling, simultaneous holds, independent override expiration, and repeat condition episodes. No Xcode test target or device state is required.

## Screenshot exclusions

Run `python3 Tests/BackupRegression/screenshots.py` to verify the production backup status calculation with screenshot exclusions, mixed photo/video/Live Photo libraries, screenshot-only libraries, and re-inclusion. Metadata and index entries are fixtures; PhotoKit classification and upload scheduling still require device checks.

## Backup controls: pre-merge device checklist

These checks require a signed-in app on a physical device. Record results and screenshots in the PR; a successful build/install alone does not verify them.

- [ ] With automatic backup off, open Backup from the gallery banner. Verify “Not Now” lasts for the app session, “Don’t Ask Again” survives relaunch, and turning automatic backup on then off restores the reminder.
- [ ] With pending assets, cellular backup off, and no Wi-Fi, verify the hold banner and “Sync This Time.” Go offline and return to cellular: the override stays. Connect to Wi-Fi, then return to cellular: the hold returns.
- [ ] At or below the configured battery threshold, verify pausing and overriding. Further discharge and charging below the threshold retain the override; rising above it resets protection for the next low-battery episode. Repeat with cellular and battery holds together to confirm their overrides reset independently.
- [ ] Repeat condition changes across background/foreground and relaunch. iOS-owned transfers may finish while new preparation/uploads pause. Resets can only be observed while the app has execution time or from current conditions when it resumes; a Wi-Fi visit or charge recovery entirely between observations cannot be reconstructed.
- [ ] With backup up to date, or Photos access denied/limited, verify no cellular/low-battery hold banner is shown. Permission recovery remains available in Backup settings.
- [ ] Turn Include Screenshots off with old and newly captured screenshots pending, including during an active backup. Verify they stop being queued, counts show them as excluded, existing index/server copies remain, and they stay in the gallery. Turn it back on and verify missing screenshots become eligible again. Explicitly selecting a screenshot for manual backup remains supported.
- [ ] Check the gallery banner and settings at large Dynamic Type sizes, with VoiceOver, in dark mode, and in iPad split view. Verify Backup appears above Storage and its “Off” value changes when automatic backup is enabled.
