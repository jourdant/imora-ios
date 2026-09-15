import Foundation

nonisolated enum BackupDateOrder: String, CaseIterable, Identifiable, Sendable {
    case newestFirst, oldestFirst
    var id: Self { self }
    var title: String { self == .newestFirst ? "Newest First" : "Oldest First" }
}

nonisolated enum BackupMediaPriority: String, CaseIterable, Identifiable, Sendable {
    case together, photosFirst, videosFirst
    var id: Self { self }
    var title: String {
        switch self {
        case .together: "Photos & Videos"
        case .photosFirst: "Photos First"
        case .videosFirst: "Videos First"
        }
    }

    private func rank(_ asset: DeviceAsset) -> Int {
        switch self {
        case .together: 0
        case .photosFirst: asset.isVideo ? 1 : 0
        case .videosFirst: asset.isVideo ? 0 : 1
        }
    }

    /// Priority affects queue order, never inclusion. A Live Photo remains a
    /// single photo here; uploadOne still sends its paired motion first.
    func order(_ assets: [DeviceAsset], by dateOrder: BackupDateOrder) -> [DeviceAsset] {
        assets.sorted { left, right in
            let leftRank = rank(left), rightRank = rank(right)
            if leftRank != rightRank { return leftRank < rightRank }
            switch (left.creationDate, right.creationDate) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return dateOrder == .newestFirst ? leftDate > rightDate : leftDate < rightDate
            case (nil, .some): return false
            case (.some, nil): return true
            default: return left.localIdentifier < right.localIdentifier
            }
        }
    }
}
