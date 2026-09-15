import Foundation

// Minimal metadata/index fixtures; the production status calculation and
// media counting implementation are compiled unchanged by screenshots.py.
struct DeviceAsset {
    let localIdentifier: String
    var isVideo = false
    var isLivePhoto = false
    var isScreenshot = false
    var modificationDate: Date? = nil
}
struct BackupEntry {
    var isLivePhoto = false
    var isBackedUp = false
    var unsupported = false
    func matches(modificationDate: Date?) -> Bool { true }
}
struct BackupSummary {
    var uploadedMedia = MediaCounts()
    var failedMedia = MediaCounts()
    var skippedMedia = MediaCounts()
    var uploaded: Int { uploadedMedia.total }
    var failed: Int { failedMedia.total }
    var skipped: Int { skippedMedia.total }
}

@main struct ScreenshotSelectionChecks {
    static func main() {
        let screenshot = DeviceAsset(localIdentifier: "screenshot", isScreenshot: true)
        let photo = DeviceAsset(localIdentifier: "photo")
        let video = DeviceAsset(localIdentifier: "video", isVideo: true)
        let live = DeviceAsset(localIdentifier: "live", isLivePhoto: true)
        let assets = [screenshot, photo, video, live]
        let entries = ["photo": BackupEntry(isBackedUp: true),
                       "video": BackupEntry(isBackedUp: true),
                       "live": BackupEntry(isLivePhoto: true, isBackedUp: true)]
        let included = BackupLibraryStatus(assets: assets, entries: entries)
        precondition(included.total == 4 && included.pending == 1 && included.excluded == 0)
        let excluded = BackupLibraryStatus(assets: assets, entries: entries, excludeScreenshots: true)
        precondition(excluded.total == 3 && excluded.pending == 0 && excluded.unindexed == 0)
        precondition(excluded.isUpToDate && excluded.excluded == 1)
        precondition(excluded.backedUpMedia == MediaCounts(photos: 2, videos: 1))
        let onlyScreenshots = BackupLibraryStatus(assets: [screenshot], entries: [:], excludeScreenshots: true)
        precondition(onlyScreenshots.isUpToDate && onlyScreenshots.total == 0 && onlyScreenshots.excluded == 1)
        precondition(onlyScreenshots.countText == "No photos or videos selected for backup.")
        let reIncluded = BackupLibraryStatus(assets: assets, entries: entries, excludeScreenshots: false)
        precondition(reIncluded.pending == 1 && !reIncluded.isUpToDate)
        var backedUpEntries = entries
        backedUpEntries["screenshot"] = BackupEntry(isBackedUp: true)
        let hiddenBackedUp = BackupLibraryStatus(assets: assets, entries: backedUpEntries, excludeScreenshots: true)
        precondition(hiddenBackedUp.backedUp == 3 && hiddenBackedUp.excluded == 1)
        let restoredBackedUp = BackupLibraryStatus(assets: assets, entries: backedUpEntries)
        precondition(restoredBackedUp.backedUp == 4 && restoredBackedUp.isUpToDate)
        print("PASS: default inclusion, screenshot exclusion, accurate pending/media counts, screenshot-only libraries, and re-inclusion")
    }
}
