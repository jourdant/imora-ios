import Foundation
import ImageIO
import Observation
import UIKit

/// uploads what the share extension staged in the app group. transfers go
/// through the same background session the backup uses, so leaving the app does
/// not stop them, and the run drives the system progress ui.
@Observable
final class ShareUploadModel {
    nonisolated enum ItemState: Equatable, Sendable {
        case waiting
        case uploading(Double)
        case uploaded
        case duplicate
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .uploaded, .duplicate, .failed: true
            default: false
            }
        }

        /// what the row shows on the trailing edge.
        var fraction: Double {
            switch self {
            case .waiting: 0
            case .uploading(let value): value
            case .uploaded, .duplicate, .failed: 1
            }
        }
    }

    struct Row: Identifiable {
        let id: String
        let filename: String
        let isVideo: Bool
        let url: URL
        let thumbnail: UIImage?
        var state: ItemState = .waiting
    }

    private(set) var rows: [Row] = []
    private(set) var isRunning = false
    /// true once a run has finished, which is what turns the footer into the
    /// view photos button.
    private(set) var isFinished = false

    var onContinuedProgress: (() -> Void)?

    private static let workers = 3

    private let client: ImmichClient
    private var batches: [ShareBatch] = []
    private var runTask: Task<Void, Never>?

    init(client: ImmichClient) {
        self.client = client
    }

    var hasWork: Bool { !rows.isEmpty }
    var uploadedCount: Int { rows.count { $0.state == .uploaded || $0.state == .duplicate } }
    var failedCount: Int { rows.count { if case .failed = $0.state { return true } else { return false } } }

    // MARK: - loading

    /// picks up anything the extension left behind. a run in flight is left
    /// alone so a second share does not restart it mid-upload.
    func reload() {
        guard !isRunning else { return }
        let batches = ShareInbox.batches()
        guard !batches.isEmpty else { return }
        self.batches = batches
        rows = batches.flatMap { batch in
            batch.items.compactMap { item -> Row? in
                guard let url = ShareInbox.fileURL(for: item),
                      FileManager.default.fileExists(atPath: url.path)
                else { return nil }
                return Row(
                    id: item.id,
                    filename: item.filename,
                    isVideo: item.isVideo,
                    url: url,
                    thumbnail: item.isVideo ? nil : Self.thumbnail(for: url)
                )
            }
        }
        isFinished = false
    }

    // MARK: - running

    func start() {
        guard !isRunning, hasWork else { return }
        runTask = Task { await run() }
    }

    func cancel() {
        runTask?.cancel()
    }

    func runToCompletion() async {
        if !isRunning { start() }
        await runTask?.value
    }

    /// the staged copies are gone either way once a row is done - the uploader
    /// consumes the file - so the descriptors go with them.
    func clearFinished() {
        for batch in batches { ShareInbox.remove(batch) }
        batches = []
        rows = []
        isFinished = false
    }

    private func run() async {
        isRunning = true
        onContinuedProgress?()
        let client = client
        let account = SessionCache.accountKey(host: client.apiURL.host() ?? "")
        let deviceId = DeviceID.current
        let report: @Sendable (String, Double) -> Void = { [weak self] id, fraction in
            guard let model = self else { return }
            Task { @MainActor in model.note(id, .uploading(fraction)) }
        }

        let queue = rows.map { Upload(id: $0.id, url: $0.url, filename: $0.filename) }
        await withTaskGroup(of: (String, ItemState).self) { group in
            var next = 0
            @MainActor func addNext() {
                guard next < queue.count, !Task.isCancelled else { return }
                let upload = queue[next]
                next += 1
                note(upload.id, .uploading(0))
                group.addTask {
                    let state = await Self.send(
                        upload, client: client, account: account,
                        deviceId: deviceId, onProgress: report
                    )
                    return (upload.id, state)
                }
            }
            for _ in 0..<Self.workers { addNext() }
            while let (id, state) = await group.next() {
                note(id, state)
                addNext()
            }
        }

        isRunning = false
        isFinished = true
        onContinuedProgress?()
    }

    private func note(_ id: String, _ state: ItemState) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        // a late byte tick must not walk a finished row backwards.
        if rows[index].state.isFinished, case .uploading = state { return }
        rows[index].state = state
        onContinuedProgress?()
    }

    private nonisolated struct Upload: Sendable {
        let id: String
        let url: URL
        let filename: String
    }

    /// the server dedups on checksum, so a file that was already sent comes
    /// back as a duplicate rather than a second copy.
    @concurrent
    private nonisolated static func send(
        _ upload: Upload,
        client: ImmichClient,
        account: String,
        deviceId: String,
        onProgress: @escaping @Sendable (String, Double) -> Void
    ) async -> ItemState {
        guard let checksum = try? await PhotoLibraryService.sha1Base64(ofFile: upload.url) else {
            return .failed("could not read the file")
        }
        let created = (try? FileManager.default.attributesOfItem(atPath: upload.url.path)[.creationDate] as? Date)
            ?? Date()
        do {
            let result = try await client.uploadAsset(AssetUploadRequest(
                fileURL: upload.url,
                checksum: checksum,
                filename: upload.filename,
                deviceAssetId: "share-\(upload.id)",
                deviceId: deviceId,
                fileCreatedAt: created,
                fileModifiedAt: created,
                isFavorite: false,
                durationMs: 0
            ), account: account) { fraction in
                onProgress(upload.id, fraction)
            }
            return result.isDuplicate ? .duplicate : .uploaded
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - thumbnails

    /// decoded once at load: the file is consumed by the upload, so there is
    /// nothing left to read from by the time a row finishes.
    private static func thumbnail(for url: URL, maxPixel: CGFloat = 240) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}

// MARK: - continued processing

extension ShareUploadModel: ContinuedWorkload {
    var continuedTitle: String {
        isFinished ? (failedCount > 0 ? "Upload finished with errors" : "Upload complete") : "Uploading to Imora"
    }

    var continuedSubtitle: String {
        if isFinished, failedCount > 0 {
            return "\(uploadedCount) uploaded, \(failedCount) failed"
        }
        return "\(uploadedCount) of \(rows.count) uploaded"
    }

    var continuedFraction: Double {
        guard !rows.isEmpty else { return 0 }
        return rows.reduce(0) { $0 + $1.state.fraction } / Double(rows.count)
    }

    var continuedSucceeded: Bool { isFinished && failedCount == 0 }
}
