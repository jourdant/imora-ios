import CryptoKit
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import os

nonisolated enum PhotoLibraryError: LocalizedError {
    case assetMissing
    case resourceMissing
    case insufficientStorage
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .assetMissing: "the photo no longer exists on this device."
        case .resourceMissing: "the photo data could not be read."
        case .insufficientStorage: "not enough free space to prepare the upload."
        case .exportFailed: "the photo could not be exported."
        }
    }
}

/// sendable snapshot of the phasset fields backup cares about.
nonisolated struct DeviceAsset: Equatable, Sendable {
    let localIdentifier: String
    let isVideo: Bool
    let isLivePhoto: Bool
    let creationDate: Date?
    let modificationDate: Date?
    let isFavorite: Bool
    let durationMs: Int
    let pixelWidth: Int
    let pixelHeight: Int

    /// timeline representation of a device asset that is not on the server
    /// yet. dates follow the photographer-local convention the grids use.
    func asAsset(backedUp: Bool) -> Asset {
        let created = creationDate ?? modificationDate ?? .distantPast
        return Asset(
            id: "local-\(localIdentifier)",
            ownerId: "",
            isImage: !isVideo,
            isFavorite: isFavorite,
            isTrashed: false,
            visibility: .timeline,
            thumbhash: nil,
            fileCreatedAt: created,
            localOffsetHours: Double(TimeZone.current.secondsFromGMT(for: created)) / 3600,
            duration: isVideo ? durationMs : nil,
            livePhotoVideoId: nil,
            ratio: pixelHeight > 0 ? Double(pixelWidth) / Double(pixelHeight) : 1,
            city: nil,
            country: nil,
            createdAt: nil,
            localIdentifier: localIdentifier,
            isLocalBackedUp: backedUp,
            hasLocalMotion: isLivePhoto
        )
    }
}

