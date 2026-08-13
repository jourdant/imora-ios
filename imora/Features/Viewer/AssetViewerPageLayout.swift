import CoreGraphics

/// One immutable sample of the compact viewer's vertical presentation. Keeping
/// these values together prevents chrome, dismissal, and media positioning
/// from observing different scroll frames during a gesture.
nonisolated struct AssetViewerScrollPresentation: Equatable, Sendable {
    let scrollOffset: CGFloat
    let mediaScale: CGFloat
    let mediaOffsetY: CGFloat
    let mediaFrameMaxY: CGFloat
    let informationProgress: CGFloat
    let isMediaAtTop: Bool
    let isShowingInformation: Bool
}

/// Resolves viewer chrome from semantic state in one place. The transport bar
/// has a separate reservation flag so loading, hiding chrome, or opening
/// information never changes a video's vertical viewport mid-transition.
nonisolated struct AssetViewerChromePresentation: Equatable, Sendable {
    let showsTopToolbarItems: Bool
    let showsViewerBottomBar: Bool
    let usesInformationBottomBarStyle: Bool
    let reservesVideoControls: Bool
    let showsVideoControls: Bool

    init(
        isCompact: Bool,
        isAtMedia: Bool,
        isInformationPresented: Bool,
        isChromeVisible: Bool,
        isContextPreview: Bool,
        isVideo: Bool,
        isVideoReady: Bool
    ) {
        let canShowChrome = isChromeVisible && !isContextPreview
        let mediaIsUnobstructed = isCompact ? isAtMedia : !isInformationPresented

        showsTopToolbarItems = canShowChrome && mediaIsUnobstructed
        showsViewerBottomBar = canShowChrome && (isCompact || !isInformationPresented)
        usesInformationBottomBarStyle = isCompact && !isAtMedia
        reservesVideoControls = isVideo && !isContextPreview
        showsVideoControls = reservesVideoControls
            && canShowChrome
            && mediaIsUnobstructed
            && isVideoReady
    }
}

