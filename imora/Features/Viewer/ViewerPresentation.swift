import Foundation
import Observation

nonisolated struct ViewerRoute: Identifiable, Hashable {
    let id: UUID
    let assets: [Asset]
    let initialIndex: Int
    let sourceAssetID: String

    static func == (lhs: ViewerRoute, rhs: ViewerRoute) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@MainActor
@Observable
final class ViewerPresentation {
    var route: ViewerRoute?
    private var activeID: UUID?

    var isTransitioning: Bool { activeID != nil }

    /// presents even while a previous cover is still tearing down - the fresh
    /// route uuid gives the new viewer clean state and the late onDisappear of
    /// the old one is ignored by complete(). refusing here made rapid taps
    /// feel dead. only an already visible route blocks a new one.
    @discardableResult
    func present(assets: [Asset], initialIndex: Int) -> Bool {
        guard route == nil, assets.indices.contains(initialIndex) else { return false }
        let route = ViewerRoute(
            id: UUID(),
            assets: assets,
            initialIndex: initialIndex,
            sourceAssetID: assets[initialIndex].id
        )
        activeID = route.id
        self.route = route
        return true
    }

    func complete(_ id: UUID) {
        guard activeID == id else { return }
        route = nil
        activeID = nil
    }
}