/// photokit wrapper for backup: scanning, hashing, exporting and deleting.
/// heavy functions are @concurrent so they never run on the main actor.
nonisolated enum PhotoLibraryService {
    /// minimum free space kept while exporting originals for upload.
    private static let storageFloor: Int64 = 512 << 20

    // MARK: - authorization

    /// backup and cleanup need full access: a limited scan hides assets, which
    /// would poison index pruning and make whole-library backup a lie.
    static var hasFullAccess: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    /// every request funnels through here so the observable mirror stays
    /// current no matter which action triggered the prompt.
    static func requestFullAccess() async -> Bool {
        let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized
        await PhotoAccess.shared.refresh()
        return granted
    }

    // MARK: - scanning

    @concurrent
    static func scan() async -> [DeviceAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        var assets: [DeviceAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video else { return }
            assets.append(snapshot(of: asset))
        }
        return assets
    }

    @concurrent
    static func assetInfo(localIdentifier: String) async -> DeviceAsset? {
        fetchPHAsset(localIdentifier).map(snapshot)
    }

    @concurrent
    static func assetExists(localIdentifier: String) async -> Bool {
        fetchPHAsset(localIdentifier) != nil
    }

    private static func snapshot(of asset: PHAsset) -> DeviceAsset {
        DeviceAsset(
            localIdentifier: asset.localIdentifier,
            isVideo: asset.mediaType == .video,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            isFavorite: asset.isFavorite,
            durationMs: Int(asset.duration * 1000),
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight
        )
    }

    private static func fetchPHAsset(_ localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    // MARK: - local info

    /// camera fields read from the image file's own metadata.
    private struct CameraMetadata: Sendable {
        var make: String?
        var model: String?
        var lens: String?
        var fNumber: Double?
        var focalLength: Double?
        var iso: Double?
        var exposureTime: String?
    }

    /// synthesized detail for a device-only asset, so the info sheet renders
    /// local photos through the same layout it uses for server ones. server
    /// notions like people, caption or rating stay nil by construction.
    @concurrent
    static func localDetail(localIdentifier: String) async -> AssetDetail? {
        guard let asset = fetchPHAsset(localIdentifier) else { return nil }
        let resource = primaryResource(for: asset)
        let camera = await cameraMetadata(of: asset)
        let created = asset.creationDate ?? asset.modificationDate ?? .distantPast
        let isVideo = asset.mediaType == .video

        let exif = ExifInfo(
            make: camera?.make,
            model: camera?.model,
            exifImageWidth: asset.pixelWidth > 0 ? Double(asset.pixelWidth) : nil,
            exifImageHeight: asset.pixelHeight > 0 ? Double(asset.pixelHeight) : nil,
            fileSizeInByte: resource?.value(forKey: "fileSize") as? Int64,
            lensModel: camera?.lens,
            fNumber: camera?.fNumber,
            focalLength: camera?.focalLength,
            iso: camera?.iso,
            exposureTime: camera?.exposureTime,
            latitude: asset.location?.coordinate.latitude,
            longitude: asset.location?.coordinate.longitude,
            city: nil,
            state: nil,
            country: nil,
            dateTimeOriginal: nil,
            timeZone: nil,
            description: nil,
            rating: nil
        )
        return AssetDetail(
            id: "local-\(localIdentifier)",
            ownerId: "",
            type: isVideo ? .video : .image,
            originalFileName: resource?.originalFilename ?? "Unknown",
            originalMimeType: resource.flatMap { UTType($0.uniformTypeIdentifier)?.preferredMIMEType },
            thumbhash: nil,
            fileCreatedAt: created.ISO8601Format(),
            localDateTime: created.ISO8601Format(),
            createdAt: nil,
            isFavorite: asset.isFavorite,
            isArchived: nil,
            isTrashed: false,
            visibility: nil,
            width: asset.pixelWidth > 0 ? asset.pixelWidth : nil,
            height: asset.pixelHeight > 0 ? asset.pixelHeight : nil,
            duration: isVideo ? Int(asset.duration * 1000) : nil,
            exifInfo: exif,
            livePhotoVideoId: nil,
            people: nil,
            tags: nil,
            checksum: nil,
            isEdited: nil
        )
    }

    /// exif straight from the picture on device. icloud-offloaded originals
    /// are never downloaded for an info panel - the fields just stay empty.
    private static func cameraMetadata(of asset: PHAsset) async -> CameraMetadata? {
        guard asset.mediaType == .image else { return nil }
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, _ in
                guard let url = input?.fullSizeImageURL,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                else { return continuation.resume(returning: nil) }

                let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
                let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
                var metadata = CameraMetadata()
                metadata.make = tiff?[kCGImagePropertyTIFFMake] as? String
                metadata.model = tiff?[kCGImagePropertyTIFFModel] as? String
                metadata.lens = exif?[kCGImagePropertyExifLensModel] as? String
                metadata.fNumber = exif?[kCGImagePropertyExifFNumber] as? Double
                metadata.focalLength = exif?[kCGImagePropertyExifFocalLength] as? Double
                metadata.iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Double])?.first
                if let seconds = exif?[kCGImagePropertyExifExposureTime] as? Double, seconds > 0 {
                    metadata.exposureTime = seconds < 1
                        ? "1/\(Int((1 / seconds).rounded()))"
                        : "\(seconds.formatted(.number.precision(.fractionLength(0...1)))) s"
                }
                continuation.resume(returning: metadata)
            }
        }
    }

    // MARK: - resource selection

    /// prefers the edited render when one exists, matching what immich's own
    /// ios code hashes and uploads.
    private static func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        let all = PHAssetResource.assetResources(for: asset)
        if asset.mediaType == .video {
            return all.first { $0.type == .fullSizeVideo } ?? all.first { $0.type == .video }
        }
        return all.first { $0.type == .fullSizePhoto } ?? all.first { $0.type == .photo }
    }

    private static func motionResource(for asset: PHAsset) -> PHAssetResource? {
        let all = PHAssetResource.assetResources(for: asset)
        return all.first { $0.type == .fullSizePairedVideo } ?? all.first { $0.type == .pairedVideo }
    }

    // MARK: - hashing

    /// base64 sha-1 of the current resource bytes, matching the server's
    /// checksum representation. streams via requestData, downloading from
    /// icloud when needed.
    @concurrent
    static func hash(localIdentifier: String, includeMotion: Bool) async throws -> (primary: String, motion: String?) {
        guard let asset = fetchPHAsset(localIdentifier) else { throw PhotoLibraryError.assetMissing }
        guard let primary = primaryResource(for: asset) else { throw PhotoLibraryError.resourceMissing }
        let primaryHash = try await sha1Base64(of: primary)
        var motionHash: String?
        if includeMotion {
            guard let motion = motionResource(for: asset) else { throw PhotoLibraryError.resourceMissing }
            motionHash = try await sha1Base64(of: motion)
        }
        return (primaryHash, motionHash)
    }

    private static func sha1Base64(of resource: PHAssetResource) async throws -> String {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let box = DataRequestBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let requestID = PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                    box.append(data)
                } completionHandler: { error in
                    // photokit calls this exactly once, including after a cancel.
                    if let error {
                        continuation.resume(throwing: mapCancellation(error))
                    } else {
                        continuation.resume(returning: box.digest())
                    }
                }
                box.register(requestID)
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// base64 sha-1 of a plain file, streamed. used to verify downloads
    /// against the server checksum before importing them.
    @concurrent
    static func sha1Base64(ofFile url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        // drained per chunk - the autoreleased nsdata otherwise pile up to
        // the size of the file being hashed.
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            try Task.checkCancellation()
            return true
        }) {}
        return Data(hasher.finalize()).base64EncodedString()
    }

    // MARK: - import

    /// saves downloaded originals as one new library asset and returns its
    /// local identifier. source files are moved into the library on success.
    @concurrent
    static func importAsset(
        primaryURL: URL,
        isVideo: Bool,
        filename: String,
        motionURL: URL?
    ) async throws -> String {
        let placeholder = OSAllocatedUnfairLock<String?>(initialState: nil)
        try await PHPhotoLibrary.shared().performChanges {
            let creation = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            options.shouldMoveFile = true
            // photokit rejects files whose type it cannot determine; declare it
            // from the original filename rather than trusting the temp name.
            let ext = URL(fileURLWithPath: filename).pathExtension
            if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
                options.uniformTypeIdentifier = type.identifier
            }
            creation.addResource(with: isVideo ? .video : .photo, fileURL: primaryURL, options: options)
            if let motionURL {
                let motionOptions = PHAssetResourceCreationOptions()
                motionOptions.shouldMoveFile = true
                motionOptions.uniformTypeIdentifier = UTType.quickTimeMovie.identifier
                creation.addResource(with: .pairedVideo, fileURL: motionURL, options: motionOptions)
            }
            let localId = creation.placeholderForCreatedAsset?.localIdentifier
            placeholder.withLock { $0 = localId }
        }
        guard let localId = placeholder.withLock({ $0 }) else {
            throw PhotoLibraryError.exportFailed
        }
        return localId
    }

    // MARK: - export

    nonisolated struct ExportedResource: Sendable {
        let fileURL: URL
        let filename: String
    }

    @concurrent
    static func exportPrimary(localIdentifier: String, to directory: URL) async throws -> ExportedResource {
        guard let asset = fetchPHAsset(localIdentifier) else { throw PhotoLibraryError.assetMissing }
        guard let resource = primaryResource(for: asset) else { throw PhotoLibraryError.resourceMissing }
        return try await export(resource, to: directory)
    }

    @concurrent
    static func exportMotion(localIdentifier: String, to directory: URL) async throws -> ExportedResource {
        guard let asset = fetchPHAsset(localIdentifier) else { throw PhotoLibraryError.assetMissing }
        guard let resource = motionResource(for: asset) else { throw PhotoLibraryError.resourceMissing }
        return try await export(resource, to: directory)
    }

    /// streams the resource into a temp file through the same cancellable
    /// requestData path used for hashing - writeData offers no cancellation.
    private static func export(_ resource: PHAssetResource, to directory: URL) async throws -> ExportedResource {
        guard availableCapacity(at: directory) > storageFloor else {
            throw PhotoLibraryError.insufficientStorage
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appending(path: "export-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let box = DataRequestBox(fileHandle: handle)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let requestID = PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                        box.append(data)
                    } completionHandler: { error in
                        if let error {
                            continuation.resume(throwing: mapCancellation(error))
                        } else if box.writeFailed {
                            continuation.resume(throwing: PhotoLibraryError.exportFailed)
                        } else {
                            continuation.resume()
                        }
                    }
                    box.register(requestID)
                }
            } onCancel: {
                box.cancel()
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
        return ExportedResource(fileURL: fileURL, filename: resource.originalFilename)
    }

    static func availableCapacity(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    // MARK: - deletion

    /// one performchanges call per invocation, so the system shows exactly one
    /// confirmation dialog per batch. user refusal surfaces as userCancelled.
    static func delete(localIdentifiers: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        guard assets.count > 0 else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    static func isUserCancelled(_ error: Error) -> Bool {
        (error as? PHPhotosError)?.code == .userCancelled || error is CancellationError
    }

    private static func mapCancellation(_ error: Error) -> Error {
        isUserCancelled(error) ? CancellationError() : error
    }
}

/// lock-guarded accumulator shared between photokit's data callback, the
/// completion handler and the task cancellation handler. no assumptions about
/// which queue photokit uses.
private nonisolated final class DataRequestBox: @unchecked Sendable {
    private struct State {
        var hasher = Insecure.SHA1()
        var requestID: PHAssetResourceDataRequestID?
        var cancelled = false
        var writeFailed = false
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let fileHandle: FileHandle?

    init(fileHandle: FileHandle? = nil) {
        self.fileHandle = fileHandle
        self.lock = OSAllocatedUnfairLock(initialState: State())
    }

    func append(_ data: Data) {
        lock.withLock { state in
            if let fileHandle {
                do {
                    try fileHandle.write(contentsOf: data)
                } catch {
                    state.writeFailed = true
                }
            } else {
                state.hasher.update(data: data)
            }
        }
    }

    func digest() -> String {
        lock.withLock { state in
            Data(state.hasher.finalize()).base64EncodedString()
        }
    }

    var writeFailed: Bool {
        lock.withLock { $0.writeFailed }
    }

    /// handles the race where cancellation lands before the request id exists.
    func register(_ requestID: PHAssetResourceDataRequestID) {
        let cancelNow = lock.withLock { state in
            state.requestID = requestID
            return state.cancelled
        }
        if cancelNow {
            PHAssetResourceManager.default().cancelDataRequest(requestID)
        }
    }

    func cancel() {
        let requestID = lock.withLock { state -> PHAssetResourceDataRequestID? in
            state.cancelled = true
            return state.requestID
        }
        if let requestID {
            PHAssetResourceManager.default().cancelDataRequest(requestID)
        }
    }
}
