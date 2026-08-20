import AVFoundation
import Photos
import UIKit
import os

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
    private let assets = OSAllocatedUnfairLock<[String: PHAsset]>(initialState: [:])
    /// exported live photo motion files in least-recently-used order.
    private let motionFiles = OSAllocatedUnfairLock<[URL]>(initialState: [])
    /// a window can be eighty identifiers wide and every miss is a synchronous
    /// library query, so the bookkeeping stays off the caller's thread. serial
    /// keeps a stop from overtaking the start it cancels.
    private let cachingQueue = DispatchQueue(label: "app.imora.local-image-caching", qos: .userInitiated)

    private init() {
        cache = NSCache()
        cache.totalCostLimit = 96 << 20
    }

    /// asset lookups are cached; a library change invalidates them all.
    func noteLibraryChange() {
        assets.withLock { $0.removeAll() }
        manager.stopCachingImagesForAllAssets()
    }

    private func fetchAsset(_ localIdentifier: String) -> PHAsset? {
        if let cached = assets.withLock({ $0[localIdentifier] }) { return cached }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            return nil
        }
        assets.withLock { $0[localIdentifier] = asset }
        return asset
    }

    private func key(
        _ localIdentifier: String,
        _ size: CGFloat,
        _ contentMode: PHImageContentMode
    ) -> NSString {
        "\(localIdentifier)#\(Int(size))#\(contentMode.rawValue)" as NSString
    }

    /// the caching manager only serves a prefetched thumbnail when the request
    /// that follows carries the same options, so both paths share these.
    private static func requestOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        // one delivery per request, so the continuation resumes exactly once.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
    }

    func cachedImage(
        localIdentifier: String,
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode = .aspectFill
    ) -> UIImage? {
        cache.object(forKey: key(localIdentifier, targetPixelSize, contentMode))
    }

    /// concurrent so the photokit fetch never runs inline on the caller. under
    /// approachable concurrency a plain nonisolated async body stays on the
    /// caller's actor, which put a synchronous library query on the main
    /// thread every time a page or tile asked for its image.
    @concurrent
    func image(
        localIdentifier: String,
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode = .aspectFill
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
        let image = await withCheckedContinuation { continuation in
            manager.requestImage(
                for: asset, targetSize: size, contentMode: contentMode, options: Self.requestOptions()
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(
                image,
                forKey: key(localIdentifier, targetPixelSize, contentMode),
                cost: cost
            )
        }
        return image
    }

    // MARK: - prefetching

    func startCaching(
        localIdentifiers: [String],
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode = .aspectFill
    ) {
        cachingQueue.async { [self] in
            setCaching(
                true,
                localIdentifiers: localIdentifiers,
                targetPixelSize: targetPixelSize,
                contentMode: contentMode
            )
        }
    }

    func stopCaching(
        localIdentifiers: [String],
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode = .aspectFill
    ) {
        cachingQueue.async { [self] in
            setCaching(
                false,
                localIdentifiers: localIdentifiers,
                targetPixelSize: targetPixelSize,
                contentMode: contentMode
            )
        }
    }

    private func setCaching(
        _ caching: Bool,
        localIdentifiers: [String],
        targetPixelSize: CGFloat,
        contentMode: PHImageContentMode
    ) {
        let assets = localIdentifiers.compactMap(fetchAsset)
        guard !assets.isEmpty else { return }
        let size = CGSize(width: targetPixelSize, height: targetPixelSize)
        if caching {
            manager.startCachingImages(
                for: assets, targetSize: size, contentMode: contentMode, options: Self.requestOptions()
            )
        } else {
            manager.stopCachingImages(
                for: assets, targetSize: size, contentMode: contentMode, options: Self.requestOptions()
            )
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
