#if DEBUG
import Foundation
import Photos
import UIKit

/// Temporary device probe. Only the newly created, marked fixture is gated.
/// Remove this file and the DEBUG hooks after physical-device validation.
nonisolated final class BackupExpiryDebug: @unchecked Sendable {
    static let shared = BackupExpiryDebug()
    private let lock = NSLock()
    private var localIds: Set<String> = []
    private var heldTasks: [URLSessionTask] = []
    private var capturedIds: Set<String> = []
    private var mode = "handoff"
    private var captured = false
    private var events: [String] = []
    @MainActor private weak var manager: BackupManager?
    @MainActor private var launched = false

    private let reportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "imora/backup-expiry-debug.txt")

    private init() {
        if ProcessInfo.processInfo.arguments.contains("--backup-expiry-debug=observe-relaunch") {
            localIds = (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: reportURL.appendingPathExtension("targets")))) ?? []
            events = ((try? String(contentsOf: reportURL, encoding: .utf8)) ?? "").components(separatedBy: "\n")
            mode = "observe-relaunch"
            record("observer-initialized pid=\(ProcessInfo.processInfo.processIdentifier)")
        }
    }

    func record(_ event: String, localId candidate: String? = nil) {
        lock.withLock {
            if let candidate, !localIds.contains(candidate) { return }
            events.append("\(Date().ISO8601Format()) \(event)\(candidate.map { " asset=\($0)" } ?? "") process=\(ProcessInfo.processInfo.processIdentifier)")
            try? FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? events.joined(separator: "\n").write(to: reportURL, atomically: true, encoding: .utf8)
        }
    }

    /// Handoff mode deliberately keeps the registered URLSession task suspended
    /// until the production expiry path has cancelled its Swift waiter.
    func holdAtHandoff(_ task: URLSessionTask, ticket: BackgroundUploader.Ticket) -> Bool {
        capture(task, ticket: ticket, at: "handoff", sent: 0, total: task.countOfBytesExpectedToSend)
    }

    func progress(_ task: URLSessionTask, ticket: BackgroundUploader.Ticket, sent: Int64, total: Int64) {
        guard sent > 0, sent < total else { return }
        _ = capture(task, ticket: ticket, at: "progress", sent: sent, total: total)
    }

    private func capture(_ task: URLSessionTask, ticket: BackgroundUploader.Ticket, at point: String, sent: Int64, total: Int64) -> Bool {
        let matches = lock.withLock {
            let expectedPoint = ["progress", "relaunch"].contains(mode) ? "progress" : "handoff"
            guard mode != "observe-relaunch" else { return false }
            guard localIds.contains(ticket.localId), !ticket.isMotion, expectedPoint == point,
                  !capturedIds.contains(ticket.localId) else { return false }
            capturedIds.insert(ticket.localId)
            captured = true
            heldTasks.append(task)
            return true
        }
        guard matches else { return false }
        if point == "progress" { task.suspend() }
        record("held task=\(task.taskIdentifier) point=\(point) sent=\(sent) total=\(total)", localId: ticket.localId)
        let ready = lock.withLock { heldTasks.count == (mode == "concurrent-restart" ? 3 : 1) }
        guard ready else {
            Task {
                try? await Task.sleep(for: .seconds(30))
                let incomplete = self.lock.withLock { self.heldTasks.count < 3 }
                if incomplete {
                    self.record("INCONCLUSIVE: concurrent upload barrier timed out")
                    task.resume()
                }
            }
            return true
        }
        let tasks = lock.withLock { heldTasks }
        Task { @MainActor in
            guard let manager = self.manager else {
                self.record("INCONCLUSIVE: manager unavailable")
                for task in tasks { task.resume() }
                return
            }
            manager.pauseForBackgroundExpiration()
            for task in tasks {
                self.record("expiry-returned task=\(task.taskIdentifier) state=\(task.state.rawValue)")
            }
            try? await Task.sleep(for: .seconds(1))
            let mode = self.lock.withLock { self.mode }
            if mode == "cancel-after-expiry" {
                self.record("explicit-cancel-requested")
                manager.cancel()
                // The original suspended task must report cancellation. Do not
                // resume it or conflate that result with the subsequent retry.
                try? await Task.sleep(for: .seconds(3))
                self.record("restart-after-cancel-requested")
                manager.start()
                return
            }
            if mode == "concurrent-restart" {
                self.record("restart-while-transfers-held")
                manager.start()
                try? await Task.sleep(for: .seconds(2))
            }
            if mode == "relaunch" {
                // Keep the task suspended until the host kills this process.
                // The new observer process must rediscover and resume it.
                self.record("ready-for-termination pid=\(ProcessInfo.processInfo.processIdentifier)")
                return
            }
            for task in tasks {
                self.record("resume-after-expiry task=\(task.taskIdentifier) state=\(task.state.rawValue)")
                task.resume()
            }
        }
        return true
    }

    @MainActor
    func runIfRequested(session: SessionStore) async {
        guard !launched, let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--backup-expiry-debug=") }) else { return }
        launched = true
        let requestedMode = String(argument.dropFirst("--backup-expiry-debug=".count))
        if requestedMode == "observe-relaunch" {
            let targets = lock.withLock { localIds }
            await BackgroundUploader.shared.debugResumeFixtureTasks(targets)
            return
        }
        guard ["handoff", "progress", "cancel-after-expiry", "concurrent-restart", "relaunch"].contains(requestedMode) else { return }
        lock.withLock { events = []; mode = requestedMode }
        record("start mode=\(requestedMode); production expiry method; no simulated OS scheduling")
        do {
            // Let launch reconciliation settle; avoid interrupting unrelated work.
            for _ in 0..<60 {
                if let backup = session.backup, !backup.isRunning, backup.libraryStatus?.pending == 0 {
                    manager = backup
                    break
                }
                try await Task.sleep(for: .seconds(1))
            }
            guard let manager else { throw ProbeError.message("Library must be idle and fully backed up before creating the fixture") }
            guard PhotoLibraryService.hasFullAccess else { throw ProbeError.message("Full photo access is required") }
            let image = try await recentImage()
            var urls: [URL] = []
            defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
            for _ in 0..<(requestedMode == "concurrent-restart" ? 3 : 1) {
                let url = try makeFixture(image: image, large: ["progress", "relaunch"].contains(requestedMode))
                urls.append(url)
                record("fixture-prepared bytes=\((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)")
            }
            try await saveFixtures(at: urls)
            let targets = lock.withLock { localIds }
            try JSONEncoder().encode(targets).write(to: reportURL.appendingPathExtension("targets"), options: .atomic)
            record("fixture-created; original photo unchanged")
            manager.start()
            // Do not change cancellation semantics if the probe cannot capture
            // progress. A missing ordered trace must remain inconclusive.
            try await Task.sleep(for: .seconds(90))
            let didCapture = lock.withLock { captured }
            if !didCapture { record("INCONCLUSIVE: no matching upload captured within 90 seconds") }
        } catch {
            record("INCONCLUSIVE: \(error.localizedDescription)")
        }
    }

    @concurrent
    private func saveFixtures(at urls: [URL]) async throws {
        // PhotoKit runs its change block on a private queue. Defining it in
        // this nonisolated context avoids inheriting the caller's MainActor.
        try await PHPhotoLibrary.shared().performChanges {
            for url in urls {
                let creation = PHAssetCreationRequest.forAsset()
                if self.lock.withLock({ self.mode == "concurrent-restart" }) {
                    // Recent captures intentionally use a serial priority lane.
                    // Put these fixtures before the persisted backlog boundary to
                    // exercise the three-worker backlog rather than that lane.
                    creation.creationDate = Date(timeIntervalSince1970: 1)
                }
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = url.lastPathComponent
                creation.addResource(with: .photo, fileURL: url, options: options)
                if let id = creation.placeholderForCreatedAsset?.localIdentifier {
                    self.lock.withLock { _ = self.localIds.insert(id) }
                }
            }
        }
    }

    @MainActor
    private func recentImage() async throws -> UIImage {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: .image, options: options).firstObject else {
            throw ProbeError.message("No recent image available")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let request = PHImageRequestOptions()
            request.deliveryMode = .highQualityFormat
            request.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1800, height: 1800), contentMode: .aspectFit, options: request) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: ProbeError.message("Could not load the recent image")) }
            }
        }
    }

    @MainActor
    private func makeFixture(image: UIImage, large: Bool) throws -> URL {
        let side = large ? 3072 : 1600
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            if large {
                // Incompressible border gives progress mode a roughly 40 MB
                // payload without another video recording or a huge photo export.
                var pixels = [UInt8](repeating: 0, count: side * side * 4)
                for offset in stride(from: 0, to: pixels.count, by: 4) {
                    let random = UInt32.random(in: .min ... .max)
                    pixels[offset] = UInt8(truncatingIfNeeded: random)
                    pixels[offset + 1] = UInt8(truncatingIfNeeded: random >> 8)
                    pixels[offset + 2] = UInt8(truncatingIfNeeded: random >> 16)
                    pixels[offset + 3] = 255
                }
                if let provider = CGDataProvider(data: Data(pixels) as CFData),
                   let noise = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                    context.cgContext.draw(noise, in: CGRect(origin: .zero, size: size))
                }
            }
            let width = CGFloat(side) * 0.65
            let height = min(width * image.size.height / image.size.width, CGFloat(side) * 0.7)
            let fittedWidth = height * image.size.width / image.size.height
            image.draw(in: CGRect(x: (CGFloat(side) - fittedWidth) / 2, y: 80, width: fittedWidth, height: height))
            let label = "IMORA BACKUP EXPIRY TEST\n\(UUID().uuidString)"
            label.draw(in: CGRect(x: 60, y: CGFloat(side) - 220, width: CGFloat(side) - 120, height: 190), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 48), .foregroundColor: UIColor.white, .backgroundColor: UIColor.black])
        }
        guard let data = rendered.pngData() else { throw ProbeError.message("Could not encode fixture") }
        let url = FileManager.default.temporaryDirectory.appending(path: "IMORA-EXPIRY-TEST-\(UUID()).png")
        try data.write(to: url)
        return url
    }

    private enum ProbeError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
    }
}
#endif
