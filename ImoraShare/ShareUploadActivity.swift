@preconcurrency import BackgroundTasks
import Foundation
import os

/// Runs uploads independently from the optional system progress UI. A
/// continued-processing request can be accepted without its launch handler
/// arriving, so the request observes work that has already started; it never
/// gates the transfer itself.
nonisolated final class ShareUploadActivity: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = ShareUploadActivity()

    struct Batch: Sendable {
        let items: [ShareUploader.Prepared]
        let credentials: ShareTransfer.Credentials
    }

    enum StageDisposition {
        case submitRequest(identifier: String)
        case joinedExistingRequest
        case progressUnavailable
    }

    private struct Outcome: Sendable {
        let uploaded: Int
        let failed: Int
    }

    private static let log = Logger(
        subsystem: "com.vexcited.imora.share",
        category: "ShareUploadActivity"
    )

    private let queue = DispatchQueue(label: "com.vexcited.imora.share.progress")
    private let queueKey = DispatchSpecificKey<Void>()

    private var session: URLSession?
    private var sessionIdentifier: String?
    private var progress = ShareUploadProgressState()
    private var workByKey: [String: URL] = [:]

    private var requestIdentifier: String?
    private var awaitingRequest = false
    private var activity: BGContinuedProcessingTask?
    private var activityIdentifier: String?
    private var completedOutcomes: [String: Outcome] = [:]
    private var lastSnapshot: ShareUploadProgressState.Snapshot?
    private var lastSubtitle = ""

    private override init() {
        super.init()
        queue.setSpecific(key: queueKey, value: ())
    }

    /// Starts the durable URLSession transfer first, then decides whether a
    /// continued-processing request can be submitted to observe it.
    func stage(_ batch: Batch) -> StageDisposition {
        sync {
            beginUploadRunIfNeeded()
            enqueue(batch)

            if activity != nil {
                reportProgress()
                return .joinedExistingRequest
            }
            if awaitingRequest { return .joinedExistingRequest }
            guard let identifier = registerProgressRequest() else {
                return .progressUnavailable
            }
            requestIdentifier = identifier
            awaitingRequest = true
            return .submitRequest(identifier: identifier)
        }
    }

    /// An accepted request and its launch handler are two separate daemon
    /// stages. Wait briefly for the handler so the share sheet doesn't promise
    /// a notification that never appeared, then cancel that UI request only;
    /// the upload continues on its already-running background session.
    @concurrent
    func waitForActivity(identifier: String, accepted: Bool) async -> Bool {
        guard accepted else {
            clearRequest(identifier: identifier, cancel: false)
            return false
        }
        for _ in 0..<15 {
            if sync({ activityIdentifier == identifier }) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if sync({ activityIdentifier == identifier }) { return true }
        clearRequest(identifier: identifier, cancel: true)
        Self.log.error("continued-processing handler did not arrive; upload remains active")
        return false
    }

    private func registerProgressRequest() -> String? {
        guard let identifier = ShareTransfer.makeUploadTaskIdentifier() else { return nil }
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: queue
        ) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.attach(task, identifier: identifier)
        }
        guard registered else {
            Self.log.error("continued-processing registration was rejected")
            return nil
        }
        return identifier
    }

    private func attach(_ task: BGContinuedProcessingTask, identifier: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard activity == nil else {
            complete(task, outcome: Outcome(uploaded: 0, failed: 0))
            return
        }
        if let outcome = completedOutcomes.removeValue(forKey: identifier) {
            complete(task, outcome: outcome)
            clearRequestState(identifier: identifier)
            return
        }
        guard requestIdentifier == identifier, progress.hasUploads else {
            complete(task, outcome: Outcome(uploaded: 0, failed: 0))
            return
        }

        awaitingRequest = false
        activity = task
        activityIdentifier = identifier
        task.expirationHandler = { [weak self] in
            self?.queue.async {
                guard let self, self.activityIdentifier == identifier,
                      let task = self.activity
                else { return }
                self.expire(task, identifier: identifier)
            }
        }
        reportProgress()
        Self.log.info("continued-processing UI attached to active upload")
    }

    private func expire(_ task: BGContinuedProcessingTask, identifier: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        let snapshot = progress.snapshot
        task.updateTitle(
            "Upload continuing",
            subtitle: "Imora will report when the transfer finishes"
        )
        task.progress.totalUnitCount = max(1, snapshot.totalBytes)
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.setTaskCompleted(success: true)
        activity = nil
        activityIdentifier = nil
        clearRequestState(identifier: identifier)
        Self.log.info("continued-processing UI expired; URLSession upload continues")
    }

    private func clearRequest(identifier: String, cancel: Bool) {
        sync {
            guard requestIdentifier == identifier, activityIdentifier != identifier else { return }
            if cancel {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            }
            completedOutcomes.removeValue(forKey: identifier)
            clearRequestState(identifier: identifier)
        }
    }

    private func clearRequestState(identifier: String) {
        guard requestIdentifier == identifier else { return }
        awaitingRequest = false
        requestIdentifier = nil
    }

    // MARK: - uploads

    private func beginUploadRunIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard session == nil else { return }

        progress = ShareUploadProgressState()
        lastSnapshot = nil
        lastSubtitle = ""
        let identifier = ShareTransfer.sessionPrefix + UUID().uuidString
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sharedContainerIdentifier = ShareTransfer.appGroup
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        sessionIdentifier = identifier
        ShareTransfer.markSession(identifier)
    }

    private func enqueue(_ batch: Batch) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let session else { return }
        for item in batch.items {
            var request = URLRequest(url: batch.credentials.apiURL.appending(path: "assets"))
            request.httpMethod = "POST"
            request.setValue(
                MultipartBody.contentType(boundary: item.boundary),
                forHTTPHeaderField: "Content-Type"
            )
            request.setValue(item.checksum, forHTTPHeaderField: "x-immich-checksum")
            request.setValue(
                "Bearer \(batch.credentials.token)",
                forHTTPHeaderField: "Authorization"
            )
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let upload = session.uploadTask(with: request, fromFile: item.bodyURL)
            upload.taskDescription = ShareTransfer.encode(
                ShareTicket(bodyPath: item.bodyURL.path, filename: item.filename)
            )
            let key = Self.progressKey(session, upload)
            progress.register(key: key, expectedBytes: Self.fileSize(at: item.bodyURL))
            workByKey[key] = item.bodyURL
            upload.resume()
        }
        Self.log.info("background upload started before progress request")
    }

    private func reportProgress() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let activity else { return }
        let snapshot = progress.snapshot
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot

        activity.progress.totalUnitCount = max(1, snapshot.totalBytes)
        activity.progress.completedUnitCount = min(
            activity.progress.totalUnitCount,
            snapshot.completedBytes
        )
        let subtitle = "\(snapshot.completedItems) of \(snapshot.totalItems) uploaded"
        if subtitle != lastSubtitle {
            lastSubtitle = subtitle
            activity.updateTitle("Uploading to Imora", subtitle: subtitle)
        }
    }

    private func finishIfComplete() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard progress.isComplete else { return }
        reportProgress()

        let outcome = Outcome(uploaded: progress.uploaded, failed: progress.failed)
        if let activity, let activityIdentifier {
            complete(activity, outcome: outcome)
            clearRequestState(identifier: activityIdentifier)
        } else if let requestIdentifier, awaitingRequest {
            completedOutcomes[requestIdentifier] = outcome
        }

        if let sessionIdentifier { ShareTransfer.unmarkSession(sessionIdentifier) }
        session?.finishTasksAndInvalidate()
        session = nil
        sessionIdentifier = nil
        workByKey.removeAll()
        activity = nil
        activityIdentifier = nil
        progress = ShareUploadProgressState()
        lastSnapshot = nil
        lastSubtitle = ""
        Self.log.info("upload finished: \(outcome.uploaded) uploaded, \(outcome.failed) failed")
    }

    private func complete(_ task: BGContinuedProcessingTask, outcome: Outcome) {
        let succeeded = outcome.failed == 0
        let title = succeeded ? "Shared to Imora" : "Sharing finished with errors"
        var summary: [String] = []
        if outcome.uploaded > 0 { summary.append("\(outcome.uploaded) uploaded") }
        if outcome.failed > 0 { summary.append("\(outcome.failed) failed") }
        task.updateTitle(title, subtitle: summary.joined(separator: ", "))
        task.progress.totalUnitCount = max(1, task.progress.totalUnitCount)
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.setTaskCompleted(success: succeeded)
    }

    private static func progressKey(_ session: URLSession, _ task: URLSessionTask) -> String {
        "\(session.configuration.identifier ?? "-")#\(task.taskIdentifier)"
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 1
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let key = Self.progressKey(session, task)
        queue.async { [weak self] in
            guard let self else { return }
            self.progress.recordSent(key: key, totalBytesSent: totalBytesSent)
            self.reportProgress()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError _: (any Error)?
    ) {
        let key = Self.progressKey(session, task)
        let ticket = ShareTransfer.decode(task.taskDescription)
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let succeeded = (200..<300).contains(statusCode)
        queue.async { [weak self] in
            guard let self else { return }
            self.workByKey.removeValue(forKey: key)
            if let ticket {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: ticket.bodyPath))
            }
            self.progress.complete(key: key, succeeded: succeeded)
            self.reportProgress()
            self.finishIfComplete()
        }
    }

    private func sync<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return operation() }
        return queue.sync(execute: operation)
    }
}