/// Geometry for the compact viewer's single vertical surface. The media page
/// and information content share one scroll offset, so revealing metadata can
/// never leave the asset pinned in a separate strip.
nonisolated struct AssetViewerPageLayout: Equatable, Sendable {
    /// SwiftUI measures fractional sheet detents inside the maximum-detent
    /// region rather than the whole display. Used by the regular-width
    /// floating sheet only.
    static let informationSheetFraction: CGFloat = 0.88

    /// Photos keeps enough of the asset visible at the first information stop
    /// to preserve context. Further scrolling is deliberately unrestricted.
    static let informationVisibleMediaFraction: CGFloat = 0.46

    let viewport: CGSize
    let bottomSafeAreaInset: CGFloat

    init(viewport: CGSize, bottomSafeAreaInset: CGFloat = 0) {
        self.viewport = CGSize(
            width: max(0, viewport.width),
            height: max(0, viewport.height)
        )
        self.bottomSafeAreaInset = max(0, bottomSafeAreaInset)
    }

    var mediaHeight: CGFloat { viewport.height }

    var informationVisibleMediaHeight: CGFloat {
        mediaHeight * Self.informationVisibleMediaFraction
    }

    var informationRevealOffset: CGFloat {
        max(0, mediaHeight - informationVisibleMediaHeight)
    }

    /// Keeps short or loading information states tall enough to reach the
    /// first stop without synthesizing a second, nested scroll surface.
    var informationMinimumHeight: CGFloat {
        informationRevealOffset + bottomSafeAreaInset + 96
    }

    func informationProgress(scrollOffset: CGFloat) -> CGFloat {
        guard informationRevealOffset > 0 else { return 0 }
        return min(1, max(0, scrollOffset / informationRevealOffset))
    }

    /// The media page itself moves with the shared scroll all the way out of
    /// the viewport. This value exists separately from the fitted image's
    /// centering transform so regressions to a sticky header are testable.
    func mediaFrameMaxY(scrollOffset: CGFloat) -> CGFloat {
        max(0, mediaHeight - max(0, scrollOffset))
    }

    /// A fit-rendered asset follows the center of the shrinking visible area
    /// and grows only as much as necessary to cover the information header.
    /// The adjustment stops at the first information position so continued
    /// scroll carries the whole page naturally offscreen.
    func mediaTransform(
        scrollOffset: CGFloat,
        aspectRatio sourceAspectRatio: Double = 1
    ) -> (scale: CGFloat, offsetY: CGFloat) {
        let followedOffset = min(informationRevealOffset, max(0, scrollOffset))
        guard viewport.width > 0, viewport.height > 0 else {
            return (1, followedOffset / 2)
        }

        let finiteRatio = sourceAspectRatio.isFinite && sourceAspectRatio > 0
            ? CGFloat(sourceAspectRatio)
            : 1
        // Real media ratios are far inside this range. Clamping corrupted
        // metadata prevents an infinite transform while preserving cover.
        let aspectRatio = min(100, max(0.01, finiteRatio))
        let viewportRatio = viewport.width / viewport.height
        let fittedSize: CGSize
        if aspectRatio >= viewportRatio {
            fittedSize = CGSize(
                width: viewport.width,
                height: viewport.width / aspectRatio
            )
        } else {
            fittedSize = CGSize(
                width: viewport.height * aspectRatio,
                height: viewport.height
            )
        }

        let coverScale = max(
            1,
            viewport.width / fittedSize.width,
            informationVisibleMediaHeight / fittedSize.height
        )
        let progress = informationProgress(scrollOffset: followedOffset)
        let scale = 1 + (coverScale - 1) * progress
        return (scale, followedOffset / 2)
    }

    /// Derives every consumer-facing value from the same normalized sample.
    /// The exact endpoints are deliberately tolerant of sub-pixel settling,
    /// while intermediate frames remain purely visual and never change layout.
    func presentation(
        scrollOffset: CGFloat,
        aspectRatio: Double = 1
    ) -> AssetViewerScrollPresentation {
        let offset = scrollOffset.isFinite ? max(0, scrollOffset) : 0
        let transform = mediaTransform(scrollOffset: offset, aspectRatio: aspectRatio)
        let progress = informationProgress(scrollOffset: offset)
        let endpointTolerance: CGFloat = 1

        return AssetViewerScrollPresentation(
            scrollOffset: offset,
            mediaScale: transform.scale,
            mediaOffsetY: transform.offsetY,
            mediaFrameMaxY: mediaFrameMaxY(scrollOffset: offset),
            informationProgress: progress,
            isMediaAtTop: offset <= endpointTolerance,
            isShowingInformation: informationRevealOffset > 0
                && offset >= informationRevealOffset - endpointTolerance
        )
    }

    /// how close to an endpoint a gesture may start while still counting as
    /// leaving from that endpoint.
    private static let settleTolerance: CGFloat = 24

    /// Provides a single discoverable first stop without turning all metadata
    /// into page-aligned content. Once a gesture begins at that stop or below,
    /// upward movement remains a normal continuous scroll.
    func settledOffset(
        startOffset: CGFloat,
        proposedOffset: CGFloat,
        velocity: CGFloat = 0
    ) -> CGFloat {
        guard informationRevealOffset > 0 else { return 0 }
        let start = max(0, startOffset)
        let proposed = max(0, proposedOffset)
        let reveal = informationRevealOffset
        let endpointTolerance = Self.settleTolerance
        let activationDistance: CGFloat = 56
        let flickVelocity: CGFloat = 120
        let flickDistance: CGFloat = 8
        let delta = proposed - start
        let isFlick = abs(velocity) >= flickVelocity && abs(delta) >= flickDistance

        if start <= endpointTolerance {
            return delta >= activationDistance || (delta > 0 && isFlick) ? reveal : 0
        }

        // At the information stop, intent is directional: a modest downward
        // swipe closes, tiny projection noise stays put, and upward movement
        // continues through metadata without another snap.
        if abs(start - reveal) <= endpointTolerance {
            if delta <= -activationDistance || (delta < 0 && isFlick) { return 0 }
            if proposed > reveal { return proposed }
            return reveal
        }

        // Scrolling back from deeper metadata pauses at the information stop;
        // a subsequent downward swipe performs the close. This prevents one
        // high-velocity gesture from throwing the media past its useful stop.
        if start > reveal + endpointTolerance, proposed < reveal { return reveal }

        // An interrupted gesture between endpoints resolves according to its
        // direction, falling back to the nearest stable endpoint.
        if delta <= -activationDistance || (delta < 0 && isFlick) { return 0 }
        if delta >= activationDistance || (delta > 0 && isFlick) { return reveal }
        if proposed < reveal {
            return proposed < reveal / 2 ? 0 : reveal
        }
        return proposed
    }

    /// The endpoint a released gesture should be driven to directly, with the
    /// same animation the information button uses, instead of decelerating
    /// there like a scroll. Nil keeps native motion: gestures that begin in
    /// deeper metadata, continuations past the information stop, and releases
    /// already resting on their target.
    func directReleaseTarget(
        startOffset: CGFloat,
        releaseOffset: CGFloat,
        velocity: CGFloat
    ) -> CGFloat? {
        guard informationRevealOffset > 0 else { return nil }
        let start = max(0, startOffset)
        let release = max(0, releaseOffset)
        guard start <= informationRevealOffset + Self.settleTolerance else { return nil }
        let settled = settledOffset(
            startOffset: start,
            proposedOffset: release,
            velocity: velocity
        )
        guard settled == 0 || settled == informationRevealOffset else { return nil }
        guard abs(settled - release) > 1 else { return nil }
        return settled
    }
}
