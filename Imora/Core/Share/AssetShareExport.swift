import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// what a shared file carries beyond its pixels, mirroring the photos app's
/// location and all-photos-data switches. remembered across shares.
nonisolated struct AssetShareOptions: Equatable, Sendable {
    static let includesLocationKey = "imora.share.includesLocation"
    static let includesAllMetadataKey = "imora.share.includesAllMetadata"

    var includesLocation = true
    var includesAllMetadata = true

    static var current: AssetShareOptions {
        let defaults = UserDefaults.standard
        return AssetShareOptions(
            includesLocation: defaults.object(forKey: includesLocationKey) as? Bool ?? true,
            includesAllMetadata: defaults.object(forKey: includesAllMetadataKey) as? Bool ?? true
        )
    }

    func persist() {
        let defaults = UserDefaults.standard
        defaults.set(includesLocation, forKey: Self.includesLocationKey)
        defaults.set(includesAllMetadata, forKey: Self.includesAllMetadataKey)
    }

    /// the original bytes go out untouched unless something is excluded.
    var needsFiltering: Bool { !includesLocation || !includesAllMetadata }
}

nonisolated enum AssetShareError: LocalizedError {
    case unsupportedImage
    case unsupportedVideo

    var errorDescription: String? {
        switch self {
        case .unsupportedImage:
            "This image format can’t be rewritten without its metadata."
        case .unsupportedVideo:
            "This video can’t be rewritten without its metadata."
        }
    }
}

nonisolated struct AssetShareExportedFile: Sendable {
    let fileURL: URL
    let contentType: UTType

    var filename: String { fileURL.lastPathComponent }
}

nonisolated struct AssetShareSource: Identifiable, Sendable {
    let id = UUID()
    let asset: Asset
    let localIdentifier: String?
    let remoteIdentifier: String?

    static func resolve(
        assets: [Asset],
        localIdentifierByRemoteID: [String: String],
        remoteIdentifierByLocalID: [String: String]
    ) -> [AssetShareSource] {
        assets.map { asset in
            let localIdentifier = asset.localIdentifier
                ?? localIdentifierByRemoteID[asset.id]
            let remoteIdentifier = asset.id.hasPrefix("local-")
                ? localIdentifier.flatMap { remoteIdentifierByLocalID[$0] }
                : asset.id
            return AssetShareSource(
                asset: asset,
                localIdentifier: localIdentifier,
                remoteIdentifier: remoteIdentifier
            )
        }
    }
}

nonisolated enum AssetShareExportProgress: Sendable {
    case preparing
    case acquiring(Double)
    case processing(Double)
    case completed
    case failed
    case cancelled
}

typealias AssetShareExportProgressHandler = @Sendable (
    UUID,
    UUID,
    AssetShareExportProgress
) -> Void

