import Foundation

/// adopts the background sessions the share extension starts: drains their
/// completions, deletes the spent request bodies, re-enqueues whatever the
/// system had not started yet and raises one summary notification per drained
/// batch. no ui is involved - new assets reach the timeline through the
/// realtime channel like any other remote change.
nonisolated final class ShareUploadCoordinator: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = ShareUploadCoordinator()

    /// uikit hands the relaunch completion over as a plain closure. it only
    /// ever runs on the main thread, which is the guarantee this box stands on.
    struct LaunchCompletion: @unchecked Sendable {
        let run: () -> Void
    }

    /// extension sessions are scheduled at the system's leisure. tasks that
    /// have not finished by the time the app is around move onto this
    /// app-owned session, which is allowed to be impatient.
    private static let mainSessionID = ShareTransfer.sessionPrefix + "main"

    private let lock = NSLock()
    private var mainSession: URLSession!
    private var adopted: [String: URLSession] = [:]
    private var tallies: [String: (uploaded: Int, failed: Int)] = [:]
    private var launchCompletions: [String: LaunchCompletion] = [:]
    /// body paths of originals this run replaced, so their cancelled endings
    /// neither count as failures nor delete a body the replacement reads.
    private var rehomedBodies: Set<String> = []

    private override init() {
        super.init()
        mainSession = makeSession(identifier: Self.mainSessionID)
    }

    /// touching the singleton builds the main session and attaches the
    /// delegate; the app calls this at launch so relaunch events are not missed.
    func attach() {}

    private func makeSession(identifier: String) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sharedContainerIdentifier = ShareTransfer.appGroup
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - adoption

    /// called when the app comes forward: picks up every session the extension
    /// left a marker for, finished or not.
    func adoptPending() {
        removeLegacyInbox()
        sweepAbandonedBodies()
        for identifier in ShareTransfer.markedSessions() {
            adopt(identifier)
        }
    }

    /// relaunch entry point: the system delivers finished transfers for one
    /// session and suspends us again once its completion runs.
    func handleEvents(identifier: String, completion: LaunchCompletion) {
        lock.withLock { launchCompletions[identifier] = completion }
        adopt(identifier)
    }

    private func adopt(_ identifier: String) {
        guard identifier != Self.mainSessionID else { return }
        let session: URLSession? = lock.withLock {
            guard adopted[identifier] == nil else { return nil }
            let session = makeSession(identifier: identifier)
            adopted[identifier] = session
            return session
        }
        guard let session else { return }
        // whatever the system has not finished moves to the app session; the
        // finished remainder replays into the delegate on its own.
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            for task in tasks where task.state == .running || task.state == .suspended {
                self.rehome(task)
            }
            if tasks.isEmpty { self.drain(identifier, session: session) }
        }
    }

    /// moves one unfinished task onto the app session. the body file is
    /// renamed first so the cancelled original cannot take it along; a cancel
    /// that loses the race just yields a server-side duplicate, which dedups.
    private func rehome(_ task: URLSessionTask) {
        guard let ticket = ShareTransfer.decode(task.taskDescription),
              let request = task.originalRequest,
              let directory = ShareTransfer.bodyDirectory
        else {
            task.cancel()
            return
        }
        let moved = directory.appending(path: "body-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: URL(fileURLWithPath: ticket.bodyPath), to: moved)
        } catch {
            // body already gone; let the original play out on its own.
            return
        }
        lock.withLock { _ = rehomedBodies.insert(ticket.bodyPath) }
        let replacement = mainSession.uploadTask(with: request, fromFile: moved)
        replacement.taskDescription = ShareTransfer.encode(
            ShareTicket(bodyPath: moved.path, filename: ticket.filename)
        )
        replacement.resume()
        task.cancel()
    }

    // MARK: - delegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let identifier = session.configuration.identifier else { return }
        if let ticket = ShareTransfer.decode(task.taskDescription) {
            let wasRehomed = lock.withLock { rehomedBodies.remove(ticket.bodyPath) != nil }
            if !wasRehomed {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: ticket.bodyPath))
            }
            let cancelled = (error as? URLError)?.code == .cancelled
            if !wasRehomed, !cancelled {
                let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
                let ok = error == nil && (200..<300).contains(status)
                lock.withLock {
                    var tally = tallies[identifier] ?? (0, 0)
                    if ok { tally.uploaded += 1 } else { tally.failed += 1 }
                    tallies[identifier] = tally
                }
            }
        }
        // the batch is done when its session runs dry.
        session.getAllTasks { [weak self] tasks in
            guard let self, tasks.isEmpty else { return }
            self.drain(identifier, session: session)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        drain(identifier, session: session)
    }

    // MARK: - internals

    /// one batch is over: report it, drop the marker and let go of the session
    /// object. safe to reach twice - the first caller takes the tally.
    private func drain(_ identifier: String, session: URLSession) {
        let (tally, completion) = lock.withLock {
            defer {
                if identifier != Self.mainSessionID { adopted[identifier] = nil }
            }
            return (
                tallies.removeValue(forKey: identifier),
                launchCompletions.removeValue(forKey: identifier)
            )
        }
        if identifier != Self.mainSessionID {
            ShareTransfer.unmarkSession(identifier)
            session.finishTasksAndInvalidate()
        }
        if let tally, tally.uploaded > 0 || tally.failed > 0 {
            Task { @MainActor in
                LocalNotifications.shared.deliverShareResult(uploaded: tally.uploaded, failed: tally.failed)
            }
        }
        // the system expects this on the main thread before it suspends us.
        if let completion { DispatchQueue.main.async { completion.run() } }
    }

    /// the pre-direct-upload architecture staged media and batch descriptors
    /// in an inbox directory the app consumed; installs upgrading past it
    /// still carry the leftovers.
    private func removeLegacyInbox() {
        guard let container = ShareTransfer.container else { return }
        try? FileManager.default.removeItem(at: container.appending(path: "inbox"))
    }

    /// bodies whose tasks died with an earlier process would sit in the app
    /// group forever; nothing two days old can still be in flight.
    private func sweepAbandonedBodies() {
        guard let directory = ShareTransfer.bodyDirectory else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let cutoff = Date().addingTimeInterval(-48 * 3600)
        for url in contents {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
