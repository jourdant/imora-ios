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

    func makeRoute(assets: [Asset], initialIndex: Int) -> ViewerRoute? {
        guard assets.indices.contains(initialIndex) else { return nil }
        return ViewerRoute(
            id: UUID(),
            assets: assets,
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
    func present(assets: [Asset], initialIndex: Int) -> Bool {
        guard let route = makeRoute(assets: assets, initialIndex: initialIndex) else { return false }
        return activate(route, presentsCover: true, replacesSettlingPresentation: true)
    }

    func complete(_ id: UUID) {
        guard activeID == id else { return }
        route = nil
        activeID = nil
    }
}
