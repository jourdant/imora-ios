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
    /// stops taking new work. whatever was already handed to the system is
    /// left to finish, and the job ends once it has.
    func windDown()
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
/// locking the device expires the task: the system meant to hold the device
/// awake for it and does not, so the task stops seeing progress and is
/// reclaimed, see apple forums thread 796138. the job is not tied to the task. its
/// transfers sit in a background url session, which carries on through the
/// lock and wakes the app to queue more, so an expiry that turns out to be a
/// lock lets the job go on without the ui, and the next foreground gives the
/// ui back.
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
    /// the job outlived its task and is running without progress ui.
    private var wantsRestore = false
    /// the next task to start is for the job already going, not a new one.
    private var restoresRunningJob = false
    private var backgroundedAt: Date?

    /// a lock withdraws protected data within about ten seconds.
    private static let lockGrace: Duration = .seconds(15)
    /// an app sent to the background this recently was locked from the
    /// foreground, which nothing else shows in time.
    private static let foregroundLockWindow: TimeInterval = 3

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
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.backgroundedAt = Date() }
        }
    }

    /// asks the system to run the job as continued processing. false means it
    /// declined and the caller should just run in app.
    func submit(title: String, subtitle: String) async -> Bool {
        guard isRegistered, workload?.isRunning != true else { return false }
        return await Self.submitRequest(identifier: identifier, title: title, subtitle: subtitle)
    }

    /// called on foreground. a job that lost its task to a device lock is
    /// still going, invisibly, and gets the system ui back.
    func restore() {
        guard wantsRestore else { return }
        wantsRestore = false
        guard isRegistered, current == nil, let workload, workload.isRunning else { return }
        let title = workload.continuedTitle
        let subtitle = workload.continuedSubtitle
        restoresRunningJob = true
        Task {
            let accepted = await Self.submitRequest(identifier: identifier, title: title, subtitle: subtitle)
            if !accepted { restoresRunningJob = false }
        }
    }

    // MARK: - running

    private func begin(_ task: BGContinuedProcessingTask) {
        // a restored task must not start a fresh job if the one it was
        // meant for ended first.
        let attachOnly = restoresRunningJob
        restoresRunningJob = false
        guard let workload, !attachOnly || workload.isRunning else {
            task.setTaskCompleted(success: attachOnly)
            return
        }
        backupLog.info("continued processing task started")
        current = task
        wantsRestore = false
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
            await workload.runToCompletion()
            wantsRestore = false
            workload.onContinuedProgress = nil
            report(to: task)
            finish(task, success: !workload.continuedFailed)
        }
    }

    /// the cancel button in the system ui lands here, as does the system
    /// reclaiming the task, and nothing says which. the task is closed at
    /// once either way. the job is not: a device lock is the usual reason and
    /// must not throw away uploads the system is still carrying, so the job
    /// goes on when the device turns out to be locked and winds down when it
    /// does not.
    private func expire(_ task: BGContinuedProcessingTask) {
        guard task === current, let workload else { return }
        workload.onContinuedProgress = nil
        finish(task, success: true)
        let expiredAt = Date()
        // nothing keeps the app alive any more; the wait needs its own time.
        let lease = ProcessLease.take("continued processing expiry")
        Task {
            defer { lease.release() }
            if await deviceLocked(expiredAt: expiredAt) {
                backupLog.info("continued processing expired by a device lock, the job goes on")
                wantsRestore = true
            } else {
                backupLog.info("continued processing stopped, winding the job down")
                workload.windDown()
            }
        }
    }

    /// a locked device withdraws protected data, within about ten seconds of
    /// the lock, so that is polled for a little longer than that. the app
    /// entering the background right around the expiry is the lock seen from
    /// the foreground, which the withdrawal may be too slow to show; a
    /// backgrounding well after the expiry is the user leaving and says nothing.
    private func deviceLocked(expiredAt: Date) async -> Bool {
        let deadline = ContinuousClock.now + Self.lockGrace
        while true {
            if !UIApplication.shared.isProtectedDataAvailable { return true }
            if let backgroundedAt,
               abs(backgroundedAt.timeIntervalSince(expiredAt)) < Self.foregroundLockWindow {
                return true
            }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .seconds(1))
        }
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
