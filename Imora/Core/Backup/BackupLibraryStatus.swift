import Foundation

extension MediaCounts {
    nonisolated init(assets: [DeviceAsset]) {
        for asset in assets { add(asset) }
    }

    nonisolated mutating func add(_ asset: DeviceAsset) {
        if asset.isVideo && !asset.isLivePhoto { videos += 1 } else { photos += 1 }
    }
}

/// A Live Photo only counts as backed up when both resources are confirmed.
nonisolated struct BackupLibraryStatus: Equatable, Sendable {
    private(set) var totalMedia = MediaCounts()
    private(set) var backedUpMedia = MediaCounts()
    private(set) var unindexedMedia = MediaCounts()
    private(set) var unsupportedMedia = MediaCounts()
    private(set) var pendingMedia = MediaCounts()

    var total: Int { totalMedia.total }
    var backedUp: Int { backedUpMedia.total }
    var unindexed: Int { unindexedMedia.total }
    var unsupported: Int { unsupportedMedia.total }
    var pending: Int { pendingMedia.total }
    var isUpToDate: Bool { pending == 0 && unsupported == 0 }

    init(assets: [DeviceAsset], entries: [String: BackupEntry]) {
        for asset in assets {
            totalMedia.add(asset)
            guard let entry = entries[asset.localIdentifier],
                  entry.matches(modificationDate: asset.modificationDate),
                  entry.isLivePhoto == asset.isLivePhoto else {
                unindexedMedia.add(asset)
                pendingMedia.add(asset)
                continue
            }
            if entry.isBackedUp { backedUpMedia.add(asset) }
            else if entry.unsupported { unsupportedMedia.add(asset) }
            else { pendingMedia.add(asset) }
        }
    }

    var countText: String {
        total == 0 ? "No photos or videos in your library."
            : "\(backedUpMedia.text) backed up"
    }

    static let upToDateText = "Done. No new photos or videos to back up."

    func completionText(_ summary: BackupSummary) -> String {
        var details: [String] = []
        if summary.uploaded > 0 { details.append("\(summary.uploadedMedia.text) uploaded") }
        if summary.failed > 0 { details.append("\(summary.failedMedia.text) failed") }
        if summary.skipped > 0 { details.append("\(summary.skippedMedia.text) skipped") }
        if unsupported > 0 { details.append("\(unsupportedMedia.text) unsupported") }
        if pending > 0 { details.append("\(pendingMedia.text) still to index or back up") }
        if details.isEmpty { return Self.upToDateText }
        return (summary.failed > 0 || pending > 0 || unsupported > 0 ? "Backup incomplete. " : "Done. ")
            + details.joined(separator: "; ") + "."
    }
}
