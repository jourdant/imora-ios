import Foundation

/// Pure byte and item accounting for one continued-processing run. URLSession
/// may replay or deliver out-of-order delegate values, so sent bytes only move
/// forward and never exceed the request body size.
nonisolated struct ShareUploadProgressState {
    struct Snapshot: Equatable, Sendable {
        let completedItems: Int
        let totalItems: Int
        let completedBytes: Int64
        let totalBytes: Int64
    }

    private struct Upload: Sendable {
        let expectedBytes: Int64
        var sentBytes: Int64
    }

    private var uploads: [String: Upload] = [:]
    private var finishedBytes: Int64 = 0
    private(set) var uploaded = 0
    private(set) var failed = 0

    var snapshot: Snapshot {
        let pendingBytes = uploads.values.reduce(Int64(0)) { $0 + $1.expectedBytes }
        let sentBytes = uploads.values.reduce(Int64(0)) { $0 + $1.sentBytes }
        let completedItems = uploaded + failed
        return Snapshot(
            completedItems: completedItems,
            totalItems: completedItems + uploads.count,
            completedBytes: finishedBytes + sentBytes,
            totalBytes: finishedBytes + pendingBytes
        )
    }

    var isComplete: Bool { uploads.isEmpty && uploaded + failed > 0 }
    var hasUploads: Bool { !uploads.isEmpty }

    mutating func register(key: String, expectedBytes: Int64) {
        guard uploads[key] == nil else { return }
        uploads[key] = Upload(expectedBytes: max(1, expectedBytes), sentBytes: 0)
    }

    mutating func recordSent(key: String, totalBytesSent: Int64) {
        guard var upload = uploads[key] else { return }
        upload.sentBytes = min(
            upload.expectedBytes,
            max(upload.sentBytes, totalBytesSent)
        )
        uploads[key] = upload
    }

    mutating func complete(key: String, succeeded: Bool) {
        guard let upload = uploads.removeValue(forKey: key) else { return }
        finishedBytes += upload.expectedBytes
        if succeeded {
            uploaded += 1
        } else {
            failed += 1
        }
    }
}
