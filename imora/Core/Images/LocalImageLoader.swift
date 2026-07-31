import AVFoundation
import Photos
import UIKit
import os

/// async photokit loading for device assets merged into the timeline, with
/// the same memory cache idea as the remote imageloader so tiles scrolling
/// back into view render on the first frame.
nonisolated final class LocalImageLoader: Sendable {
    static let shared = LocalImageLoader()

    private let cache: NSCache<NSString, UIImage>
    private let assets = OSAllocatedUnfairLock<[String: PHAsset]>(initialState: [:])

    private init() {
        cache = NSCache()
        cache.totalCostLimit = 96 << 20
    }

    /// asset lookups are cached; a library change invalidates them all.
    func noteLibraryChange() {
        assets.withLock { $0.removeAll() }
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

    func cachedImage(localIdentifier: String, targetPixelSize: CGFloat) -> UIImage? {
        cache.object(forKey: key(localIdentifier, targetPixelSize))
    }

    func image(localIdentifier: String, targetPixelSize: CGFloat) async -> UIImage? {
        if let cached = cachedImage(localIdentifier: localIdentifier, targetPixelSize: targetPixelSize) {
            return cached
        }
        guard let asset = fetchAsset(localIdentifier) else { return nil }
        let options = PHImageRequestOptions()
        // one delivery per request, so the continuation resumes exactly once.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let size = CGSize(width: targetPixelSize, height: targetPixelSize)
        let image = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset, targetSize: size, contentMode: .aspectFill, options: options
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

    func playerItem(localIdentifier: String) async -> AVPlayerItem? {
        guard let asset = fetchAsset(localIdentifier) else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }
}
