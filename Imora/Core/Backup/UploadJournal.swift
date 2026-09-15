import Foundation

/// Small atomic records, separate from the large regenerable multipart bodies.
/// No credentials are written here. The URLSession task description carries the
/// same source proof, so older prepared records can be reconciled by checksum.
nonisolated final class UploadJournal: @unchecked Sendable {
    private struct Record: Codable {
        var ticket: BackgroundUploader.Ticket
        var completion: BackgroundUploader.Completion?
    }
    private struct Failure: Codable {
        var date: Date
        var account: String
        var localId: String
        var status: Int
        var errorCode: Int?
        var cancellationReason: Int?
    }
    private let lock = NSLock()
    private let directory: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "imora/upload-journal")) {
        self.directory = directory
    }

    private func url(_ ticket: BackgroundUploader.Ticket) -> URL {
        // Legacy tasks have no UUID; their body filename was already unique.
        let key = ticket.id?.uuidString ?? URL(fileURLWithPath: ticket.bodyPath).lastPathComponent
        return directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func prepare(_ ticket: BackgroundUploader.Ticket) throws {
        try lock.withLock { try write(Record(ticket: ticket), to: url(ticket)) }
    }

    private func responseURL(_ ticket: BackgroundUploader.Ticket) -> URL {
        url(ticket).appendingPathExtension("response")
    }

    /// Response callbacks may straddle process launches too. Keep their small
    /// JSON payload on disk until the completed receipt replaces it.
    func appendResponse(_ data: Data, ticket: BackgroundUploader.Ticket) throws {
        try lock.withLock {
            let target = responseURL(ticket)
            var response: Data
            do { response = try Data(contentsOf: target) }
            catch CocoaError.fileReadNoSuchFile { response = Data() }
            response.append(data)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try response.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    func response(for ticket: BackgroundUploader.Ticket) -> Data? {
        lock.withLock { try? Data(contentsOf: responseURL(ticket)) }
    }

    func complete(_ completion: BackgroundUploader.Completion) throws {
        try lock.withLock {
            try write(Record(ticket: completion.ticket, completion: completion), to: url(completion.ticket))
            try? FileManager.default.removeItem(at: responseURL(completion.ticket))
        }
    }

    func recordFailure(_ ticket: BackgroundUploader.Ticket, status: Int, error: (any Error)?) throws {
        try lock.withLock {
            let error = error as NSError?
            // Keep only the latest diagnostic; retry authority is the saved run
            // intent and the index, not an ever-growing failed-transfer queue.
            try write(Failure(date: Date(), account: ticket.account, localId: ticket.localId,
                              status: status, errorCode: error?.code,
                              cancellationReason: error?.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int),
                      to: directory.appendingPathComponent("last-failure.json"))
            try? FileManager.default.removeItem(at: url(ticket))
            try? FileManager.default.removeItem(at: responseURL(ticket))
        }
    }

    func receipts() -> [BackgroundUploader.Completion] {
        lock.withLock {
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                        includingPropertiesForKeys: nil)) ?? []
            return urls.compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
                return record.completion
            }
        }
    }

    func acknowledge(_ ticket: BackgroundUploader.Ticket) {
        lock.withLock { _ = try? FileManager.default.removeItem(at: url(ticket)) }
    }
}
