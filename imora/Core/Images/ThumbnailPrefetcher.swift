import Foundation

/// keeps a rolling window of grid thumbnails warm around what is on screen, so
/// a fling lands on decoded tiles instead of placeholders. each grid owns one,
/// and dropping it cancels only that grid's prefetches.
///
/// server tiles go through the nuke pipeline and device tiles through
/// photokit's caching manager, but both take the same window.
@MainActor
final class ThumbnailPrefetcher {
    /// tiles kept warm past the fold - roughly two phone screens, about what a
    /// fling covers before the network can answer.
    private static let lookAhead = 60
    /// scrolling back up is common enough to keep a short tail warm too.
    private static let lookBehind = 20

    private let targetPixelSize: CGFloat
    private var remote: Set<URL> = []
    private var local: Set<String> = []

    init(targetPixelSize: CGFloat = 640) {
        self.targetPixelSize = targetPixelSize
    }

    /// anchors on the first visible tile row and warms the assets around it.
    func update(visibleRowIDs: [String], model: TimelineModel, client: ImmichClient?) {
        guard let client,
              let anchorID = visibleRowIDs.lazy.compactMap({ model.firstAssetIDByRowID[$0] }).first,
              let anchor = model.flatAssetIndex(for: anchorID)
        else { return cancel() }

        let assets = model.flatAssets
        let lower = max(0, anchor - Self.lookBehind)
        let upper = min(assets.count, anchor + Self.lookAhead)
        guard lower < upper else { return cancel() }

        var remote: Set<URL> = []
        var local: Set<String> = []
        for asset in assets[lower..<upper] {
            if let localIdentifier = asset.localIdentifier {
                local.insert(localIdentifier)
            } else {
                remote.insert(client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash))
            }
        }
        apply(remote: remote, local: local)
    }

    /// warms an explicit window, for hosts that already know theirs: the
    /// viewer pages a flat list and picks its own thumbnail size.
    func warm(remote: Set<URL>, local: Set<String>) {
        apply(remote: remote, local: local)
    }

    func cancel() {
        apply(remote: [], local: [])
    }

    private func apply(remote: Set<URL>, local: Set<String>) {
        if remote != self.remote {
            let added = remote.subtracting(self.remote)
            let dropped = self.remote.subtracting(remote)
            if !added.isEmpty {
                ImageLoader.shared.startPrefetching(urls: Array(added), targetPixelSize: targetPixelSize)
            }
            if !dropped.isEmpty {
                ImageLoader.shared.stopPrefetching(urls: Array(dropped), targetPixelSize: targetPixelSize)
            }
            self.remote = remote
        }

        if local != self.local {
            let added = local.subtracting(self.local)
            let dropped = self.local.subtracting(local)
            if !added.isEmpty {
                LocalImageLoader.shared.startCaching(localIdentifiers: Array(added), targetPixelSize: targetPixelSize)
            }
            if !dropped.isEmpty {
                LocalImageLoader.shared.stopCaching(localIdentifiers: Array(dropped), targetPixelSize: targetPixelSize)
            }
            self.local = local
        }
    }
}