/// produces the file an activity receives for one asset: the device copy
/// when photokit has one, otherwise the server original with its edits
/// applied, rewritten without whatever metadata the options exclude. exports
/// are keyed per source for progress bookkeeping and cancellation, and every
/// file lands under one scratch directory retained until recipients finish
/// copying it.
actor AssetShareExporter {
    private typealias ExportContinuation = CheckedContinuation<AssetShareExportedFile, any Error>

    private struct InFlightExport {
        let token: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: ExportContinuation]
    }

    private enum CachedExport {
        case inFlight(InFlightExport)
        case completed(AssetShareExportedFile)
    }

    private let directory: URL
    private let client: ImmichClient?
    private let progress: AssetShareExportProgressHandler
    private let options: AssetShareOptions
    private var exports: [UUID: CachedExport] = [:]
    private var pendingWaiters: [UUID: Bool] = [:]
    private var isFinished = false

    init(
        directory: URL,
        client: ImmichClient?,
        options: AssetShareOptions,
        progress: @escaping AssetShareExportProgressHandler
    ) {
        self.directory = directory
        self.client = client
        self.options = options
        self.progress = progress
    }

    func fileURL(for source: AssetShareSource) async throws -> URL {
        try await exportedFile(for: source).fileURL
    }

    func exportedFile(for source: AssetShareSource) async throws -> AssetShareExportedFile {
        try Task.checkCancellation()
        guard !isFinished else { throw CancellationError() }

        let waiterID = UUID()
        pendingWaiters[waiterID] = false
        return try await withTaskCancellationHandler {
            do {
                let exported = try await waitForExport(
                    source,
                    waiterID: waiterID
                )
                try Task.checkCancellation()
                return exported
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    waiterID,
                    sourceID: source.id
                )
            }
        }
    }

    func cancelAll() {
        isFinished = true
        cancelInFlightExports()
    }

    private func waitForExport(
        _ source: AssetShareSource,
        waiterID: UUID
    ) async throws -> AssetShareExportedFile {
        try await withCheckedThrowingContinuation { continuation in
            let wasCancelled = pendingWaiters.removeValue(forKey: waiterID) ?? true
            guard !isFinished, !wasCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }

            switch exports[source.id] {
            case .completed(let exported):
                continuation.resume(returning: exported)
            case .inFlight(var entry):
                entry.waiters[waiterID] = continuation
                exports[source.id] = .inFlight(entry)
            case nil:
                startExport(
                    source,
                    waiterID: waiterID,
                    continuation: continuation
                )
            }
        }
    }

    private func startExport(
        _ source: AssetShareSource,
        waiterID: UUID,
        continuation: ExportContinuation
    ) {
        let token = UUID()
        let destination = directory.appending(path: UUID().uuidString)
        let client = client
        let options = options
        let progress = progress
        progress(source.id, token, .preparing)
        let task = Task {
            do {
                let exported = try await Self.export(
                    source,
                    into: destination,
                    client: client,
                    options: options,
                    progress: { stage in
                        progress(source.id, token, stage)
                    }
                )
                completeExport(
                    exported,
                    sourceID: source.id,
                    token: token
                )
            } catch {
                failExport(
                    error,
                    sourceID: source.id,
                    token: token
                )
            }
        }
        exports[source.id] = .inFlight(InFlightExport(
            token: token,
            task: task,
            waiters: [waiterID: continuation]
        ))
    }

    private func completeExport(
        _ exported: AssetShareExportedFile,
        sourceID: UUID,
        token: UUID
    ) {
        guard case .inFlight(let entry) = exports[sourceID],
              entry.token == token
        else { return }
        exports[sourceID] = .completed(exported)
        progress(sourceID, token, .completed)
        for continuation in entry.waiters.values {
            continuation.resume(returning: exported)
        }
    }

    private func failExport(
        _ error: any Error,
        sourceID: UUID,
        token: UUID
    ) {
        guard case .inFlight(let entry) = exports[sourceID],
              entry.token == token
        else { return }
        exports[sourceID] = nil
        let wasCancelled = error is CancellationError
            || (error as? URLError)?.code == .cancelled
        progress(sourceID, token, wasCancelled ? .cancelled : .failed)
        for continuation in entry.waiters.values {
            continuation.resume(throwing: error)
        }
    }

    private func cancelWaiter(_ waiterID: UUID, sourceID: UUID) {
        if pendingWaiters[waiterID] != nil {
            pendingWaiters[waiterID] = true
            return
        }
        guard case .inFlight(var entry) = exports[sourceID],
              let continuation = entry.waiters.removeValue(forKey: waiterID)
        else { return }

        if entry.waiters.isEmpty {
            exports[sourceID] = nil
            entry.task.cancel()
            progress(sourceID, entry.token, .cancelled)
        } else {
            exports[sourceID] = .inFlight(entry)
        }
        continuation.resume(throwing: CancellationError())
    }

    private func cancelInFlightExports() {
        let cached = exports
        exports.removeAll()
        for waiterID in Array(pendingWaiters.keys) {
            pendingWaiters[waiterID] = true
        }
        for (sourceID, cachedExport) in cached {
            guard case .inFlight(let entry) = cachedExport else { continue }
            entry.task.cancel()
            progress(sourceID, entry.token, .cancelled)
            for continuation in entry.waiters.values {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    private static func export(
        _ source: AssetShareSource,
        into directory: URL,
        client: ImmichClient?,
        options: AssetShareOptions,
        progress: @escaping @Sendable (AssetShareExportProgress) -> Void
    ) async throws -> AssetShareExportedFile {
        let asset = source.asset
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original: AssetShareExportedFile
        // a server side edit means the device copy no longer matches what the
        // user sees, so the edited original is downloaded instead.
        let requiresRemote = asset.isEdited == true
            && client != nil
            && source.remoteIdentifier != nil
        if let localID = source.localIdentifier, !requiresRemote {
            do {
                let resource = try await PhotoLibraryService.exportPrimary(
                    localIdentifier: localID,
                    to: directory,
                    progress: { fraction in
                        progress(.acquiring(fraction))
                    }
                )
                progress(.acquiring(1))
                original = try await AssetShareFileInspector.place(
                    resource.fileURL,
                    suggestedFilename: resource.filename,
                    responseMIMEType: nil,
                    asset: asset,
                    in: directory
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if case PhotoLibraryError.insufficientStorage = error {
                    throw error
                }
                if isDestinationWriteFailure(error) {
                    throw error
                }
                guard let client, let remoteIdentifier = source.remoteIdentifier else {
                    throw error
                }
                original = try await download(
                    asset,
                    remoteIdentifier: remoteIdentifier,
                    client: client,
                    into: directory,
                    progress: { fraction in
                        progress(.acquiring(fraction))
                    }
                )
            }
        } else {
            guard let client, let remoteIdentifier = source.remoteIdentifier else {
                throw ImmichError.unreachable
            }
            original = try await download(
                asset,
                remoteIdentifier: remoteIdentifier,
                client: client,
                into: directory,
                progress: { fraction in
                    progress(.acquiring(fraction))
                }
            )
        }
        try Task.checkCancellation()
        guard options.needsFiltering else { return original }
        progress(.processing(0))

        let filteredContentType = asset.isVideo
            ? AssetShareMetadataFilter.videoOutputContentType(
                for: original.fileURL
            )
            : original.contentType
        let filteredFilename = try AssetShareFileInspector.normalizedFilename(
            original.filename,
            contentType: filteredContentType,
            fallbackStem: asset.isVideo ? "video" : "photo",
            error: asset.isVideo ? .unsupportedVideo : .unsupportedImage
        )
        let filtered = directory
            .appending(path: "filtered")
            .appending(path: filteredFilename)
        try FileManager.default.createDirectory(
            at: filtered.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            if asset.isVideo {
                try await AssetShareMetadataFilter.copyVideo(
                    at: original.fileURL,
                    to: filtered,
                    options: options,
                    progress: { fraction in
                        progress(.processing(fraction))
                    }
                )
            } else {
                try await AssetShareMetadataFilter.copyImage(
                    at: original.fileURL,
                    to: filtered,
                    options: options,
                    progress: { fraction in
                        progress(.processing(fraction))
                    }
                )
            }
            try Task.checkCancellation()
            return try await AssetShareFileInspector.place(
                filtered,
                suggestedFilename: filteredFilename,
                responseMIMEType: filteredContentType.preferredMIMEType,
                asset: asset,
                in: filtered.deletingLastPathComponent()
            )
        } catch {
            try? FileManager.default.removeItem(at: filtered)
            throw error
        }
    }

    private static func isDestinationWriteFailure(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileWriteNoPermissionError,
                 NSFileWriteOutOfSpaceError,
                 NSFileWriteVolumeReadOnlyError:
                return true
            default:
                break
            }
        }
        if error.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(error.code)) {
            switch code {
            case .EACCES, .ENOSPC, .EROFS:
                return true
            default:
                break
            }
        }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
              underlying !== error
        else { return false }
        return isDestinationWriteFailure(underlying)
    }

    private static func download(
        _ asset: Asset,
        remoteIdentifier: String,
        client: ImmichClient,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AssetShareExportedFile {
        var request = URLRequest(
            url: client.editedOriginalURL(assetID: remoteIdentifier)
        )
        for (key, value) in client.authHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // streamed to disk: buffering with data(for:) held the whole original
        // in memory, which could jetsam the app on a large video.
        let download = AssetShareRemoteDownload(
            directory: directory,
            progress: progress
        )
        let result = try await download.start(request)
        let tempURL = result.fileURL
        let response = result.response
        do {
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ImmichError.unreachable
        }
        guard (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ImmichError.http(http.statusCode, "")
        }
        return try await AssetShareFileInspector.place(
            tempURL,
            suggestedFilename: http.suggestedFilename ?? "",
            responseMIMEType: http.mimeType,
            asset: asset,
            in: directory
        )
    }
}

private nonisolated struct AssetShareRemoteDownloadResult: Sendable {
    let fileURL: URL
    let response: URLResponse
}

private nonisolated final class AssetShareRemoteDownload:
    NSObject,
    URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private struct State {
        var continuation: CheckedContinuation<AssetShareRemoteDownloadResult, any Error>?
        var session: URLSession?
        var task: URLSessionDownloadTask?
        var downloadedURL: URL?
        var response: URLResponse?
        var isCancelled = false
        var isFinished = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let directory: URL
    private let progress: @Sendable (Double) -> Void

    init(
        directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) {
        self.directory = directory
        self.progress = progress
    }

    func start(_ request: URLRequest) async throws -> AssetShareRemoteDownloadResult {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.default
                configuration.urlCache = nil
                configuration.timeoutIntervalForRequest = 20
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                let task = session.downloadTask(with: request)
                let shouldStart = lock.withLock { state in
                    guard !state.isCancelled, !state.isFinished else {
                        return false
                    }
                    state.continuation = continuation
                    state.session = session
                    state.task = task
                    return true
                }
                if shouldStart {
                    task.resume()
                } else {
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(
            1,
            max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        )
        lock.withLock { state in
            guard !state.isCancelled, !state.isFinished else { return }
            progress(fraction)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let destination = directory.appending(
            path: "download-\(UUID().uuidString)"
        )
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            let shouldRemove = lock.withLock { state in
                guard !state.isFinished else { return true }
                state.downloadedURL = destination
                state.response = downloadTask.response
                return false
            }
            if shouldRemove {
                try? FileManager.default.removeItem(at: destination)
            }
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            finish(.failure(error))
            return
        }
        let result = lock.withLock { state -> AssetShareRemoteDownloadResult? in
            guard let fileURL = state.downloadedURL,
                  let response = state.response
            else { return nil }
            return AssetShareRemoteDownloadResult(
                fileURL: fileURL,
                response: response
            )
        }
        finish(result.map(Result.success) ?? .failure(ImmichError.unreachable))
    }

    private func cancel() {
        let resources = lock.withLock { state -> (
            CheckedContinuation<AssetShareRemoteDownloadResult, any Error>?,
            URLSessionDownloadTask?,
            URLSession?,
            URL?
        ) in
            state.isCancelled = true
            guard !state.isFinished, state.continuation != nil else {
                return (nil, state.task, state.session, state.downloadedURL)
            }
            state.isFinished = true
            let resources = (
                state.continuation,
                state.task,
                state.session,
                state.downloadedURL
            )
            state.continuation = nil
            state.task = nil
            state.session = nil
            state.downloadedURL = nil
            return resources
        }
        resources.1?.cancel()
        resources.2?.invalidateAndCancel()
        if let fileURL = resources.3 {
            try? FileManager.default.removeItem(at: fileURL)
        }
        resources.0?.resume(throwing: CancellationError())
    }

    private func finish(
        _ result: Result<AssetShareRemoteDownloadResult, any Error>
    ) {
        let resources = lock.withLock { state -> (
            CheckedContinuation<AssetShareRemoteDownloadResult, any Error>?,
            URLSession?,
            URL?
        ) in
            guard !state.isFinished, let continuation = state.continuation else {
                return (nil, nil, nil)
            }
            state.isFinished = true
            let fileToRemove: URL?
            if case .failure = result {
                fileToRemove = state.downloadedURL
            } else {
                fileToRemove = nil
            }
            let resources = (continuation, state.session, fileToRemove)
            state.continuation = nil
            state.task = nil
            state.session = nil
            state.downloadedURL = nil
            return resources
        }
        guard let continuation = resources.0 else { return }
        resources.1?.finishTasksAndInvalidate()
        if let fileURL = resources.2 {
            try? FileManager.default.removeItem(at: fileURL)
        }
        continuation.resume(with: result)
    }
}

nonisolated enum AssetShareFileInspector {
    @concurrent
    static func place(
        _ source: URL,
        suggestedFilename: String,
        responseMIMEType: String?,
        asset: Asset,
        in directory: URL
    ) async throws -> AssetShareExportedFile {
        do {
            let responseType = try validatedResponseType(
                responseMIMEType,
                expected: asset.isVideo ? .movie : .image,
                error: asset.isVideo ? .unsupportedVideo : .unsupportedImage
            )
            let contentType = asset.isVideo
                ? try await videoType(at: source, responseType: responseType, filename: suggestedFilename)
                : try imageType(at: source)
            let filename = try normalizedFilename(
                suggestedFilename,
                contentType: contentType,
                fallbackStem: asset.isVideo ? "video" : "photo",
                error: asset.isVideo ? .unsupportedVideo : .unsupportedImage
            )
            let destination = directory.appending(path: filename)
            if source.standardizedFileURL != destination.standardizedFileURL {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: source, to: destination)
            }
            return AssetShareExportedFile(fileURL: destination, contentType: contentType)
        } catch {
            try? FileManager.default.removeItem(at: source)
            throw error
        }
    }

    static func normalizedFilename(
        _ suggestedFilename: String,
        contentType: UTType,
        fallbackStem: String,
        error: AssetShareError
    ) throws -> String {
        guard let filenameExtension = contentType.preferredFilenameExtension,
              !filenameExtension.isEmpty
        else { throw error }
        let component = suggestedFilename
            .replacingOccurrences(of: "\\", with: "_")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""
        let stem = URL(fileURLWithPath: component)
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(stem.isEmpty ? fallbackStem : stem).\(filenameExtension)"
    }

    private static func validatedResponseType(
        _ mimeType: String?,
        expected: UTType,
        error: AssetShareError
    ) throws -> UTType? {
        guard let mimeType = mimeType?.lowercased(), !mimeType.isEmpty else { return nil }
        if mimeType == "application/octet-stream" || mimeType == "binary/octet-stream" {
            return nil
        }
        guard let type = UTType(mimeType: mimeType) else { return nil }
        guard type.isDynamic || type.conforms(to: expected) else { throw error }
        return type.conforms(to: expected) ? type : nil
    }

    private static func imageType(at url: URL) throws -> UTType {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String),
              type.conforms(to: .image)
        else { throw AssetShareError.unsupportedImage }
        return type
    }

    private static func videoType(
        at url: URL,
        responseType: UTType?,
        filename: String
    ) async throws -> UTType {
        // magic bytes are proof enough of a real container. formats
        // avfoundation cannot parse - avi, transport streams - still share
        // fine as raw files, so they must not be validated through it.
        if let detected = try detectedVideoType(at: url) { return detected }
        let filenameType = UTType(filenameExtension: URL(fileURLWithPath: filename).pathExtension)
        guard let contentType = concreteMovieType(responseType)
            ?? concreteMovieType(filenameType)
        else { throw AssetShareError.unsupportedVideo }
        // a type known only from hints gets verified by opening the file, so
        // mislabeled bytes cannot go out typed as a movie.
        let assetOptions: [String: Any]? = contentType.preferredMIMEType.map {
            [AVURLAssetOverrideMIMETypeKey: $0]
        }
        let asset = AVURLAsset(url: url, options: assetOptions)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw AssetShareError.unsupportedVideo }
        return contentType
    }

    private static func concreteMovieType(_ type: UTType?) -> UTType? {
        guard let type,
              type.conforms(to: .movie),
              type.preferredFilenameExtension != nil
        else { return nil }
        return type
    }

    private static func detectedVideoType(at url: URL) throws -> UTType? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 4_096) ?? Data()
        guard header.count >= 12 else { return nil }

        if ascii(in: 4..<8, of: header) == "ftyp" {
            return ascii(in: 8..<12, of: header) == "qt  " ? .quickTimeMovie : .mpeg4Movie
        }
        if ascii(in: 0..<4, of: header) == "RIFF", ascii(in: 8..<12, of: header) == "AVI " {
            return .avi
        }
        if header.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            let text = String(decoding: header, as: UTF8.self).lowercased()
            let extensionHint = text.contains("webm") ? "webm" : "mkv"
            return concreteMovieType(UTType(filenameExtension: extensionHint))
        }
        if header[0] == 0x47, header.count > 188, header[188] == 0x47 {
            return .mpeg2TransportStream
        }
        if header.starts(with: [0x00, 0x00, 0x01, 0xBA]) {
            return .mpeg
        }
        return nil
    }

    private static func ascii(in range: Range<Int>, of data: Data) -> String? {
        guard data.indices.contains(range.lowerBound), data.indices.contains(range.upperBound - 1) else {
            return nil
        }
        return String(bytes: data[range], encoding: .ascii)
    }
}

