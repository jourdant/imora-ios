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
/// information never changes a playable asset's vertical viewport mid-
/// transition. Videos and live photos both reserve it.
nonisolated struct AssetViewerChromePresentation: Equatable, Sendable {
    let showsTopToolbarItems: Bool
    let showsViewerBottomBar: Bool
    let reservesTransportControls: Bool
    let showsTransportControls: Bool

    init(
        isCompact: Bool,
        isAtMedia: Bool,
        isInformationPresented: Bool,
        isChromeVisible: Bool,
        isContextPreview: Bool,
        isPlayable: Bool,
        isPlayerReady: Bool
    ) {
        let canShowChrome = isChromeVisible && !isContextPreview
        let mediaIsUnobstructed = isCompact ? isAtMedia : !isInformationPresented

        showsTopToolbarItems = canShowChrome && mediaIsUnobstructed
        showsViewerBottomBar = canShowChrome && (isCompact || !isInformationPresented)
        reservesTransportControls = isPlayable && !isContextPreview
        showsTransportControls = reservesTransportControls
            && canShowChrome
            && mediaIsUnobstructed
            && isPlayerReady
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

    static let topChromeReservation: CGFloat = 72
    static let bottomChromeReservation: CGFloat = 68
    static let transportControlsReservation: CGFloat = 56

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

    func fittedMediaFrame(aspectRatio sourceAspectRatio: Double) -> CGRect {
        fittedMediaFrame(
            aspectRatio: sourceAspectRatio,
            in: CGRect(origin: .zero, size: viewport)
        )
    }

    func presentationMediaFrame(
        aspectRatio: Double,
        showsChrome: Bool,
        topSafeAreaInset: CGFloat,
        bottomSafeAreaInset: CGFloat,
        reservesTransportControls: Bool
    ) -> CGRect {
        guard showsChrome else { return fittedMediaFrame(aspectRatio: aspectRatio) }
        let minY = max(0, topSafeAreaInset) + Self.topChromeReservation
        let transportReservation = reservesTransportControls
            ? Self.transportControlsReservation
            : 0
        let maxY = viewport.height
            - max(0, bottomSafeAreaInset)
            - Self.bottomChromeReservation
            - transportReservation
        guard maxY > minY else { return fittedMediaFrame(aspectRatio: aspectRatio) }
        return fittedMediaFrame(
            aspectRatio: aspectRatio,
            in: CGRect(x: 0, y: minY, width: viewport.width, height: maxY - minY)
        )
    }

    private func fittedMediaFrame(
        aspectRatio sourceAspectRatio: Double,
        in bounds: CGRect
    ) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let finiteRatio = sourceAspectRatio.isFinite && sourceAspectRatio > 0
            ? CGFloat(sourceAspectRatio)
            : 1
        let aspectRatio = min(100, max(0.01, finiteRatio))
        let boundsRatio = bounds.width / bounds.height
        let size: CGSize
        if aspectRatio >= boundsRatio {
            size = CGSize(width: bounds.width, height: bounds.width / aspectRatio)
        } else {
            size = CGSize(width: bounds.height * aspectRatio, height: bounds.height)
        }
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
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
        aspectRatio sourceAspectRatio: Double = 1,
        showsChrome: Bool = false,
        topSafeAreaInset: CGFloat = 0,
        bottomSafeAreaInset: CGFloat = 0,
        reservesTransportControls: Bool = false
    ) -> (scale: CGFloat, offsetY: CGFloat) {
        let followedOffset = min(informationRevealOffset, max(0, scrollOffset))
        guard viewport.width > 0, viewport.height > 0 else {
            return (1, followedOffset / 2)
        }
        let fullFrame = fittedMediaFrame(aspectRatio: sourceAspectRatio)
        let restingFrame = presentationMediaFrame(
            aspectRatio: sourceAspectRatio,
            showsChrome: showsChrome,
            topSafeAreaInset: topSafeAreaInset,
            bottomSafeAreaInset: bottomSafeAreaInset,
            reservesTransportControls: reservesTransportControls
        )
        let restingScale = restingFrame.width / fullFrame.width
        let restingOffsetY = restingFrame.midY - viewport.height / 2

        let coverScale = max(
            1,
            viewport.width / fullFrame.width,
            informationVisibleMediaHeight / fullFrame.height
        )
        let progress = informationProgress(scrollOffset: followedOffset)
        let scale = restingScale + (coverScale - restingScale) * progress
        let offsetY = restingOffsetY * (1 - progress) + followedOffset / 2
        return (scale, offsetY)
    }

    /// Derives every consumer-facing value from the same normalized sample.
    /// The exact endpoints are deliberately tolerant of sub-pixel settling,
    /// while intermediate frames remain purely visual and never change layout.
    func presentation(
        scrollOffset: CGFloat,
        aspectRatio: Double = 1,
        showsChrome: Bool = false,
        topSafeAreaInset: CGFloat = 0,
        bottomSafeAreaInset: CGFloat = 0,
        reservesTransportControls: Bool = false
    ) -> AssetViewerScrollPresentation {
        let offset = scrollOffset.isFinite ? max(0, scrollOffset) : 0
        let transform = mediaTransform(
            scrollOffset: offset,
            aspectRatio: aspectRatio,
            showsChrome: showsChrome,
            topSafeAreaInset: topSafeAreaInset,
            bottomSafeAreaInset: bottomSafeAreaInset,
            reservesTransportControls: reservesTransportControls
        )
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

        // a gesture from deeper metadata is ordinary reading and stays
        // native. scrolling back into the transition pauses at the
        // information stop - a subsequent swipe performs the close - so one
        // high-velocity gesture cannot throw the media past its useful stop.
        if start > reveal + endpointTolerance {
            return proposed < reveal ? reveal : proposed
        }

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
