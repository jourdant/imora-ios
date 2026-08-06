import BackgroundTasks
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Turns shared media into uploads. When the system grants continued
/// processing, the extension that submitted the request also owns the session
/// and reports its bytes. If the request is declined, the original daemon-owned
/// background-session path remains the fallback.
nonisolated enum ShareUploader {
    struct Prepared: Sendable {
        let bodyURL: URL
        let filename: String
        let checksum: String
        let boundary: String
    }

    // MARK: - staging

    /// builds one finished multipart body in the app group for one provider.
    /// all of it happens inside the load callback because the url it hands
    /// over is only valid there.
    static func prepare(_ provider: NSItemProvider, deviceId: String) async -> Prepared? {
        let isVideo = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
        let type: UTType = isVideo ? .movie : .image
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                guard let url, let directory = ShareTransfer.bodyDirectory else {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: buildBody(from: url, deviceId: deviceId, in: directory))
            }
        }
    }

    private static func buildBody(from url: URL, deviceId: String, in directory: URL) -> Prepared? {
        guard let checksum = try? sha1Base64(ofFile: url) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let created = attributes?[.creationDate] as? Date
            ?? attributes?[.modificationDate] as? Date
            ?? Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let id = UUID().uuidString
        let fields: [(name: String, value: String)] = [
            ("deviceAssetId", "share-\(id)"),
            ("deviceId", deviceId),
            ("fileCreatedAt", iso.string(from: created)),
            ("fileModifiedAt", iso.string(from: created)),
            ("isFavorite", "false"),
            ("duration", "0"),
        ]
        let boundary = "imora-\(id)"
        guard let bodyURL = try? MultipartBody.makeBodyFile(
            fields: fields,
            fileField: "assetData",
            filename: url.lastPathComponent,
            contentsOf: url,
            boundary: boundary,
            in: directory
        ) else { return nil }
        return Prepared(
            bodyURL: bodyURL,
            filename: url.lastPathComponent,
            checksum: checksum,
            boundary: boundary
        )
    }

    /// streaming sha1 of the staged file, the checksum the server dedups on.
    private static func sha1Base64(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        // each bridged chunk comes back autoreleased - drained per iteration,
        // or hashing accumulates the whole file and a large video kills the
        // extension at its memory cap before anything is enqueued.
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return Data(hasher.finalize()).base64EncodedString()
    }

    // MARK: - handoff

    /// Stages the workload before submission so the extension launch handler
    /// can see it immediately. The handler may run before the async submission
    /// call returns.
    @concurrent
    static func handOff(_ items: [Prepared], credentials: ShareTransfer.Credentials) async -> Bool {
        guard !items.isEmpty else { return false }
        let batch = ShareUploadActivity.Batch(items: items, credentials: credentials)
        switch ShareUploadActivity.shared.stage(batch) {
        case .joinedExistingRequest:
            return true
        case .progressUnavailable:
            return false
        case .submitRequest(let identifier):
            let accepted = await requestProgress(identifier: identifier, count: items.count)
            return await ShareUploadActivity.shared.waitForActivity(
                identifier: identifier,
                accepted: accepted
            )
        }
    }

    /// Asks for the Live Activity that represents the extension-owned upload.
    /// Failing fast preserves the reliable URLSession-only fallback.
    private static func requestProgress(identifier: String, count: Int) async -> Bool {
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Uploading to Imora",
            subtitle: count == 1 ? "1 item" : "\(count) items"
        )
        request.strategy = .fail
        do {
            if #available(iOS 27.0, *) {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } else {
                try BGTaskScheduler.shared.submit(request)
            }
            return true
        } catch {
            return false
        }
    }
}
