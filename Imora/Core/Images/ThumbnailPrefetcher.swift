import Foundation
import Photos

/// keeps a rolling window of grid thumbnails warm around what is on screen, so
/// a fling lands on decoded tiles instead of placeholders. each grid owns one,
/// and dropping it cancels only that grid's prefetches.
///
/// server tiles go through the nuke pipeline and device tiles through
/// photokit's caching manager, but both take the same window.
@MainActor
final class ThumbnailPrefetcher {
    /// tiles kept warm past the fold, about what a fast fling can reveal before
    /// the network can answer.
    private static let lookAhead = 36
    /// scrolling back up is common enough to keep a short tail warm too.
    private static let lookBehind = 12

    private var targetPixelSize: CGFloat
    private let localContentMode: PHImageContentMode
    /// the caching manager only serves requests whose target matches, so
    /// this has to agree with what the tiles ask for.
    private let localCoversTarget: Bool
    private var remote: Set<URL> = []
    /// device-only assets: the library is their only source, so icloud may
    /// be asked for them.
    private var local: Set<String> = []
    /// device copies of server assets: rendered from the library when it has
    /// them, never downloaded for a tile the server can serve. kept apart
    /// because the caching manager only serves requests whose options match.
    private var paired: Set<String> = []
    /// the asset range last warmed, with the `flatAssets` revision it was taken
    /// from. a fling reports visible rows far more often than the window it
    /// implies actually moves, and rebuilding it costs a url per asset.
    private var window: Range<Int>?
    private var windowVersion = -1

    init(
        targetPixelSize: CGFloat = 640,
        localContentMode: PHImageContentMode = .aspectFill,
        localCoversTarget: Bool = false
    ) {
        self.targetPixelSize = targetPixelSize
        self.localContentMode = localContentMode
        self.localCoversTarget = localCoversTarget
    }

    /// anchors on both ends of the visible tile rows and warms the assets
    /// around them, the long side of the window facing the way the grid is
    /// going: 1 towards the bottom, -1 towards the top, 0 at rest.
    func update(
        visibleRowIDs: [String],
        model: TimelineModel,
        client: ImmichClient?,
        backup: BackupManager?,
        targetPixelSize: CGFloat? = nil,
        direction: Int = 0
    ) {
        if let targetPixelSize {
            updateTargetPixelSize(targetPixelSize)
        }
        // both ends anchor the window, so the look-ahead starts past the
        // fold rather than a screen short of it.
        guard let client,
              let firstID = visibleRowIDs.lazy.compactMap({ model.firstAssetIDByRowID[$0] }).first,
              let lastID = visibleRowIDs.reversed().lazy.compactMap({ model.firstAssetIDByRowID[$0] }).first,
              let first = model.flatAssetIndex(for: firstID),
              let last = model.flatAssetIndex(for: lastID)
        else { return cancel() }

        let assets = model.flatAssets
        let (behind, ahead) = direction < 0
            ? (Self.lookAhead, Self.lookBehind)
            : (Self.lookBehind, Self.lookAhead)
        let lower = max(0, min(first, last) - behind)
        let upper = min(assets.count, max(first, last) + 1 + ahead)
        guard lower < upper else { return cancel() }

        let version = model.flatAssetsVersion
        guard window != lower..<upper || windowVersion != version else { return }
        window = lower..<upper
        windowVersion = version

        var remote: Set<URL> = []
        var local: Set<String> = []
        var paired: Set<String> = []
        remote.reserveCapacity(upper - lower)
        for asset in assets[lower..<upper] {
            // tiles render the device copy when one is paired, so warm the
            // same source, with the same options, the tile will ask for.
            if let localIdentifier = asset.localIdentifier {
                local.insert(localIdentifier)
            } else if let localIdentifier = backup?.localIdentifierByRemoteId[asset.id] {
                paired.insert(localIdentifier)
            } else {
                remote.insert(client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash))
            }
        }
        apply(remote: remote, local: local, paired: paired)
    }

    /// warms an explicit window, for hosts that already know theirs: the
    /// viewer pages a flat list and picks its own thumbnail size.
    func warm(remote: Set<URL>, local: Set<String>) {
        window = nil
        apply(remote: remote, local: local, paired: [])
    }

    func cancel() {
        window = nil
        windowVersion = -1
        apply(remote: [], local: [], paired: [])
    }

    private func updateTargetPixelSize(_ value: CGFloat) {
        let value = max(1, value.rounded(.up))
        guard value != targetPixelSize else { return }
        cancel()
        targetPixelSize = value
    }

    private func apply(remote: Set<URL>, local: Set<String>, paired: Set<String>) {
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
        self.local = syncLocal(local, from: self.local, allowsNetwork: true)
        self.paired = syncLocal(paired, from: self.paired, allowsNetwork: false)
    }

    private func syncLocal(
        _ wanted: Set<String>,
        from current: Set<String>,
        allowsNetwork: Bool
    ) -> Set<String> {
        guard wanted != current else { return current }
        let added = wanted.subtracting(current)
        let dropped = current.subtracting(wanted)
        if !added.isEmpty {
            LocalImageLoader.shared.startCaching(
                localIdentifiers: Array(added),
                targetPixelSize: targetPixelSize,
                contentMode: localContentMode,
                coversTarget: localCoversTarget,
                allowsNetwork: allowsNetwork
            )
        }
        if !dropped.isEmpty {
            LocalImageLoader.shared.stopCaching(
                localIdentifiers: Array(dropped),
                targetPixelSize: targetPixelSize,
                contentMode: localContentMode,
                coversTarget: localCoversTarget,
                allowsNetwork: allowsNetwork
            )
        }
        return wanted
    }
}
