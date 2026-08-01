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

    private func key(_ localIdentifier: String, _ size: CGFloat) -> NSString {
        "\(localIdentifier)#\(Int(size))" as NSString
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

    func cachedImage(localIdentifier: String, targetPixelSize: CGFloat) -> UIImage? {
        cache.object(forKey: key(localIdentifier, targetPixelSize))
    }

    func image(localIdentifier: String, targetPixelSize: CGFloat) async -> UIImage? {
        if let cached = cachedImage(localIdentifier: localIdentifier, targetPixelSize: targetPixelSize) {
            return cached
        }
        guard let asset = fetchAsset(localIdentifier) else { return nil }
        let size = CGSize(width: targetPixelSize, height: targetPixelSize)
        let image = await withCheckedContinuation { continuation in
            manager.requestImage(
                for: asset, targetSize: size, contentMode: .aspectFill, options: Self.requestOptions()
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: key(localIdentifier, targetPixelSize), cost: cost)
        }
        return image
    }

    // MARK: - prefetching

    func startCaching(localIdentifiers: [String], targetPixelSize: CGFloat) {
        setCaching(true, localIdentifiers: localIdentifiers, targetPixelSize: targetPixelSize)
    }

    func stopCaching(localIdentifiers: [String], targetPixelSize: CGFloat) {
        setCaching(false, localIdentifiers: localIdentifiers, targetPixelSize: targetPixelSize)
    }

    private func setCaching(_ caching: Bool, localIdentifiers: [String], targetPixelSize: CGFloat) {
        let assets = localIdentifiers.compactMap(fetchAsset)
        guard !assets.isEmpty else { return }
        let size = CGSize(width: targetPixelSize, height: targetPixelSize)
        if caching {
            manager.startCachingImages(
                for: assets, targetSize: size, contentMode: .aspectFill, options: Self.requestOptions()
            )
        } else {
            manager.stopCachingImages(
                for: assets, targetSize: size, contentMode: .aspectFill, options: Self.requestOptions()
            )
        }
    }

    func playerItem(localIdentifier: String) async -> AVPlayerItem? {
        guard let asset = fetchAsset(localIdentifier) else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            manager.requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }
}
