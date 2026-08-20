import Foundation

nonisolated struct AssetViewerOpeningSwipeInteraction {
    let startingFraction: CGFloat

    init(startingFraction: CGFloat) {
        self.startingFraction = min(1, max(0, startingFraction))
    }

    func openingFraction(forDismissalProgress progress: CGFloat) -> CGFloat {
        min(1, max(0, startingFraction - max(0, progress)))
    }

    static func shouldClose(
        progress: CGFloat,
        projectedProgress: CGFloat
    ) -> Bool {
        progress > 0.14 || projectedProgress > 0.28
    }
}

nonisolated enum AssetViewerOpeningChromeReveal {
    static let initialBackdropOpacity: CGFloat = 0.02

    static func coverOpacity(isRevealed: Bool) -> CGFloat {
        isRevealed ? 0 : 1
    }

    static func duration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : 0.16
    }
}
