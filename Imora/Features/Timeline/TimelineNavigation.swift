import Foundation
import Observation

nonisolated struct TimelineNavigationTarget: Equatable, Sendable {
    let assetID: String
    let localAssetID: String?
    let localDate: Date

    init(asset: Asset, serverAssetID: String?) {
        assetID = serverAssetID ?? asset.id
        localAssetID = asset.localIdentifier.map { "local-\($0)" }
        localDate = asset.localDate
    }

    var candidateAssetIDs: [String] {
        guard let localAssetID, localAssetID != assetID else { return [assetID] }
        return [assetID, localAssetID]
    }
}

@MainActor
@Observable
final class TimelineNavigationRouter {
    static let shared = TimelineNavigationRouter()

    var pendingTarget: TimelineNavigationTarget?

    private init() {}

    func open(_ target: TimelineNavigationTarget) {
        pendingTarget = target
    }
}
