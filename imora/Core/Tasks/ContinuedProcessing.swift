import BackgroundTasks
import Observation
import os

/// what the system progress ui needs from whatever is running. the scheduler
/// expires a task that stops reporting, so `onContinuedProgress` has to fire
/// more often than the wording changes.
@MainActor
protocol ContinuedWorkload: AnyObject {
    var isRunning: Bool { get }
    var continuedTitle: String { get }
    var continuedSubtitle: String { get }
    /// 0...1 across the whole job.
    var continuedFraction: Double { get }
    var continuedSucceeded: Bool { get }
    var onContinuedProgress: (() -> Void)? { get set }

    /// starts the job if idle and suspends until it ends. the task has to
    /// outlive the whole thing, so it needs something to await.
    func runToCompletion() async
    func cancel()
}

/// keeps a user-started job running after the app leaves the foreground and
/// feeds the system progress ui - the live activity ios draws in the dynamic
/// island and on the lock screen, with its own cancel button.
///
/// the api is only for work the user explicitly asked for, which is why the
/// backup instance covers the back up now button and not the library-change
/// reruns, and the share instance covers a drop from the share sheet.
@Observable
final class ContinuedProcessing {
    static let backup = ContinuedProcessing(suffix: "backup")
    static let share = ContinuedProcessing(suffix: "share")

    /// set by whoever owns the job; the launch handler needs it to exist by the
    /// time the system calls back.
    @ObservationIgnored weak var workload: (any ContinuedWorkload)?

    private let suffix: String
    private var isRegistered = false
    private var lastSubtitle = ""

    /// one fixed identifier per job kind, registered once. apple blocks wildcard
    /// handlers - the registered and submitted strings have to match - and only
    /// one job of each kind runs at a time, so a single id covers it.
    private var identifier: String {
        "\(Bundle.main.bundleIdentifier ?? "app.imora").\(suffix)"
    }

    private init(suffix: String) {
        self.suffix = suffix
    }

    private static func owner(ofSuffix suffix: String) -> ContinuedProcessing {
        suffix == "share" ? share : backup
    }

    /// called from the app initializer. continued-processing registrations are
    /// exempt from the finish-launching deadline, but there is no reason to wait.
    static func registerAll() {
        backup.register()
        share.register()
    }

    private func register() {
        guard !isRegistered else { return }
        let suffix = suffix
        isRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { task in
            // the queue above pins this to the main thread, so adopting the main
            // actor is sound and the non-sendable task never crosses isolation.
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else { return }
                ContinuedProcessing.owner(ofSuffix: suffix).begin(task)
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
        guard let workload else {
            task.setTaskCompleted(success: false)
            return
        }
        backupLog.info("continued processing task started")
        lastSubtitle = ""
        task.progress.totalUnitCount = 100
        // the cancel button in the system ui lands here, as does the scheduler
        // reclaiming resources under load.
        let suffix = suffix
        task.expirationHandler = {
            Task { @MainActor in
                ContinuedProcessing.owner(ofSuffix: suffix).workload?.cancel()
            }
        }
        workload.onContinuedProgress = { [weak self, weak task] in
            guard let self, let task else { return }
            self.report(to: task)
        }
        Task {
            await workload.runToCompletion()
            workload.onContinuedProgress = nil
            self.report(to: task)
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: workload.continuedSucceeded)
        }
    }

    private func report(to task: BGContinuedProcessingTask) {
        guard let workload else { return }
        task.progress.completedUnitCount = Int64((workload.continuedFraction * 100).rounded())
        let subtitle = workload.continuedSubtitle
        // byte progress ticks far more often than the wording changes.
        guard subtitle != lastSubtitle else { return }
        lastSubtitle = subtitle
        task.updateTitle(workload.continuedTitle, subtitle: subtitle)
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
