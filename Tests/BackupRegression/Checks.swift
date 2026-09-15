import Foundation
import os

let testDirectory = FileManager.default.temporaryDirectory.appending(path: "imora-cancellation-\(UUID())")
let backupLog = Logger(subsystem: "imora.cancellation-check", category: "test")
// UI/PhotoKit types are not used by these checks. The real BackupEntry,
// BackupIndex, UploadJournal and BackupIntentStore are compiled by run.py.
struct DeviceAsset: Sendable { let localIdentifier: String; let modificationDate: Date? }
struct BackupLibraryStatus { init(assets: [DeviceAsset], entries: [String: BackupEntry]) {} }
struct AssetUploadResult: Codable { let id: String }
enum ImmichError: Error { case http(Int, String) }
final class ProcessLease: Sendable { func release() {} }

final class ProtocolState: @unchecked Sendable {
    let lock = NSLock()
    var active: [String: ControlledProtocol] = [:]
    var stopped: Set<String> = []
    func lookup(_ id: String) -> ControlledProtocol? { lock.withLock { active[id] } }
    func wasStopped(_ id: String) -> Bool { lock.withLock { stopped.contains(id) } }
}

final class ControlledProtocol: URLProtocol, @unchecked Sendable {
    static let state = ProtocolState()
    private let endingLock = NSLock()
    private var ended = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.lock.withLock { Self.state.active[request.url!.lastPathComponent] = self }
    }
    override func stopLoading() {
        endingLock.withLock { ended = true }
        _ = Self.state.lock.withLock { Self.state.stopped.insert(request.url!.lastPathComponent) }
    }
    func finish(status: Int = 200, body: String = "{\"id\":\"remote\"}", networkError: URLError? = nil) {
        let shouldFinish = endingLock.withLock { if ended { return false }; ended = true; return true }
        guard shouldFinish else { return }
        if let networkError {
            client?.urlProtocol(self, didFailWithError: networkError)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main struct Check {
    enum Outcome: Equatable { case success, cancelled, http(Int), error }
    static func waitUntil(_ label: String, _ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Timed out: \(label)")
    }

    static func start(_ id: String, lifetime: BackgroundUploader.RunLifetime? = nil) -> Task<Outcome, Never> {
        Task {
            do {
                let body = testDirectory.appending(path: id)
                try Data("test body".utf8).write(to: body)
                var request = URLRequest(url: URL(string: "https://test.invalid/\(id)")!)
                request.httpMethod = "POST"
                _ = try await BackgroundUploader.shared.upload(request, fromFile: body,
                    ticket: .init(account: "test", localId: id, isMotion: false, bodyPath: body.path),
                    lifetime: lifetime, onProgress: nil)
                return .success
            } catch is CancellationError { return .cancelled }
            catch ImmichError.http(let code, _) { return .http(code) }
            catch { return .error }
        }
    }

    static func main() async throws {
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let lifetime = BackgroundUploader.RunLifetime()
        let preserved = start("expired", lifetime: lifetime)
        try await waitUntil("upload started") { ControlledProtocol.state.lookup("expired") != nil }
        lifetime.expire()
        preserved.cancel()
        let detached = await preserved.value
        precondition(detached == .cancelled, "Expired waiter did not return cancellation")
        precondition(!ControlledProtocol.state.wasStopped("expired"), "Budget expiration stopped transfer")
        ControlledProtocol.state.lookup("expired")!.finish()
        let journal = UploadJournal(directory: testDirectory.appending(path: "journal"))
        try await waitUntil("durable orphan receipt") { journal.receipts().contains { $0.ticket.localId == "expired" } }

        let cancelled = start("explicit")
        try await waitUntil("explicit upload started") { ControlledProtocol.state.lookup("explicit") != nil }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        precondition(cancelledResult == .cancelled)
        try await waitUntil("explicit transfer cancelled") { ControlledProtocol.state.wasStopped("explicit") }

        let refused = start("already-expired", lifetime: lifetime)
        let refusedResult = await refused.value
        precondition(refusedResult == .cancelled)
        precondition(ControlledProtocol.state.lookup("already-expired") == nil, "Expired run started another transfer")

        let next = start("next-run", lifetime: BackgroundUploader.RunLifetime())
        try await waitUntil("next run started") { ControlledProtocol.state.lookup("next-run") != nil }
        next.cancel()
        let nextResult = await next.value
        precondition(nextResult == .cancelled)
        try await waitUntil("next run cancels normally") { ControlledProtocol.state.wasStopped("next-run") }
        print("PASS: expiry detaches promptly, transfer survives and journals completion, explicit cancellation stops transfer, expired run cannot start transfers, next run cancels independently")
        try await additionalUploaderChecks(journal: journal)
        try await indexAndIntentChecks()
    }

    static func additionalUploaderChecks(journal: UploadJournal) async throws {
        let lifetime = BackgroundUploader.RunLifetime()
        let tasks = (0..<12).map { start("parallel-\($0)", lifetime: lifetime) }
        try await waitUntil("concurrent starts") { (0..<12).allSatisfy { ControlledProtocol.state.lookup("parallel-\($0)") != nil } }
        lifetime.expire()
        for task in tasks { task.cancel() }
        for task in tasks { let result = await task.value; precondition(result == .cancelled) }
        for i in 0..<12 {
            precondition(!ControlledProtocol.state.wasStopped("parallel-\(i)"))
            ControlledProtocol.state.lookup("parallel-\(i)")!.finish()
        }
        try await waitUntil("all orphan receipts") { journal.receipts().filter { $0.ticket.localId.hasPrefix("parallel-") }.count == 12 }
        print("PASS: 12 concurrent uploads detach and persist all orphan receipts")

        let cancelLifetime = BackgroundUploader.RunLifetime()
        let held = start("cancel-after-expiry", lifetime: cancelLifetime)
        try await waitUntil("cancel after expiry start") { ControlledProtocol.state.lookup("cancel-after-expiry") != nil }
        cancelLifetime.expire(); held.cancel()
        let heldResult = await held.value
        precondition(heldResult == .cancelled)
        BackgroundUploader.shared.cancelAll()
        try await waitUntil("cancelAll stops detached transfer") { ControlledProtocol.state.wasStopped("cancel-after-expiry") }
        print("PASS: cancelAll stops an already-detached transfer")

        for (name, status, network) in [("http-error", 503, false), ("network-error", 200, true)] {
            let task = start(name)
            try await waitUntil(name) { ControlledProtocol.state.lookup(name) != nil }
            ControlledProtocol.state.lookup(name)!.finish(status: status, networkError: network ? URLError(.networkConnectionLost) : nil)
            let result = await task.value
            precondition(result == (network ? .error : .http(status)))
            precondition(!journal.receipts().contains { $0.ticket.localId == name })
        }
        print("PASS: server rejection and connection loss produce errors, not success receipts")

        // Fail the durable commit after successful prepare, independent of user
        // permissions: replace the journal directory with a regular file.
        let task = start("receipt-write-failure")
        try await waitUntil("write failure started") { ControlledProtocol.state.lookup("receipt-write-failure") != nil }
        let path = testDirectory.appending(path: "journal")
        let saved = testDirectory.appending(path: "journal-saved")
        try FileManager.default.moveItem(at: path, to: saved)
        try Data().write(to: path)
        ControlledProtocol.state.lookup("receipt-write-failure")!.finish()
        let writeResult = await task.value
        precondition(writeResult == .error)
        precondition(FileManager.default.fileExists(atPath: testDirectory.appending(path: "receipt-write-failure").path))
        try FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: saved, to: path)
        precondition(!journal.receipts().contains { $0.ticket.localId == "receipt-write-failure" })
        print("PASS: receipt-write failure is surfaced and retains the upload body")

        for i in 0..<50 {
            let name = "race-\(i)"
            let task = start(name)
            try await waitUntil(name) { ControlledProtocol.state.lookup(name) != nil }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { task.cancel() }
                group.addTask { ControlledProtocol.state.lookup(name)!.finish() }
            }
            let result = await task.value
            precondition(result == .success || result == .cancelled)
        }
        for i in 0..<50 {
            let task = start("early-cancel-\(i)")
            task.cancel()
            let result = await task.value
            precondition(result == .cancelled)
        }
        print("PASS: 50 completion/cancellation races and 50 immediate cancellations finish without double resumes or hangs")

        let reopened = UploadJournal(directory: path)
        let receipt = reopened.receipts().first { $0.ticket.localId == "expired" }!
        reopened.acknowledge(receipt.ticket)
        precondition(!UploadJournal(directory: path).receipts().contains { $0.ticket.localId == "expired" })
        print("PASS: receipts survive journal reconstruction; acknowledgement persists")

        let replayLifetime = BackgroundUploader.RunLifetime()
        let orphan = start("deferred-replay", lifetime: replayLifetime)
        try await waitUntil("deferred replay start") { ControlledProtocol.state.lookup("deferred-replay") != nil }
        replayLifetime.expire(); orphan.cancel()
        let detached = await orphan.value
        precondition(detached == .cancelled)
        ControlledProtocol.state.lookup("deferred-replay")!.finish()
        try await waitUntil("deferred receipt saved") { journal.receipts().contains { $0.ticket.localId == "deferred-replay" } }
        BackgroundUploader.shared.setOrphanHandler { _ in false }
        await BackgroundUploader.shared.replayReceipts()
        precondition(journal.receipts().contains { $0.ticket.localId == "deferred-replay" })
        BackgroundUploader.shared.setOrphanHandler { $0.ticket.localId == "deferred-replay" }
        try await waitUntil("accepted receipt acknowledged") { !journal.receipts().contains { $0.ticket.localId == "deferred-replay" } }
        BackgroundUploader.shared.setOrphanHandler(nil)
        print("PASS: unavailable receipt consumer retains recovery data until a later consumer accepts it")
    }

    static func indexAndIntentChecks() async throws {
        let indexURL = testDirectory.appending(path: "index.json")
        let index = BackupIndex(fileURL: indexURL)
        let loaded = await index.load(serverHost: "test", userId: "user")
        precondition(loaded)
        let date = Date(timeIntervalSince1970: 100)
        let source = BackupEntry(modificationDate: date, isLivePhoto: true, primaryChecksum: "still", motionChecksum: "motion")
        func receipt(_ motion: Bool) -> BackgroundUploader.Completion {
            .init(ticket: .init(account: "test|user", localId: "live", isMotion: motion, bodyPath: "", source: source), remoteId: motion ? "motion-remote" : "still-remote")
        }
        let motionApplied = await index.applyReceipt(receipt(true))
        precondition(motionApplied)
        let motionOnly = await index.entry(for: "live")!
        precondition(!motionOnly.isBackedUp && motionOnly.motionRemoteId == "motion-remote")
        let reopened = BackupIndex(fileURL: indexURL)
        let reloaded = await reopened.load(serverHost: "test", userId: "user")
        precondition(reloaded)
        let stillApplied = await reopened.applyReceipt(receipt(false))
        precondition(stillApplied)
        let complete = await reopened.entry(for: "live")!
        precondition(complete.isBackedUp && complete.motionRemoteId == "motion-remote")
        let repeated = await reopened.applyReceipt(receipt(true))
        precondition(repeated)
        await reopened.setHashed(localId: "live", isLivePhoto: true, primaryChecksum: "edited", motionChecksum: "edited-motion", modificationDate: date.addingTimeInterval(1))
        let ignored = await reopened.applyReceipt(receipt(false))
        precondition(ignored)
        let edited = await reopened.entry(for: "live")!
        precondition(edited.primaryRemoteId == nil && edited.primaryChecksum == "edited")
        print("PASS: Live Photo motion survives index reload, still completes pairing, repeated receipts are safe, stale receipts cannot bind edited bytes")

        let journalURL = testDirectory.appending(path: "intents.json")
        let intents = await BackupIntentStore(url: journalURL)
        let saved = await intents.set(true, account: "test|user")
        precondition(saved)
        let newIntents = await BackupIntentStore(url: journalURL)
        let retained = await newIntents.contains("test|user")
        let unrelated = await newIntents.contains("test|different-user")
        precondition(retained && !unrelated)
        let cleared = await newIntents.set(false, account: "test|user")
        precondition(cleared)
        let afterClear = await BackupIntentStore(url: journalURL)
        let absent = await afterClear.contains("test|user")
        precondition(!absent)
        print("PASS: unfinished intent survives reload, remains account-scoped, and explicit clear persists")

        let directory = testDirectory.appending(path: "index-failure")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let retryIndex = BackupIndex(fileURL: directory.appending(path: "index.json"))
        let ready = await retryIndex.load(serverHost: "test", userId: "user")
        precondition(ready)
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        let failed = await retryIndex.applyReceipt(receipt(true))
        precondition(!failed, "Index must not acknowledge a receipt when its durable write fails")
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let retried = await retryIndex.applyReceipt(receipt(true))
        precondition(retried)
        let readBack = BackupIndex(fileURL: directory.appending(path: "index.json"))
        let readable = await readBack.load(serverHost: "test", userId: "user")
        precondition(readable)
        let restored = await readBack.entry(for: "live")
        precondition(restored?.motionRemoteId == "motion-remote")
        print("PASS: index write failure refuses acknowledgement; replay succeeds after storage recovers")

        let corruptURL = testDirectory.appending(path: "corrupt-intents.json")
        try Data("invalid json".utf8).write(to: corruptURL)
        let corrupt = await BackupIntentStore(url: corruptURL)
        let refused = await corrupt.set(true, account: "test|user")
        precondition(!refused)
        let retainedData = try Data(contentsOf: corruptURL)
        precondition(retainedData == Data("invalid json".utf8))
        print("PASS: unreadable intent storage refuses mutation instead of overwriting recovery data")
    }
}
