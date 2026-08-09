import CoreGraphics

/// The viewer is two vertically aligned destinations: the media and its
/// information. Keeping their shared height in one value prevents one page
/// from shrinking independently as the surrounding chrome changes.
nonisolated struct AssetViewerPageLayout: Equatable {
    let mediaHeight: CGFloat
    let informationHeight: CGFloat
    let informationTopContentInset: CGFloat
    let informationBottomContentInset: CGFloat

    init(
        viewportHeight: CGFloat,
        viewportWidth: CGFloat = 0,
        topSafeAreaInset: CGFloat = 0,
        bottomSafeAreaInset: CGFloat = 0
    ) {
        let pageHeight = max(0, viewportHeight)
        mediaHeight = pageHeight
        informationHeight = pageHeight

        guard pageHeight > 0 else {
            informationTopContentInset = 0
            informationBottomContentInset = 0
            return
        }

        // The viewer deliberately extends under its floating toolbars. Keep
        // the information surface edge-to-edge while moving only its readable
        // content clear of those controls.
        let portrait = viewportWidth <= 0 || viewportHeight >= viewportWidth
        let minimumTopInset: CGFloat = portrait ? 90 : 60
        let minimumBottomInset: CGFloat = portrait ? 104 : 76
        informationTopContentInset = max(minimumTopInset, max(0, topSafeAreaInset) + 16)
        informationBottomContentInset = max(minimumBottomInset, max(0, bottomSafeAreaInset) + 50)
    }
}
