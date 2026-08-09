import CoreGraphics

/// Sizes the media as the viewer moves between its immersive and information
/// presentations. The information surface occupies 80% of the viewport, so
/// the asset remains visible and refits the strip above it.
nonisolated struct AssetViewerPageLayout: Equatable {
    /// SwiftUI measures fractional sheet detents inside the maximum-detent
    /// region rather than the whole display. 0.88 leaves roughly one fifth of
    /// a Dynamic Island phone visible above the sheet.
    static let informationSheetFraction: CGFloat = 0.88
    static let informationMediaFraction: CGFloat = 0.2

    let mediaHeight: CGFloat
    let informationMediaHeight: CGFloat
    private let viewportWidth: CGFloat

    init(viewportHeight: CGFloat, viewportWidth: CGFloat = 0) {
        let pageHeight = max(0, viewportHeight)
        mediaHeight = pageHeight
        informationMediaHeight = pageHeight * Self.informationMediaFraction
        self.viewportWidth = max(0, viewportWidth)
    }

    /// Once presented, the sheet's real global frame is the source of truth
    /// for the media region. Regular-width floating sheets leave the full
    /// viewer in place instead of collapsing an unrelated strip behind them.
    func mediaHeight(forInformationSheet sheetFrame: CGRect, compactWidth: Bool = true) -> CGFloat {
        guard sheetFrame.width > 0 else {
            return compactWidth ? informationMediaHeight : mediaHeight
        }
        guard viewportWidth <= 0 || sheetFrame.width >= viewportWidth * 0.9 else {
            return mediaHeight
        }
        return min(mediaHeight, max(0, sheetFrame.minY))
    }
}
