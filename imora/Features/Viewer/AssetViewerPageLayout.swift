import CoreGraphics

/// continuous geometry for the viewer's information transition. progress 0 is
/// the immersive full-screen fit, progress 1 leaves a compact strip above the
/// information panel with the media covering it edge to edge like an
/// aspect-fill image. every value in between is a plain scale and translate
/// of the very same page, so the transition can track a finger frame by frame
/// with no content swap or relayout anywhere.
nonisolated enum AssetViewerPageLayout {
    /// swiftui measures fractional sheet detents inside the maximum-detent
    /// region rather than the whole display. used by the regular-width
    /// floating sheet only.
    static let informationSheetFraction: CGFloat = 0.88
    /// share of the viewport the media keeps above the information panel.
    static let informationMediaFraction: CGFloat = 0.2

    static func mediaStripHeight(viewportHeight: CGFloat) -> CGFloat {
        max(1, viewportHeight * informationMediaFraction)
    }

    /// how far the information panel travels between hidden and presented,
    /// which is also the finger travel that maps to the full transition.
    static func informationPanelTravel(viewportHeight: CGFloat) -> CGFloat {
        max(1, viewportHeight - mediaStripHeight(viewportHeight: viewportHeight))
    }

    /// scale and vertical shift that carry a fit-rendered page from resting
    /// full screen to covering the strip at progress 1. the scale grows until
    /// the fitted image fills the strip and the offset recenters it there.
    static func mediaTransform(
        ratio: Double,
        viewport: CGSize,
        progress: CGFloat
    ) -> (scale: CGFloat, offsetY: CGFloat) {
        guard progress > 0, viewport.width > 0, viewport.height > 0 else { return (1, 0) }
        let ratio = CGFloat(ratio > 0 ? ratio : 1)
        let fitWidth = min(viewport.width, viewport.height * ratio)
        let fitHeight = fitWidth / ratio
        let strip = mediaStripHeight(viewportHeight: viewport.height)
        let fillScale = max(viewport.width / fitWidth, strip / fitHeight)
        let scale = 1 + (fillScale - 1) * progress
        let offsetY = (strip - viewport.height) / 2 * progress
        return (scale, offsetY)
    }
}
