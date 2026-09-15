import Foundation
import os

/// every asset upload goes through one background url session, so a transfer
/// handed to the system can continue after suspension or system termination.
/// A user force-quit cancels transfers and requires a subsequent app launch.
///
/// while the app is alive an upload behaves like any async call. when it is
/// not, the delegate still fires - on relaunch if need be - and the completion
/// is replayed into the backup index instead of a caller that no longer exists.
nonisolated final class BackgroundUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackgroundUploader()

    /// everything needed to finish an upload whose caller is gone. the system
    /// persists it for us in the task description.
    struct Ticket: Codable, Sendable {
        /// host|userId, so a completion never lands in another account's index.
        let account: String
        let localId: String
        let isMotion: Bool
        let bodyPath: String
        var version: Int? = 1
        var id: UUID? = UUID()
        var source: BackupEntry? = nil
    }

    struct Completion: Codable, Sendable {
        let ticket: Ticket
        let remoteId: String
    }

    /// One library run owns this policy. Expiring its processing budget stops
    /// new transfers, but cancellation only detaches callers from existing ones.
    /// Viewer uploads and later runs use independent cancellation policies.
    final class RunLifetime: @unchecked Sendable {
        private let lock = NSLock()
        private var expired = false

        var hasExpired: Bool { lock.withLock { expired } }

        func expire() { lock.withLock { expired = true } }
    }

    /// uikit hands the relaunch completion over as a plain closure. it only
    /// ever runs on the main thread, which is the guarantee this box stands on.
    struct LaunchCompletion: @unchecked Sendable {
        let run: () -> Void
    }

    private static let sessionID = "app.imora.backup.uploads"
    /// application support rather than tmp or caches: the body has to outlive
    /// the app process, and neither of those is promised to.
    static let bodyDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "imora/uploads")

    private var session: URLSession!
    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var buffers: [Int: Data] = [:]
    private var progressHandlers: [Int: @Sendable (Double) -> Void] = [:]
    private var orphanHandler: (@Sendable (Completion) async -> Bool)?
    private var backgroundCompletion: LaunchCompletion?
    private var finishedEventsAwaitingHandler = false
    private let journal = UploadJournal()

    private override init() {
        super.init()
        Self.prepareBodyDirectory()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        // the user asked for this backup, so it should not wait for a charger.
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// touching the singleton is what builds the session and attaches the
    /// delegate; the app calls this at launch so relaunch events are not missed.
    func attach() {}

    /// request bodies are large and regenerable, so they have no business in
    /// the user's icloud backup even though application support is.
    private static func prepareBodyDirectory() {
        var directory = bodyDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    // MARK: - handlers

    func setOrphanHandler(_ handler: (@Sendable (Completion) async -> Bool)?) {
        lock.withLock { orphanHandler = handler }
        Task { await replayReceipts() }
    }

    /// Deletion is an acknowledgement: the consumer has committed the index,
    /// or verified that this receipt belongs to an obsolete asset revision.
    @concurrent
    func replayReceipts() async {
        guard let handler = lock.withLock({ orphanHandler }) else { return }
        for completion in journal.receipts() {
            if await handler(completion) { journal.acknowledge(completion.ticket) }
        }
    }

    /// Adopt system-owned work before preparing another copy. This wait is
    /// cancellable; cancelling a waiter does not cancel somebody else's task.
    @concurrent
    func waitForExisting(account: String, localId: String) async throws {
        while true {
            try Task.checkCancellation()
            let tasks = await session.allTasks
            let exists = tasks.contains {
                guard let ticket = Self.decode($0.taskDescription) else { return false }
                return ticket.account == account && ticket.localId == localId
            }
            if !exists { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        await replayReceipts()
        try Task.checkCancellation()
    }

    /// stored by the app delegate when the system relaunches us to deliver
    /// finished transfers; calling it is what lets the app suspend again.
    func setBackgroundCompletionHandler(_ handler: LaunchCompletion) {
        let alreadyFinished = lock.withLock {
            if finishedEventsAwaitingHandler {
                finishedEventsAwaitingHandler = false
                return true
            }
            backgroundCompletion = handler
            return false
        }
        if alreadyFinished { finishBackgroundEvents(handler) }
    }

    // MARK: - uploading

    /// `lease` is whatever kept the process alive while the body was built.
    /// it is released the moment the system owns the transfer.
    func upload(
        _ request: URLRequest,
        fromFile bodyURL: URL,
        ticket: Ticket,
        lease: ProcessLease? = nil,
        lifetime: RunLifetime? = nil,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> Data {
        try Task.checkCancellation()
        // Persist the source revision before iOS can send a single byte.
        try journal.prepare(ticket)
        let task = session.uploadTask(with: request, fromFile: bodyURL)
        task.taskDescription = Self.encode(ticket)
        let id = task.taskIdentifier
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // registered before the task runs, or a fast failure would find
                // nothing to resume and be replayed as an orphan instead.
                let started = lock.withLock {
                    guard !Task.isCancelled, lifetime?.hasExpired != true else { return false }
                    continuations[id] = continuation
                    progressHandlers[id] = onProgress
                    #if DEBUG
                    if !BackupExpiryDebug.shared.holdAtHandoff(task, ticket: ticket) { task.resume() }
                    #else
                    task.resume()
                    #endif
                    return true
                }
                if !started {
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                }
                lease?.release()
            }
        } onCancel: { [weak self] in
            // Release the Swift worker promptly even if iOS continues sending
            // the file. Completion still reaches the durable receipt journal.
            let continuation = self?.lock.withLock {
                self?.progressHandlers[id] = nil
                return self?.continuations.removeValue(forKey: id)
            }
            if lifetime?.hasExpired != true { task.cancel() }
            #if DEBUG
            BackupExpiryDebug.shared.record("waiter-detached task=\(id) expired=\(lifetime?.hasExpired == true) had-continuation=\(continuation != nil)", localId: ticket.localId)
            #endif
            continuation?.resume(throwing: CancellationError())
        }
    }

    func cancelAll() {
        session.getAllTasks { tasks in
            for task in tasks { task.cancel() }
        }
    }

    #if DEBUG
    func debugResumeFixtureTasks(_ localIds: Set<String>) async {
        var resumed = 0
        for task in await session.allTasks {
            guard let ticket = Self.decode(task.taskDescription), localIds.contains(ticket.localId) else { continue }
            BackupExpiryDebug.shared.record("resume-after-relaunch task=\(task.taskIdentifier) state=\(task.state.rawValue)", localId: ticket.localId)
            task.resume()
            resumed += 1
        }
        if resumed == 0 { BackupExpiryDebug.shared.record("INCONCLUSIVE: no retained fixture upload found after relaunch") }
    }
    #endif

    /// removes body files no live task still refers to. a killed run leaves
    /// them behind and nothing else ever will. anything recent is spared: a
    /// body is on disk for a moment before its task exists.
    func sweepAbandonedBodies() {
        session.getAllTasks { tasks in
            let live = Set(tasks.compactMap { Self.decode($0.taskDescription)?.bodyPath })
            let manager = FileManager.default
            let contents = (try? manager.contentsOfDirectory(
                at: Self.bodyDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            let cutoff = Date().addingTimeInterval(-3600)
            for url in contents where !live.contains(url.path) {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                guard let modified, modified < cutoff else { continue }
                try? manager.removeItem(at: url)
            }
        }
    }

    // MARK: - delegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { buffers[dataTask.taskIdentifier, default: Data()].append(data) }
        if let ticket = Self.decode(dataTask.taskDescription) {
            do { try journal.appendResponse(data, ticket: ticket) }
            catch { backupLog.error("upload response could not be saved: \(error)") }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        #if DEBUG
        if let ticket = Self.decode(task.taskDescription) {
            BackupExpiryDebug.shared.progress(task, ticket: ticket, sent: totalBytesSent, total: totalBytesExpectedToSend)
        }
        #endif
        let handler = lock.withLock { progressHandlers[task.taskIdentifier] }
        handler?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let id = task.taskIdentifier
        let ticket = Self.decode(task.taskDescription)
        let (continuation, data) = lock.withLock { () -> (CheckedContinuation<Data, any Error>?, Data) in
            let continuation = continuations.removeValue(forKey: id)
            let buffered = buffers.removeValue(forKey: id) ?? Data()
            let persisted = ticket.flatMap { journal.response(for: $0) }
            let data = (persisted?.count ?? 0) >= buffered.count ? (persisted ?? buffered) : buffered
            progressHandlers[id] = nil
            return (continuation, data)
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        var deliveryError = error
        if let ticket {
            do {
                if error == nil, (200..<300).contains(status),
                   let result = try? JSONDecoder().decode(AssetUploadResult.self, from: data) {
                    // The delegate queue writes this before acknowledging events
                    // to UIKit, even if the account/index is not ready yet.
                    try journal.complete(Completion(ticket: ticket, remoteId: result.id))
                    #if DEBUG
                    BackupExpiryDebug.shared.record("receipt-persisted task=\(id) http=\(status) orphan=\(continuation == nil)", localId: ticket.localId)
                    #endif
                } else {
                    try journal.recordFailure(ticket, status: status, error: error)
                    #if DEBUG
                    BackupExpiryDebug.shared.record("upload-failed task=\(id) http=\(status) error=\((error as NSError?)?.code ?? 0)", localId: ticket.localId)
                    #endif
                }
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: ticket.bodyPath))
            } catch {
                // Keep the prepared ticket and body for checksum reconciliation.
                // Never pretend a failed durable commit succeeded locally.
                deliveryError = error
                backupLog.error("upload receipt could not be saved: \(error)")
            }
        }
        if let continuation {
            if let deliveryError {
                continuation.resume(throwing: deliveryError)
            } else if (200..<300).contains(status) {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: ImmichError.http(status, Self.message(from: data)))
            }
        }
        Task { await replayReceipts() }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock {
            defer { backgroundCompletion = nil }
            if backgroundCompletion == nil { finishedEventsAwaitingHandler = true }
            return backgroundCompletion
        }
        if let completion { finishBackgroundEvents(completion) }
    }

    private func finishBackgroundEvents(_ completion: LaunchCompletion) {
        // All delegate events preceding this callback have durable receipts.
        // Apply/flush now if possible; unavailable accounts retain the journal.
        Task {
            await replayReceipts()
            await MainActor.run { completion.run() }
        }
    }

    // MARK: - helpers

    private static func encode(_ ticket: Ticket) -> String? {
        guard let data = try? JSONEncoder().encode(ticket) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decode(_ description: String?) -> Ticket? {
        guard let description else { return nil }
        return try? JSONDecoder().decode(Ticket.self, from: Data(description.utf8))
    }

    private static func message(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = object["message"] as? String { return message }
            if let messages = object["message"] as? [String] { return messages.joined(separator: "\n") }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
