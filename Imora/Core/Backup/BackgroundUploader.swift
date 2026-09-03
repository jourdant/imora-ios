import Foundation
import os

/// every asset upload goes through one background url session, so a transfer
/// handed to the system finishes even after the app is suspended or killed.
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
    }

    struct Completion: Sendable {
        let ticket: Ticket
        let remoteId: String
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
    private var orphanHandler: (@Sendable (Completion) -> Void)?
    private var backgroundCompletion: LaunchCompletion?
    /// completions that arrived before anything was listening, e.g. during a
    /// relaunch where the delegate beat the signed-in account.
    private var pendingOrphans: [Completion] = []

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

    func setOrphanHandler(_ handler: (@Sendable (Completion) -> Void)?) {
        let queued = lock.withLock { () -> [Completion] in
            orphanHandler = handler
            guard handler != nil else { return [] }
            defer { pendingOrphans = [] }
            return pendingOrphans
        }
        for completion in queued { handler?(completion) }
    }

    /// stored by the app delegate when the system relaunches us to deliver
    /// finished transfers; calling it is what lets the app suspend again.
    func setBackgroundCompletionHandler(_ handler: LaunchCompletion) {
        lock.withLock { backgroundCompletion = handler }
    }

    // MARK: - uploading

    func upload(
        _ request: URLRequest,
        fromFile bodyURL: URL,
        ticket: Ticket,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> Data {
        let task = session.uploadTask(with: request, fromFile: bodyURL)
        task.taskDescription = Self.encode(ticket)
        let id = task.taskIdentifier
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // registered before the task runs, or a fast failure would find
                // nothing to resume and be replayed as an orphan instead.
                lock.withLock {
                    continuations[id] = continuation
                    progressHandlers[id] = onProgress
                }
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.cancel(taskIdentifier: id)
        }
    }

    private func cancel(taskIdentifier: Int) {
        session.getAllTasks { tasks in
            tasks.first { $0.taskIdentifier == taskIdentifier }?.cancel()
        }
    }

    func cancelAll() {
        session.getAllTasks { tasks in
            for task in tasks { task.cancel() }
        }
    }

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
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let handler = lock.withLock { progressHandlers[task.taskIdentifier] }
        handler?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let id = task.taskIdentifier
        let ticket = Self.decode(task.taskDescription)
        let (continuation, data) = lock.withLock { () -> (CheckedContinuation<Data, any Error>?, Data) in
            let continuation = continuations.removeValue(forKey: id)
            let data = buffers.removeValue(forKey: id) ?? Data()
            progressHandlers[id] = nil
            return (continuation, data)
        }
        if let ticket {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: ticket.bodyPath))
        }

        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if let continuation {
            if let error {
                continuation.resume(throwing: error)
            } else if (200..<300).contains(status) {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: ImmichError.http(status, Self.message(from: data)))
            }
            return
        }

        // nobody is waiting: this finished while the app was away. a failure
        // needs no repair - the next run re-uploads it - but a success has to
        // reach the index or the bytes would be sent twice.
        guard let ticket, error == nil, (200..<300).contains(status),
              let result = try? JSONDecoder().decode(AssetUploadResult.self, from: data)
        else { return }
        deliverOrphan(Completion(ticket: ticket, remoteId: result.id))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock {
            defer { backgroundCompletion = nil }
            return backgroundCompletion
        }
        // the system expects this on the main thread before it suspends us.
        if let completion { DispatchQueue.main.async { completion.run() } }
    }

    // MARK: - helpers

    private func deliverOrphan(_ completion: Completion) {
        let handler = lock.withLock { () -> (@Sendable (Completion) -> Void)? in
            guard let orphanHandler else {
                pendingOrphans.append(completion)
                return nil
            }
            return orphanHandler
        }
        handler?(completion)
    }

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
