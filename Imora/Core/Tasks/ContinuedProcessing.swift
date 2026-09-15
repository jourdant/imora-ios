import BackgroundTasks
import Observation
import UIKit
import os

/// what the system progress ui needs from whatever is running. the scheduler
/// expires a task that stops reporting, so `onContinuedProgress` has to fire
/// more often than the wording changes.
@MainActor
protocol ContinuedWorkload: AnyObject {
    var isRunning: Bool { get }
    var continuedTitle: String { get }
    var continuedSubtitle: String { get }
    /// nil leaves the system bar where it is.
    var continuedProgress: ContinuedProgress? { get }
    /// reporting a failure makes the system tell the user the job failed,
    /// so a job the user stopped themselves must not count as one.
    var continuedFailed: Bool { get }
    var onContinuedProgress: (() -> Void)? { get set }

    /// starts the job if idle and suspends until it ends. the task has to
    /// outlive the whole thing, so it needs something to await.
    func runToCompletion() async
    /// Cancels preparation and transfers promptly when the system expires
    /// the task, including when the user presses the system Cancel button.
    func cancel()
}

/// keeps a user-started job running after the app leaves the foreground and
/// feeds the system progress ui - the live activity ios draws in the dynamic
/// island and on the lock screen, with its own cancel button.
///
/// the api is only for work the user explicitly asked for, which is why the
/// backup instance covers the back up now button and not the library-change
/// reruns. share uploads ride their own background url sessions and need
/// none of this.
///
/// Expiration has no public reason code. Treat every expiration as a stop;
/// protected-data availability cannot distinguish a lock from cancellation.
@Observable
final class ContinuedProcessing {
    static let backup = ContinuedProcessing(
        identifier: "\(Bundle.main.bundleIdentifier ?? "app.imora").backup"
    )

    /// set by whoever owns the job; the launch handler needs it to exist by the
    /// time the system calls back.
    @ObservationIgnored weak var workload: (any ContinuedWorkload)?

    /// one fixed identifier per job kind, registered once. apple blocks wildcard
    /// handlers - the registered and submitted strings have to match - and only
    /// one job of each kind runs at a time, so a single id covers it.
    private let identifier: String
    private var isRegistered = false
    /// the task the system is drawing progress for, until it is completed.
    /// nothing may touch a task past that point.
    private var current: BGContinuedProcessingTask?
    private var lastSubtitle = ""

    private init(identifier: String) {
        self.identifier = identifier
    }

    /// called from the app initializer. continued-processing registrations are
    /// exempt from the finish-launching deadline, but there is no reason to wait.
    static func registerAll() {
        backup.register()
    }

    private func register() {
        guard !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { [self] task in
            // the queue above pins this to the main thread, so adopting the main
            // actor is sound and the non-sendable task never crosses isolation.
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else { return }
                self.begin(task)
            }
        }
        if !isRegistered {
            backupLog.error("continued processing identifier missing from the info plist")
        }
    }

    /// asks the system to run the job as continued processing. false means it
    /// declined and the caller should just run in app.
    func submit(title: String, subtitle: String) async -> Bool {
        guard isRegistered, workload?.isRunning != true else { return false }
        return await Self.submitRequest(identifier: identifier, title: title, subtitle: subtitle)
    }

    // MARK: - running

    private func begin(_ task: BGContinuedProcessingTask) {
        guard current == nil, let workload else {
            task.setTaskCompleted(success: false)
            return
        }
        backupLog.info("continued processing task started")
        current = task
        lastSubtitle = ""
        task.progress.totalUnitCount = 1
        task.progress.completedUnitCount = 0
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor in
                guard let self, let task else { return }
                self.expire(task)
            }
        }
        workload.onContinuedProgress = { [weak self, weak task] in
            guard let self, let task else { return }
            self.report(to: task)
        }
        Task {
            guard task === current else { return }
            await workload.runToCompletion()
            guard task === current else { return }
            workload.onContinuedProgress = nil
            report(to: task)
            finish(task, success: !workload.continuedFailed)
        }
    }

    /// Apple requires cancellation and minimal cleanup on expiration. Never
    /// report an unfinished operation as successful or submit a replacement
    /// continued-processing request without another explicit user action.
    private func expire(_ task: BGContinuedProcessingTask) {
        guard task === current else { return }
        workload?.onContinuedProgress = nil
        workload?.cancel()
        backupLog.info("continued processing expired; cancelling backup")
        finish(task, success: false)
    }

    private func report(to task: BGContinuedProcessingTask) {
        guard task === current, let workload else { return }
        if let progress = workload.continuedProgress {
            task.progress.totalUnitCount = progress.totalUnitCount
            task.progress.completedUnitCount = progress.completedUnitCount
        }
        let subtitle = workload.continuedSubtitle
        // byte progress ticks far more often than the wording changes.
        guard subtitle != lastSubtitle else { return }
        lastSubtitle = subtitle
        task.updateTitle(workload.continuedTitle, subtitle: subtitle)
    }

    private func finish(_ task: BGContinuedProcessingTask, success: Bool) {
        guard task === current else { return }
        current = nil
        task.setTaskCompleted(success: success)
    }

    /// submission is documented as main-thread hostile and the request is not
    /// sendable, so it is built where it is used and only strings cross.
    @concurrent
    private nonisolated static func submitRequest(
        identifier: String,
        title: String,
        subtitle: String
    ) async -> Bool {
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: subtitle
        )
        // queueing would show an indicator for a job that may never start;
        // failing fast lets the caller fall back to running in app.
        request.strategy = .fail
        do {
            if #available(iOS 27.0, *) {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } else {
                try BGTaskScheduler.shared.submit(request)
            }
            return true
        } catch {
            backupLog.info("continued processing declined: \(error.localizedDescription)")
            return false
        }
    }
}
