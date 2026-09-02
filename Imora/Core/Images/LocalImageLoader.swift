import AVFoundation
import Photos
import UIKit
import os

/// one step of a progressive photokit load: the library's own stored
/// thumbnail while the sharp render is still being decoded, then the render.
nonisolated enum LocalImageDelivery {
    case preview(UIImage)
    case final(UIImage)
}

/// photokit loading for device assets merged into the timeline. the heavy
/// lifting - decoding, downscaling and keeping a window of tiles warm - is
/// photokit's own caching manager, the local twin of the nuke pipeline behind
/// remote thumbnails.
/// unchecked because nscache is documented thread-safe.
nonisolated final class LocalImageLoader: @unchecked Sendable {
    static let shared = LocalImageLoader()

    /// caching manager rather than the default one: it prefetches and holds
    /// decoded thumbnails for the identifiers the grid asks it to keep warm.
    private let manager = PHCachingImageManager()
    /// decoded results still get a small cache of their own so a tile
    /// scrolling back into view renders on its first frame, synchronously -
    /// photokit only ever answers through a callback.
    private let cache: NSCache<NSString, UIImage>
    /// photokit's stored previews, one per asset whatever size was asked. the
    /// opening transition needs an uncropped picture for a tile that only has
    /// its preview yet - a snapshot of the square tile is a crop the viewer
    /// visibly zooms out of once the render lands.
    private let previews: NSCache<NSString, UIImage>
    private let assets: NSCache<NSString, PHAsset>
    /// exported live photo motion files in least-recently-used order.
    private let motionFiles = OSAllocatedUnfairLock<[URL]>(initialState: [])
    /// a window can hold dozens of identifiers and every miss is a synchronous
    /// library query, so the bookkeeping stays off the caller's thread. serial
    /// keeps a stop from overtaking the start it cancels.
    private let cachingQueue = DispatchQueue(label: "app.imora.local-image-caching", qos: .userInitiated)

    private init() {
        cache = NSCache()
        cache.totalCostLimit = 48 << 20
        previews = NSCache()
        previews.totalCostLimit = 12 << 20
        assets = NSCache()
        assets.countLimit = 512
    }

    /// asset lookups are cached; a library change invalidates them all.
    func noteLibraryChange() {
        assets.removeAllObjects()
        manager.stopCachingImagesForAllAssets()
    }

    private func fetchAsset(_ localIdentifier: String) -> PHAsset? {
        let key = localIdentifier as NSString
        if let cached = assets.object(forKey: key) { return cached }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            return nil
        }
        assets.setObject(asset, forKey: key)
        return asset
    }

    /// one library query for every identifier not already cached, instead of
    /// one per tile: a prefetch window moves dozens of identifiers at a time
    /// and each query is a round trip to the photos database.
    private func fetchAssets(_ localIdentifiers: [String]) -> [PHAsset] {
        var found: [PHAsset] = []
        var missing: [String] = []
        found.reserveCapacity(localIdentifiers.count)
        for localIdentifier in localIdentifiers {
            if let cached = assets.object(forKey: localIdentifier as NSString) {
                found.append(cached)
            } else {
                missing.append(localIdentifier)
            }
        }
        guard !missing.isEmpty else { return found }
        PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil).enumerateObjects { asset, _, _ in
            self.assets.setObject(asset, forKey: asset.localIdentifier as NSString)
            found.append(asset)
        }
        return found
    }

    private func key(
        _ localIdentifier: String,
        _ size: CGFloat,
        _ contentMode: PHImageContentMode
    ) -> NSString {
        "\(localIdentifier)#\(Int(size))#\(contentMode.rawValue)" as NSString
    }

    /// the caching manager only serves a prefetched thumbnail when the request
    /// that follows carries the same options, so every path shares these.
    /// opportunistic delivery hands back the library's stored thumbnail at
    /// once whenever the render at the asked size still has to be decoded,
    /// which is what keeps a fling painted instead of grey.
    private static func requestOptions(allowsNetwork: Bool) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowsNetwork
        return options
    }

    private static func isDegraded(_ info: [AnyHashable: Any]?) -> Bool {
        (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
    }

    private static func isCancelled(_ info: [AnyHashable: Any]?) -> Bool {
        (info?[PHImageCancelledKey] as? Bool) ?? false
    }

    private static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }

    private func store(
        _ image: UIImage,
        localIdentifier: String,
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode
    ) {
        cache.setObject(
            image,
            forKey: key(localIdentifier, targetPixelSize, contentMode),
            cost: Self.cost(of: image)
        )
    }

    private func storePreview(_ image: UIImage, localIdentifier: String) {
        previews.setObject(image, forKey: localIdentifier as NSString, cost: Self.cost(of: image))
    }

    func cachedImage(
        localIdentifier: String,
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode = .aspectFill
    ) -> UIImage? {
        cache.object(forKey: key(localIdentifier, targetPixelSize, contentMode))
    }

    /// the last preview photokit handed over for the asset, at whatever size.
    func cachedPreview(localIdentifier: String) -> UIImage? {
        previews.object(forKey: localIdentifier as NSString)
    }

    /// the sharp render alone, for callers that want exactly one image.
    /// concurrent so the photokit fetch never runs inline on the caller. under
    /// approachable concurrency a plain nonisolated async body stays on the
    /// caller's actor, which put a synchronous library query on the main
    /// thread every time a page or tile asked for its image.
    @concurrent
    func image(
        localIdentifier: String,
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode = .aspectFill,
        allowsNetwork: Bool = true
    ) async -> UIImage? {
        if let cached = cachedImage(
            localIdentifier: localIdentifier,
            targetPixelSize: targetPixelSize,
            contentMode: contentMode
        ) {
            return cached
        }
        guard let asset = fetchAsset(localIdentifier) else { return nil }
        let size = CGSize(width: targetPixelSize, height: targetPixelSize)
        // opportunistic delivery may answer twice; the stored thumbnail is
        // skipped and the guard keeps the continuation to a single resume.
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let image = await withCheckedContinuation { continuation in
            manager.requestImage(
                for: asset,
                targetSize: size,
                contentMode: contentMode,
                options: Self.requestOptions(allowsNetwork: allowsNetwork)
            ) { image, info in
                if Self.isDegraded(info) {
                    if let image { self.storePreview(image, localIdentifier: localIdentifier) }
                    return
                }
                let first = resumed.withLock { resumed in
                    defer { resumed = true }
                    return !resumed
                }
                guard first else { return }
                continuation.resume(returning: image)
            }
        }
        if let image {
            store(image, localIdentifier: localIdentifier, targetPixelSize: targetPixelSize, contentMode: contentMode)
        }
        return image
    }

    /// progressive load for tiles: photokit's stored thumbnail lands first
    /// when the render at `targetPixelSize` still has to be decoded, so a tile
    /// paints on arrival and sharpens a moment later. only the sharp render is
    /// cached. a stream that ends without one means photokit could not produce
    /// it - the asset is gone, or sits in icloud with network access off.
    func deliveries(
        localIdentifier: String,
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode = .aspectFill,
        allowsNetwork: Bool = true
    ) -> AsyncStream<LocalImageDelivery> {
        if let cached = cachedImage(
            localIdentifier: localIdentifier,
            targetPixelSize: targetPixelSize,
            contentMode: contentMode
        ) {
            return AsyncStream { continuation in
                continuation.yield(.final(cached))
                continuation.finish()
            }
        }
        let request = ImageRequestBox()
        let manager = manager
        return AsyncStream { continuation in
            continuation.onTermination = { _ in request.cancel(manager) }
            // the library lookup is synchronous photokit work, kept off the
            // caller's actor like the single-image path.
            Task.detached(priority: .userInitiated) { [self] in
                guard !request.isCancelled, let asset = fetchAsset(localIdentifier) else {
                    continuation.finish()
                    return
                }
                let size = CGSize(width: targetPixelSize, height: targetPixelSize)
                let requestID = manager.requestImage(
                    for: asset,
                    targetSize: size,
                    contentMode: contentMode,
                    options: Self.requestOptions(allowsNetwork: allowsNetwork)
                ) { image, info in
                    guard !Self.isCancelled(info), let image else {
                        continuation.finish()
                        return
                    }
                    if Self.isDegraded(info) {
                        self.storePreview(image, localIdentifier: localIdentifier)
                        continuation.yield(.preview(image))
                        return
                    }
                    self.store(
                        image,
                        localIdentifier: localIdentifier,
                        targetPixelSize: targetPixelSize,
                        contentMode: contentMode
                    )
                    continuation.yield(.final(image))
                    continuation.finish()
                }
                request.register(requestID, manager: manager)
            }
        }
    }

    // MARK: - prefetching

    /// `allowsNetwork` has to match what the tiles will ask with, or the
    /// caching manager treats their requests as strangers to its cache.
    func startCaching(
        localIdentifiers: [String],
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode = .aspectFill,
        allowsNetwork: Bool = true
    ) {
        cachingQueue.async { [self] in
            setCaching(
                true,
                localIdentifiers: localIdentifiers,
                targetPixelSize: targetPixelSize,
                contentMode: contentMode,
                allowsNetwork: allowsNetwork
            )
        }
    }

    func stopCaching(
        localIdentifiers: [String],
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode = .aspectFill,
        allowsNetwork: Bool = true
    ) {
        cachingQueue.async { [self] in
            setCaching(
                false,
                localIdentifiers: localIdentifiers,
                targetPixelSize: targetPixelSize,
                contentMode: contentMode,
                allowsNetwork: allowsNetwork
            )
        }
    }

    private func setCaching(
        _ caching: Bool,
        localIdentifiers: [String],
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode,
        allowsNetwork: Bool
    ) {
        let assets = fetchAssets(localIdentifiers)
        guard !assets.isEmpty else { return }
        let size = CGSize(width: targetPixelSize, height: targetPixelSize)
        let options = Self.requestOptions(allowsNetwork: allowsNetwork)
        if caching {
            manager.startCachingImages(for: assets, targetSize: size, contentMode: contentMode, options: options)
        } else {
            manager.stopCachingImages(for: assets, targetSize: size, contentMode: contentMode, options: options)
        }
    }

    /// `allowsNetwork` is false when the caller has a server copy to fall back
    /// on: pulling the original down from icloud would be the slower of the
    /// two, and "available on device" should mean actually on the device.
    func playerItem(localIdentifier: String, allowsNetwork: Bool = true) async -> AVPlayerItem? {
        guard let asset = fetchAsset(localIdentifier) else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = allowsNetwork
        return await withCheckedContinuation { continuation in
            manager.requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    // MARK: - live photo motion

    /// exported motion halves, newest last. the viewer seeks through these, so
    /// they outlive a single page, but browsing a library of live photos would
    /// otherwise fill the temp directory a few megabytes at a time.
    private static let motionCacheLimit = 24

    private var motionDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "live-photo-motion")
    }

    /// motion half of a device live photo as a seekable item. photokit only
    /// vends live photos as `PHLivePhoto`, which plays as an opaque unit and
    /// cannot be scrubbed, so the paired video resource is exported instead.
    func motionPlayerItem(localIdentifier: String, allowsNetwork: Bool = true) async -> AVPlayerItem? {
        guard let url = await motionFile(localIdentifier: localIdentifier, allowsNetwork: allowsNetwork)
        else { return nil }
        return AVPlayerItem(url: url)
    }

    /// concurrent for the same reason as `image`: the resource lookup and the
    /// export are both blocking photokit work.
    @concurrent
    private func motionFile(localIdentifier: String, allowsNetwork: Bool) async -> URL? {
        let directory = motionDirectory
        // localidentifiers carry a "uuid/L0/001" shape that cannot be a path.
        let name = localIdentifier.replacingOccurrences(of: "/", with: "_")
        let destination = directory.appending(path: "\(name).mov")
        if FileManager.default.fileExists(atPath: destination.path) {
            noteMotionUse(destination)
            return destination
        }

        guard let asset = fetchAsset(localIdentifier) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePairedVideo })
            ?? resources.first(where: { $0.type == .pairedVideo })
        else { return nil }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = allowsNetwork
        // written to a unique path first: an interrupted write would otherwise
        // leave a truncated file that every later play would trust.
        let staging = directory.appending(path: "staging-\(UUID().uuidString).mov")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: staging, options: options) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            // a concurrent export of the same asset may have landed first.
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return nil
        }
        noteMotionUse(destination)
        return destination
    }

    /// keeps the export directory bounded, evicting whatever was touched least
    /// recently rather than whatever happens to be on screen.
    private func noteMotionUse(_ url: URL) {
        let evicted = motionFiles.withLock { files -> URL? in
            files.removeAll { $0 == url }
            files.append(url)
            guard files.count > Self.motionCacheLimit else { return nil }
            return files.removeFirst()
        }
        if let evicted { try? FileManager.default.removeItem(at: evicted) }
    }
}

/// lock-guarded handle on one photokit image request, shared between the
/// stream's termination handler and the task that starts the request. covers
/// the race where the consumer gives up before the request id exists.
private nonisolated final class ImageRequestBox: @unchecked Sendable {
    private struct State {
        var requestID: PHImageRequestID?
        var cancelled = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var isCancelled: Bool {
        lock.withLock { $0.cancelled }
    }

    func register(_ requestID: PHImageRequestID, manager: PHImageManager) {
        let cancelNow = lock.withLock { state in
            state.requestID = requestID
            return state.cancelled
        }
        if cancelNow { manager.cancelImageRequest(requestID) }
    }

    func cancel(_ manager: PHImageManager) {
        let requestID = lock.withLock { state -> PHImageRequestID? in
            state.cancelled = true
            return state.requestID
        }
        if let requestID { manager.cancelImageRequest(requestID) }
    }
}
