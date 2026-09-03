import UIKit

/// a claim on process time. the system suspends an app within seconds of it
/// leaving the foreground unless something like this is held, and grants
/// about thirty seconds when it is. taken in the foreground it costs nothing.
/// when the grant runs out the lease is released for us and whatever was
/// running freezes until the app is next resumed, which is harmless for work
/// that picks up where it stopped.
nonisolated final class ProcessLease: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    @MainActor
    static func take(_ name: String) -> ProcessLease {
        let lease = ProcessLease()
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            lease.release()
        }
        lease.lock.withLock { lease.identifier = identifier }
        return lease
    }

    /// a lease that lets go on its own, for bridging the moment between the
    /// system handing the app something to do and that work taking a lease
    /// of its own.
    @MainActor
    @discardableResult
    static func take(_ name: String, for duration: Duration) -> ProcessLease {
        let lease = take(name)
        Task {
            try? await Task.sleep(for: duration)
            lease.release()
        }
        return lease
    }

    /// safe to call more than once and from any thread.
    func release() {
        let identifier = lock.withLock { () -> UIBackgroundTaskIdentifier in
            defer { self.identifier = .invalid }
            return self.identifier
        }
        guard identifier != .invalid else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { UIApplication.shared.endBackgroundTask(identifier) }
        } else {
            Task { @MainActor in UIApplication.shared.endBackgroundTask(identifier) }
        }
    }
}
