import Testing
@testable import imora

@Suite("Asset viewer page layout")
struct AssetViewerPageLayoutTests {
    @Test("media and information each fill an 844-point viewport")
    func bothPagesFillTheViewport() {
        let layout = AssetViewerPageLayout(viewportHeight: 844)

        #expect(layout.mediaHeight == 844)
        #expect(layout.informationHeight == 844)
    }

    @Test("an unavailable viewport never produces negative page heights")
    func invalidViewportIsClamped() {
        let layout = AssetViewerPageLayout(viewportHeight: -1)

        #expect(layout.mediaHeight == 0)
        #expect(layout.informationHeight == 0)
    }

    @Test("information content clears floating viewer chrome")
    func informationContentClearsViewerChrome() {
        let portrait = AssetViewerPageLayout(
            viewportHeight: 874,
            viewportWidth: 402,
            topSafeAreaInset: 0,
            bottomSafeAreaInset: 0
        )
        let landscape = AssetViewerPageLayout(
            viewportHeight: 393,
            viewportWidth: 874,
            topSafeAreaInset: 0,
            bottomSafeAreaInset: 21
        )

        #expect(portrait.informationTopContentInset == 90)
        #expect(portrait.informationBottomContentInset == 104)
        #expect(landscape.informationTopContentInset == 60)
        #expect(landscape.informationBottomContentInset == 76)
    }
}