/// rewrites a file without the metadata the options exclude. images are
/// copied losslessly through imageio - the pixels are untouched, only the
/// metadata containers change - and videos pass through avfoundation without
/// re-encoding.
nonisolated enum AssetShareMetadataFilter {
    static func videoOutputContentType(for source: URL) -> UTType {
        ["mp4", "m4v"].contains(source.pathExtension.lowercased())
            ? .mpeg4Movie
            : .quickTimeMovie
    }

    @concurrent
    static func copyImage(
        at source: URL,
        to destination: URL,
        options: AssetShareOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        progress(0)
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let type = CGImageSourceGetType(imageSource),
              let imageDestination = CGImageDestinationCreateWithURL(
                  destination as CFURL,
                  type,
                  CGImageSourceGetCount(imageSource),
                  nil
              )
        else { throw AssetShareError.unsupportedImage }

        let metadata = try filteredMetadata(
            from: imageSource,
            options: options
        )
        try Task.checkCancellation()
        var copyOptions: [CFString: Any] = [
            kCGImageMetadataShouldExcludeGPS: !options.includesLocation,
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false
        ]
        if !options.includesAllMetadata {
            copyOptions[kCGImageMetadataShouldExcludeXMP] = true
        }
        progress(0.5)
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(imageDestination, imageSource, copyOptions as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? AssetShareError.unsupportedImage
        }
        try Task.checkCancellation()
        progress(1)
    }

    private static func filteredMetadata(
        from imageSource: CGImageSource,
        options: AssetShareOptions
    ) throws -> CGMutableImageMetadata {
        try Task.checkCancellation()
        let metadata: CGMutableImageMetadata
        if options.includesAllMetadata,
           let sourceMetadata = CGImageSourceCopyMetadataAtIndex(imageSource, 0, nil),
           let copy = CGImageMetadataCreateMutableCopy(sourceMetadata) {
            metadata = copy
        } else {
            metadata = CGImageMetadataCreateMutable()
        }

        try Task.checkCancellation()
        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            imageSource,
            0,
            nil
        ) as? [CFString: Any] else { return metadata }
        if let orientation = properties[kCGImagePropertyOrientation] {
            guard CGImageMetadataSetValueMatchingImageProperty(
                metadata,
                kCGImagePropertyTIFFDictionary,
                kCGImagePropertyTIFFOrientation,
                orientation as CFTypeRef
            ) else { throw AssetShareError.unsupportedImage }
        }
        if !options.includesAllMetadata,
           options.includesLocation,
           let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            for (property, value) in gps {
                guard CGImageMetadataSetValueMatchingImageProperty(
                    metadata,
                    kCGImagePropertyGPSDictionary,
                    property,
                    value as CFTypeRef
                ) else { throw AssetShareError.unsupportedImage }
            }
        }
        return metadata
    }

    @concurrent
    static func copyVideo(
        at source: URL,
        to destination: URL,
        options: AssetShareOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        progress(0)
        let sourceAsset = AVURLAsset(url: source)
        let metadata = try await sourceAsset.load(.metadata)
        let selectedMetadata: [AVMetadataItem]
        if options.includesAllMetadata {
            selectedMetadata = options.includesLocation
                ? metadata
                : metadata.filter { !isLocationMetadata($0) }
        } else if options.includesLocation {
            selectedMetadata = metadata.filter(isLocationMetadata)
        } else {
            selectedMetadata = []
        }
        let composition = try await compositionWithoutAssetMetadata(
            from: sourceAsset,
            options: options
        )
        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw AssetShareError.unsupportedVideo
        }
        session.metadata = selectedMetadata
        let fileType: AVFileType = videoOutputContentType(for: source) == .mpeg4Movie
            ? .mp4
            : .mov
        try Task.checkCancellation()
        let progressTask = Task {
            for await state in session.states(updateInterval: 0.1) {
                guard !Task.isCancelled else { return }
                if case .exporting(let exportProgress) = state {
                    progress(exportProgress.fractionCompleted)
                }
            }
        }
        defer { progressTask.cancel() }
        try await session.export(to: destination, as: fileType)
        try Task.checkCancellation()
        progress(1)
    }

    private static func compositionWithoutAssetMetadata(
        from asset: AVAsset,
        options: AssetShareOptions
    ) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        let tracks = try await asset.load(.tracks)
        for sourceTrack in tracks {
            if sourceTrack.mediaType == .metadata {
                guard try await shouldKeepMetadataTrack(
                    sourceTrack,
                    options: options
                ) else { continue }
            }
            guard let track = composition.addMutableTrack(
                withMediaType: sourceTrack.mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { throw AssetShareError.unsupportedVideo }

            let timeRange = try await sourceTrack.load(.timeRange)
            try track.insertTimeRange(
                timeRange,
                of: sourceTrack,
                at: timeRange.start
            )
            track.isEnabled = try await sourceTrack.load(.isEnabled)
            track.naturalTimeScale = try await sourceTrack.load(.naturalTimeScale)
            track.languageCode = try await sourceTrack.load(.languageCode)
            track.extendedLanguageTag = try await sourceTrack.load(.extendedLanguageTag)
            track.preferredTransform = try await sourceTrack.load(.preferredTransform)
            track.preferredVolume = try await sourceTrack.load(.preferredVolume)
        }
        return composition
    }

    /// timed metadata tracks carry gps traces on gopro and dji footage, so
    /// they honor the same switches as item metadata. with location excluded
    /// a track survives only when every identifier is readable and none reads
    /// as location - unknown payloads are dropped rather than trusted.
    private static func shouldKeepMetadataTrack(
        _ track: AVAssetTrack,
        options: AssetShareOptions
    ) async throws -> Bool {
        guard options.includesAllMetadata else { return false }
        guard !options.includesLocation else { return true }
        let descriptions = try await track.load(.formatDescriptions)
        for description in descriptions {
            guard let identifiers = CMMetadataFormatDescriptionGetIdentifiers(
                description
            ) as? [String], !identifiers.isEmpty else { return false }
            guard !identifiers.contains(where: {
                isLocationField($0.lowercased())
            }) else { return false }
        }
        return !descriptions.isEmpty
    }

    private static func isLocationMetadata(_ item: AVMetadataItem) -> Bool {
        if item.identifier == .quickTimeUserDataLocationISO6709
            || item.identifier == .quickTimeMetadataLocationISO6709 {
            return true
        }
        let fields = [
            item.identifier?.rawValue,
            item.keySpace?.rawValue,
            item.key.map { String(describing: $0) },
        ].compactMap { $0?.lowercased() }
        return fields.contains(where: isLocationField)
    }

    private static func isLocationField(_ field: String) -> Bool {
        field.contains("location")
            || field.contains("iso6709")
            || field.contains("©xyz")
    }
}
