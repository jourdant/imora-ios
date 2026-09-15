import BackgroundTasks
import os

/// Opportunistic wakeups for unfinished preparation and automatic library
/// discovery. iOS chooses when (or whether) to grant a window.
@MainActor
final class BackupProcessing {
    static let shared = BackupProcessing()
    private let identifier = "\(Bundle.main.bundleIdentifier ?? "app.imora").backup.refresh"
    weak var session: SessionStore?
    private var registered = false
    private var current: BGProcessingTask?
    private var worker: Task<Void, Never>?

    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let task = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.begin(task)
            }
        }
    }

    func schedule(needed: Bool) {
        guard registered else { return }
        guard needed else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        // Submitting the same identifier replaces its pending request. Do this
        // at lifecycle/run boundaries, never on progress ticks.
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { backupLog.info("background backup scheduling declined: \(error)") }
    }

    private func begin(_ task: BGProcessingTask) {
        guard current == nil else { task.setTaskCompleted(success: false); return }
        current = task
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor in
                guard let self, let task, self.current === task else { return }
                self.worker?.cancel()
                self.session?.backup?.pauseForBackgroundExpiration()
                self.finish(task, success: false)
            }
        }
        worker = Task {
            session?.restoreSessionIfAvailable()
            guard let manager = session?.backup else {
                // Protected data may be unavailable. Retain both receipts and
                // the opportunity to retry after the device is unlocked.
                schedule(needed: session?.state == .restoring)
                finish(task, success: false)
                return
            }
            manager.scheduleRecovery()
            let success = await manager.runScheduledBackup()
            guard current === task else { return }
            manager.scheduleRecovery()
            finish(task, success: success)
        }
    }

    private func finish(_ task: BGProcessingTask, success: Bool) {
        guard current === task else { return }
        current = nil
        worker = nil
        task.setTaskCompleted(success: success)
    }
}
