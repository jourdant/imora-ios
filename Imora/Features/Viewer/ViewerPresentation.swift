import Foundation
import Observation

nonisolated struct ViewerRoute: Identifiable, Hashable {
    let id: UUID
    let assets: [Asset]
    let indexByAssetID: [String: Int]
    let initialIndex: Int
    let sourceAssetID: String

    static func == (lhs: ViewerRoute, rhs: ViewerRoute) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Resolves the semantic pager selection after a page leaves the collection.
/// Identity wins over a stale numeric index; if the selected page itself was
/// removed, its following neighbor (or the new last page) takes its place.
nonisolated struct AssetViewerSelectionResolution: Equatable, Sendable {
    let assetID: String?
    let index: Int

    static func resolve(
        remainingAssetIDs: [String],
        selectedAssetID: String?,
        removedIndex: Int
    ) -> Self {
        if let selectedAssetID,
           let index = remainingAssetIDs.firstIndex(of: selectedAssetID) {
            return Self(assetID: selectedAssetID, index: index)
        }
        guard !remainingAssetIDs.isEmpty else {
            return Self(assetID: nil, index: 0)
        }
        let index = min(max(0, removedIndex), remainingAssetIDs.count - 1)
        return Self(assetID: remainingAssetIDs[index], index: index)
    }
}

@MainActor
@Observable
final class ViewerPresentation {
    var route: ViewerRoute?
    @ObservationIgnored private var activeID: UUID?

    var isTransitioning: Bool { activeID != nil }

    func isActive(_ id: UUID) -> Bool {
        activeID == id
    }

    func makeRoute(
        assets: [Asset],
        initialIndex: Int,
        indexByAssetID: [String: Int]? = nil
    ) -> ViewerRoute? {
        guard assets.indices.contains(initialIndex) else { return nil }
        return ViewerRoute(
            id: UUID(),
            assets: assets,
            indexByAssetID: indexByAssetID ?? Self.indexMap(for: assets),
            initialIndex: initialIndex,
            sourceAssetID: assets[initialIndex].id
        )
    }

    /// Activates a previously built route. Context-menu previews deliberately
    /// build without activating: cancelling the menu must not suspend its grid.
    /// UIKit-owned viewers also activate without publishing a SwiftUI cover.
    @discardableResult
    func activate(
        _ route: ViewerRoute,
        presentsCover: Bool,
        replacesSettlingPresentation: Bool = false
    ) -> Bool {
        guard self.route == nil else { return false }
        guard activeID == nil || replacesSettlingPresentation else { return false }
        activeID = route.id
        if presentsCover { self.route = route }
        return true
    }

    /// Presents even while a previous cover is still tearing down - the fresh
    /// route uuid gives the new viewer clean state and the late onDisappear of
    /// the old one is ignored by complete(). Refusing here made rapid taps
    /// feel dead. Only an already visible route blocks a new one.
    @discardableResult
    func present(
        assets: [Asset],
        initialIndex: Int,
        indexByAssetID: [String: Int]? = nil
    ) -> Bool {
        guard let route = makeRoute(
            assets: assets,
            initialIndex: initialIndex,
            indexByAssetID: indexByAssetID
        ) else { return false }
        return activate(route, presentsCover: true, replacesSettlingPresentation: true)
    }

    private static func indexMap(for assets: [Asset]) -> [String: Int] {
        var result = [String: Int](minimumCapacity: assets.count)
        for (index, asset) in assets.enumerated() {
            result[asset.id] = index
        }
        return result
    }

    func complete(_ id: UUID) {
        guard activeID == id else { return }
        route = nil
        activeID = nil
    }
}
