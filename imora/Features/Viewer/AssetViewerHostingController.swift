import Observation
import Photos
import SwiftUI
import UIKit

private func assetViewerDismissalDistance(for height: CGFloat) -> CGFloat {
    max(180, height * 0.38)
}

private var assetViewerPresentationDuration: TimeInterval {
    UIAccessibility.isReduceMotionEnabled ? 0.1 : 0.32
}

private var assetViewerDismissalDuration: TimeInterval {
    UIAccessibility.isReduceMotionEnabled ? 0.09 : 0.3
}

private var assetViewerChromeTransitionDuration: TimeInterval {
    UIAccessibility.isReduceMotionEnabled ? 0.12 : 0.22
}

@MainActor
private func makeAssetViewerZoomView(
    image: UIImage,
    frame: CGRect,
    cornerRadius: CGFloat
) -> UIImageView {
    let imageView = UIImageView(image: image)
    imageView.frame = frame
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.layer.cornerCurve = .continuous
    imageView.layer.cornerRadius = cornerRadius
    return imageView
}

@MainActor
private final class AssetViewerZoomSource {
    weak var view: UIView?
    let image: UIImage
    let frame: CGRect
    private let originalAlpha: CGFloat

    init(view: UIView, image: UIImage, frame: CGRect) {
        self.view = view
        self.image = image
        self.frame = frame
        originalAlpha = view.alpha
    }

    func hide() {
        view?.alpha = 0
    }

    func restore() {
        guard let view, view.alpha == 0 else { return }
        view.alpha = originalAlpha
    }

    func makeZoomView(frame: CGRect? = nil, cornerRadius: CGFloat? = nil) -> UIImageView {
        makeAssetViewerZoomView(
            image: image,
            frame: frame ?? self.frame,
            cornerRadius: cornerRadius ?? view?.layer.cornerRadius ?? 0
        )
    }
}

@MainActor
private final class AssetViewerMediaFrameSourceRegistry {
    private final class Entry {
        weak var view: UIView?
        var aspectRatio: Double

        init(view: UIView, aspectRatio: Double) {
            self.view = view
            self.aspectRatio = aspectRatio
        }
    }

    private var entries: [String: Entry] = [:]

    func update(
        assetID: String,
        view: UIView,
        aspectRatio: Double,
        isAttached: Bool
    ) {
        if isAttached {
            if let entry = entries[assetID], entry.view === view {
                entry.aspectRatio = aspectRatio
            } else {
                entries[assetID] = Entry(view: view, aspectRatio: aspectRatio)
            }
        } else if entries[assetID]?.view === view {
            entries[assetID] = nil
        }
    }

    func source(for assetID: String) -> (view: UIView, aspectRatio: Double)? {
        guard let entry = entries[assetID], let view = entry.view, view.window != nil else {
            entries[assetID] = nil
            return nil
        }
        return (view, entry.aspectRatio)
    }
}

@MainActor
private final class AssetViewerChromeSnapshot {
    let view: UIView

    private let shieldView: UIView
    private let originals: [(view: UIView, alpha: CGFloat)]

    private static func glassFrames(
        in root: UIView,
        coordinateSpace: UIView
    ) -> [CGRect] {
        var frames: [CGRect] = []

        func visit(_ layer: CALayer) {
            guard !layer.isHidden, layer.opacity > 0.001 else { return }
            let height = layer.bounds.height
            let radius = layer.cornerRadius
            if height >= 32,
               radius > 0,
               abs(radius - height / 2) <= max(1, height * 0.08) {
                let frame = layer.convert(layer.bounds, to: coordinateSpace.layer)
                let isDuplicate = frames.contains { existing in
                    abs(existing.minX - frame.minX) < 1
                        && abs(existing.minY - frame.minY) < 1
                        && abs(existing.width - frame.width) < 1
                        && abs(existing.height - frame.height) < 1
                }
                if !isDuplicate { frames.append(frame) }
            }
            for sublayer in layer.sublayers ?? [] { visit(sublayer) }
        }

        visit(root.layer)
        return frames
    }

    private static func addGlassShields(
        for chromeView: UIView,
        to shieldView: UIView,
        in coordinateSpace: UIView
    ) {
        for frame in glassFrames(in: chromeView, coordinateSpace: coordinateSpace) {
            guard !frame.isEmpty, frame.intersects(coordinateSpace.bounds) else { continue }
            let shield = UIView(frame: frame)
            shield.backgroundColor = .black
            shield.isUserInteractionEnabled = false
            shield.layer.cornerCurve = .continuous
            shield.layer.cornerRadius = min(frame.width, frame.height) / 2
            shieldView.addSubview(shield)
        }
    }

    init?(chromeViews: [UIView], in coordinateSpace: UIView) {
        let container = UIView(frame: coordinateSpace.bounds)
        container.backgroundColor = .clear
        container.isUserInteractionEnabled = false
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let shieldView = UIView(frame: coordinateSpace.bounds)
        shieldView.backgroundColor = .clear
        shieldView.isUserInteractionEnabled = false
        shieldView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        var originals: [(view: UIView, alpha: CGFloat)] = []
        for chromeView in chromeViews {
            guard let snapshot = chromeView.snapshotView(afterScreenUpdates: false) else { continue }
            Self.addGlassShields(
                for: chromeView,
                to: shieldView,
                in: coordinateSpace
            )
            snapshot.frame = chromeView.convert(chromeView.bounds, to: coordinateSpace)
            snapshot.alpha = chromeView.alpha
            snapshot.isUserInteractionEnabled = false
            container.addSubview(snapshot)
            originals.append((chromeView, chromeView.alpha))
        }
        guard !originals.isEmpty else { return nil }

        self.view = container
        self.shieldView = shieldView
        self.originals = originals
        for original in originals {
            original.view.layer.removeAllAnimations()
            original.view.alpha = 0
        }
    }

    func install(in host: UIView) {
        shieldView.removeFromSuperview()
        view.removeFromSuperview()
        shieldView.frame = host.bounds
        view.frame = host.bounds
        host.addSubview(shieldView)
        host.addSubview(view)
    }

    func setAlpha(_ alpha: CGFloat) {
        let alpha = min(1, max(0, alpha))
        view.alpha = alpha
        shieldView.alpha = min(1, alpha / 0.7)
    }

    func restore() {
        for original in originals {
            original.view.alpha = original.alpha
        }
        shieldView.removeFromSuperview()
        view.removeFromSuperview()
    }
}

@MainActor
private final class AssetViewerSwipeDismissal {
    let source: AssetViewerZoomSource?
    let zoomView: UIImageView?
    let mediaFrame: CGRect?
    let chromeSnapshot: AssetViewerChromeSnapshot?
    let openingChromeOverlay: AssetViewerOpeningChromeOverlay?

    init(
        source: AssetViewerZoomSource? = nil,
        zoomView: UIImageView? = nil,
        mediaFrame: CGRect? = nil,
        chromeSnapshot: AssetViewerChromeSnapshot? = nil,
        openingChromeOverlay: AssetViewerOpeningChromeOverlay? = nil
    ) {
        self.source = source
        self.zoomView = zoomView
        self.mediaFrame = mediaFrame
        self.chromeSnapshot = chromeSnapshot
        self.openingChromeOverlay = openingChromeOverlay
    }
}

@MainActor
private final class AssetViewerPresentationController: UIPresentationController {
    override var shouldRemovePresentersView: Bool { false }

    override var frameOfPresentedViewInContainerView: CGRect {
        containerView?.bounds ?? .zero
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        presentedView?.frame = frameOfPresentedViewInContainerView
    }
}

@MainActor
private final class AssetViewerDetachedDismissal {
    let id = UUID()

    private let overlayView: UIView
    private let backdropView: UIView
    private let chromeSnapshot: AssetViewerChromeSnapshot?
    private let openingChromeOverlay: AssetViewerOpeningChromeOverlay?
    private let zoomView: UIImageView?
    private let targetFrame: CGRect?
    private let source: AssetViewerZoomSource?
    private var animator: UIViewPropertyAnimator?

    init(
        window: UIWindow,
        backdropAlpha: CGFloat,
        chromeSnapshot: AssetViewerChromeSnapshot?,
        openingChromeOverlay: AssetViewerOpeningChromeOverlay?,
        contentAlpha: CGFloat,
        zoomView: UIImageView?,
        zoomFrame: CGRect?,
        targetFrame: CGRect?,
        source: AssetViewerZoomSource?
    ) {
        let overlayView = UIView(frame: window.bounds)
        overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayView.backgroundColor = .clear
        overlayView.isUserInteractionEnabled = false

        let backdropView = UIView(frame: overlayView.bounds)
        backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdropView.backgroundColor = .black
        backdropView.alpha = backdropAlpha
        backdropView.isUserInteractionEnabled = false
        overlayView.addSubview(backdropView)

        if let zoomView, let zoomFrame {
            zoomView.removeFromSuperview()
            zoomView.frame = zoomFrame
            zoomView.layer.cornerRadius = 0
            zoomView.isUserInteractionEnabled = false
            overlayView.addSubview(zoomView)
        }

        self.overlayView = overlayView
        self.backdropView = backdropView
        self.chromeSnapshot = chromeSnapshot
        self.openingChromeOverlay = openingChromeOverlay
        self.zoomView = zoomView
        self.targetFrame = targetFrame
        self.source = source
        window.addSubview(overlayView)
        chromeSnapshot?.install(in: window)
        chromeSnapshot?.setAlpha(contentAlpha)
        if let openingChromeOverlay {
            let frame = openingChromeOverlay.superview.map {
                window.convert(openingChromeOverlay.frame, from: $0)
            } ?? openingChromeOverlay.frame
            openingChromeOverlay.removeFromSuperview()
            openingChromeOverlay.frame = frame
            openingChromeOverlay.alpha = contentAlpha
            openingChromeOverlay.isUserInteractionEnabled = false
            window.addSubview(openingChromeOverlay)
        }
    }

    func start(completion: @escaping (UUID) -> Void) {
        let animator = UIViewPropertyAnimator(
            duration: assetViewerDismissalDuration,
            dampingRatio: 1
        )
        animator.addAnimations { [weak self] in
            guard let self else { return }
            self.backdropView.alpha = 0
            self.chromeSnapshot?.setAlpha(0)
            self.openingChromeOverlay?.alpha = 0
            if let targetFrame = self.targetFrame {
                self.zoomView?.frame = targetFrame
                self.zoomView?.layer.cornerRadius = 0
            } else if let zoomView = self.zoomView {
                zoomView.alpha = 0
                zoomView.transform = CGAffineTransform(translationX: 0, y: 120)
                    .scaledBy(x: 0.94, y: 0.94)
            }
        }
        animator.addCompletion { [weak self] _ in
            guard let self else { return }
            self.source?.restore()
            self.chromeSnapshot?.restore()
            self.openingChromeOverlay?.removeFromSuperview()
            self.overlayView.removeFromSuperview()
            self.animator = nil
            completion(self.id)
        }
        self.animator = animator
        animator.startAnimation()
    }

    func completeImmediately() {
        guard let animator else {
            source?.restore()
            chromeSnapshot?.restore()
            openingChromeOverlay?.removeFromSuperview()
            overlayView.removeFromSuperview()
            return
        }
        animator.stopAnimation(false)
        animator.finishAnimation(at: .end)
    }
}

@MainActor
private enum AssetViewerDetachedDismissalStore {
    private static var active: [UUID: AssetViewerDetachedDismissal] = [:]

    static func run(_ transition: AssetViewerDetachedDismissal) {
        active[transition.id] = transition
        transition.start { id in
            active[id] = nil
        }
    }

    static func completeAll() {
        let transitions = Array(active.values)
        active.removeAll()
        for transition in transitions {
            transition.completeImmediately()
        }
    }
}

@MainActor
private final class AssetViewerTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    enum Operation {
        case presentation
        case dismissal
    }

    private let operation: Operation
    weak var controller: AssetViewerHostingController?
    private var animator: UIViewPropertyAnimator?
    private weak var activePresentationZoomView: UIImageView?
    var onCompletion: ((Bool) -> Void)?

    init(operation: Operation) {
        self.operation = operation
    }

    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        switch operation {
        case .presentation: assetViewerPresentationDuration
        case .dismissal: assetViewerDismissalDuration
        }
    }

    func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
        interruptibleAnimator(using: transitionContext).startAnimation()
    }

    func interruptibleAnimator(
        using transitionContext: any UIViewControllerContextTransitioning
    ) -> any UIViewImplicitlyAnimating {
        if let animator { return animator }

        let duration = transitionDuration(using: transitionContext)
        let animator: UIViewPropertyAnimator
        let zoomSource: AssetViewerZoomSource?
        let zoomView: UIImageView?
        let openingChromeOverlay: AssetViewerOpeningChromeOverlay?
        switch operation {
        case .presentation:
            guard let prepared = preparePresentation(
                using: transitionContext,
                duration: duration
            ) else { return completedAnimator(for: transitionContext) }
            animator = prepared.animator
            zoomSource = prepared.source
            zoomView = prepared.view
            openingChromeOverlay = prepared.openingChrome
        case .dismissal:
            guard let prepared = prepareDismissal(
                using: transitionContext,
                duration: duration
            ) else { return completedAnimator(for: transitionContext) }
            animator = prepared.animator
            zoomSource = prepared.source
            zoomView = prepared.view
            openingChromeOverlay = nil
        }

        animator.addCompletion { [weak self] _ in
            let completed = !transitionContext.transitionWasCancelled
            if !completed, let fromView = transitionContext.view(forKey: .from) {
                fromView.alpha = 1
                fromView.transform = .identity
            }
            switch self?.operation {
            case .presentation where completed:
                self?.controller?.setTransitionMediaVisible(true)
            case .dismissal where !completed:
                self?.controller?.setTransitionMediaVisible(true)
            default:
                break
            }
            if self?.operation == .presentation, let zoomView {
                if completed {
                    self?.controller?.holdPresentationZoomView(zoomView)
                } else {
                    self?.controller?.discardTrackedPresentationZoomView(zoomView)
                    zoomView.removeFromSuperview()
                }
            } else {
                zoomView?.removeFromSuperview()
            }
            if self?.operation == .presentation, let openingChrome = openingChromeOverlay {
                if completed {
                    self?.controller?.holdOpeningChromeOverlay(openingChrome)
                } else {
                    openingChrome.removeFromSuperview()
                }
            }
            zoomSource?.restore()
            transitionContext.completeTransition(completed)
            self?.onCompletion?(completed)
            self?.activePresentationZoomView = nil
            self?.animator = nil
        }
        self.animator = animator
        return animator
    }

    private typealias PreparedTransition = (
        animator: UIViewPropertyAnimator,
        source: AssetViewerZoomSource?,
        view: UIImageView?,
        openingChrome: AssetViewerOpeningChromeOverlay?
    )

    private func preparePresentation(
        using transitionContext: any UIViewControllerContextTransitioning,
        duration: TimeInterval
    ) -> PreparedTransition? {
        guard let toController = transitionContext.viewController(forKey: .to),
              let toView = transitionContext.view(forKey: .to)
        else { return nil }
        let container = transitionContext.containerView
        toView.frame = transitionContext.finalFrame(for: toController)
        container.addSubview(toView)
        toView.layoutIfNeeded()
        controller?.installDismissalGesture(on: container)
        controller?.prepareViewerContentForPresentation()
        // views below this threshold stop receiving touches. keeping a nearly
        // invisible destination live lets back and swipe reverse immediately.
        toView.alpha = AssetViewerOpeningChromeReveal.initialBackdropOpacity
        let openingChrome = controller?.makeOpeningChromeOverlay(in: container)

        guard !UIAccessibility.isReduceMotionEnabled,
              let source = controller?.transitionZoomSource(in: container),
              let targetFrame = controller?.transitionMediaFrame(in: container)
        else {
            controller?.setTransitionMediaVisible(true)
            if let openingChrome {
                container.addSubview(openingChrome)
            }
            let animator = UIViewPropertyAnimator(duration: duration, curve: .easeOut) {
                toView.alpha = 1
                openingChrome?.reveal()
            }
            return (animator, nil, nil, openingChrome)
        }

        source.hide()
        let zoomView = source.makeZoomView()
        container.addSubview(zoomView)
        activePresentationZoomView = zoomView
        controller?.trackPresentationZoomView(zoomView)
        if let openingChrome {
            container.addSubview(openingChrome)
        }
        let animator = UIViewPropertyAnimator(duration: duration, dampingRatio: 1) {
            toView.alpha = 1
            zoomView.frame = targetFrame
            zoomView.layer.cornerRadius = 0
            openingChrome?.reveal()
        }
        animator.isInterruptible = true
        animator.isUserInteractionEnabled = true
        return (animator, source, zoomView, openingChrome)
    }

    private func prepareDismissal(
        using transitionContext: any UIViewControllerContextTransitioning,
        duration: TimeInterval
    ) -> PreparedTransition? {
        guard let fromView = transitionContext.view(forKey: .from) else { return nil }
        let container = transitionContext.containerView
        if let toController = transitionContext.viewController(forKey: .to),
           let toView = transitionContext.view(forKey: .to) {
            toView.frame = transitionContext.finalFrame(for: toController)
            container.insertSubview(toView, belowSubview: fromView)
        }
        if let swipe = controller?.takeSwipeDismissal() {
            guard let zoomView = swipe.zoomView else {
                return fallbackDismissal(
                    from: fromView,
                    duration: duration
                )
            }
            guard let source = swipe.source else {
                let animator = UIViewPropertyAnimator(duration: duration, curve: .easeOut) {
                    fromView.alpha = 0
                    zoomView.alpha = 0
                    zoomView.transform = CGAffineTransform(
                        translationX: 0,
                        y: assetViewerDismissalDistance(for: container.bounds.height) * 0.45
                    )
                    .scaledBy(x: 0.94, y: 0.94)
                }
                return (animator, nil, zoomView, nil)
            }
            let animator = UIViewPropertyAnimator(duration: duration, dampingRatio: 1) {
                fromView.alpha = 0
                zoomView.frame = source.frame
                zoomView.layer.cornerRadius = 0
            }
            return (animator, source, zoomView, nil)
        }

        guard !UIAccessibility.isReduceMotionEnabled,
              let mediaFrame = controller?.transitionMediaFrame(in: container)
        else {
            return fallbackDismissal(
                from: fromView,
                duration: duration
            )
        }

        if let source = controller?.transitionZoomSource(in: container) {
            controller?.setTransitionMediaVisible(false)
            source.hide()
            let zoomView = source.makeZoomView(frame: mediaFrame, cornerRadius: 0)
            container.addSubview(zoomView)
            let animator = UIViewPropertyAnimator(duration: duration, dampingRatio: 1) {
                fromView.alpha = 0
                zoomView.frame = source.frame
                zoomView.layer.cornerRadius = 0
            }
            return (animator, source, zoomView, nil)
        }

        guard let zoomView = controller?.makeDetachedTransitionZoomView(frame: mediaFrame) else {
            return fallbackDismissal(from: fromView, duration: duration)
        }
        controller?.setTransitionMediaVisible(false)
        container.addSubview(zoomView)
        let animator = UIViewPropertyAnimator(duration: duration, curve: .easeOut) {
            fromView.alpha = 0
            zoomView.alpha = 0
            zoomView.transform = CGAffineTransform(
                translationX: 0,
                y: assetViewerDismissalDistance(for: container.bounds.height) * 0.32
            )
            .scaledBy(x: 0.94, y: 0.94)
        }
        return (animator, nil, zoomView, nil)
    }

    private func fallbackDismissal(
        from fromView: UIView,
        duration: TimeInterval
    ) -> PreparedTransition {
        controller?.setTransitionMediaVisible(true)
        let animator = UIViewPropertyAnimator(duration: duration, curve: .easeOut) {
            fromView.alpha = 0
        }
        return (animator, nil, nil, nil)
    }

    func animationEnded(_ transitionCompleted: Bool) {
        animator = nil
    }

    func pauseForInteraction() -> CGFloat? {
        guard case .presentation = operation,
              let animator,
              animator.state == .active
        else { return nil }
        if animator.isRunning { animator.pauseAnimation() }
        return min(1, max(0, animator.fractionComplete))
    }

    func updatePresentationFraction(_ fraction: CGFloat) {
        guard case .presentation = operation,
              let animator,
              animator.state == .active,
              !animator.isRunning
        else { return }
        animator.fractionComplete = min(1, max(0, fraction))
    }

    func retargetPresentationZoom(to frame: CGRect) -> Bool {
        guard operation == .presentation,
              let animator,
              animator.state == .active,
              let zoomView = activePresentationZoomView,
              zoomView.superview != nil
        else { return false }
        animator.addAnimations {
            zoomView.frame = frame
            zoomView.layer.cornerRadius = 0
        }
        return true
    }

    func completeImmediately() {
        guard let animator else { return }
        animator.stopAnimation(false)
        animator.finishAnimation(at: animator.isReversed ? .start : .end)
    }

    private func completedAnimator(
        for transitionContext: any UIViewControllerContextTransitioning
    ) -> UIViewPropertyAnimator {
        let animator = UIViewPropertyAnimator(duration: 0, curve: .linear)
        animator.addCompletion { [weak self] _ in
            if self?.operation == .presentation {
                self?.controller?.setTransitionMediaVisible(true)
            }
            transitionContext.completeTransition(true)
            self?.animator = nil
        }
        self.animator = animator
        return animator
    }
}

@MainActor
private final class AssetViewerTransitionDriver: NSObject,
    UIViewControllerTransitioningDelegate,
    UIGestureRecognizerDelegate
{
    weak var controller: AssetViewerHostingController? {
        didSet {
            presentationAnimator.controller = controller
            dismissalAnimator.controller = controller
        }
    }

    private let presentationAnimator: AssetViewerTransitionAnimator
    private let dismissalAnimator: AssetViewerTransitionAnimator
    private let presentationInteraction: UIPercentDrivenInteractiveTransition
    private var openingSwipeInteraction: AssetViewerOpeningSwipeInteraction?
    private var trackedSwipe: TrackedSwipe?
    private weak var dismissalPan: UIPanGestureRecognizer?

    private enum TrackedSwipe {
        case presentation
        case dismissal
    }

    override init() {
        presentationAnimator = AssetViewerTransitionAnimator(operation: .presentation)
        dismissalAnimator = AssetViewerTransitionAnimator(operation: .dismissal)
        presentationInteraction = UIPercentDrivenInteractiveTransition()
        super.init()
        presentationInteraction.wantsInteractiveStart = false
        presentationInteraction.completionCurve = .easeOut
        presentationInteraction.completionSpeed = 1
        presentationAnimator.onCompletion = { [weak self] completed in
            self?.openingSwipeInteraction = nil
            self?.trackedSwipe = nil
            guard !completed else { return }
            self?.controller?.presentationWasCancelled()
        }
    }

    func cancelPresentation() -> Bool {
        presentationInteraction.pause()
        guard presentationAnimator.pauseForInteraction() != nil else { return false }
        openingSwipeInteraction = nil
        presentationInteraction.cancel()
        return true
    }

    private func beginPresentationSwipe() -> Bool {
        presentationInteraction.pause()
        guard let fraction = presentationAnimator.pauseForInteraction() else { return false }
        let interaction = AssetViewerOpeningSwipeInteraction(startingFraction: fraction)
        openingSwipeInteraction = interaction
        presentationInteraction.update(fraction)
        return true
    }

    private func updatePresentationSwipe(progress: CGFloat) {
        guard let openingSwipeInteraction else { return }
        let fraction = openingSwipeInteraction.openingFraction(
            forDismissalProgress: progress
        )
        presentationInteraction.update(fraction)
        presentationAnimator.updatePresentationFraction(fraction)
    }

    private func endPresentationSwipe(closes: Bool) {
        guard openingSwipeInteraction != nil else { return }
        openingSwipeInteraction = nil
        if closes {
            presentationInteraction.cancel()
        } else {
            presentationInteraction.finish()
        }
    }

    func retargetPresentationZoom(to frame: CGRect) -> Bool {
        presentationAnimator.retargetPresentationZoom(to: frame)
    }

    func completeClosingTransitionImmediately() {
        presentationAnimator.completeImmediately()
        dismissalAnimator.completeImmediately()
    }

    func installGesture(on view: UIView) {
        if let dismissalPan {
            view.addGestureRecognizer(dismissalPan)
            return
        }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(didPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delegate = self
        view.addGestureRecognizer(pan)
        dismissalPan = pan
    }

    func prioritizeDismissalGesture(in root: UIView) {
        guard let dismissalPan else { return }
        for scrollView in scrollViews(in: root) {
            scrollView.panGestureRecognizer.require(toFail: dismissalPan)
        }
    }

    func presentationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source: UIViewController
    ) -> UIPresentationController? {
        AssetViewerPresentationController(
            presentedViewController: presented,
            presenting: presenting
        )
    }

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        presentationAnimator
    }

    func animationController(
        forDismissed dismissed: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        dismissalAnimator
    }

    func interactionControllerForPresentation(
        using animator: any UIViewControllerAnimatedTransitioning
    ) -> (any UIViewControllerInteractiveTransitioning)? {
        guard animator as AnyObject === presentationAnimator else { return nil }
        return presentationInteraction
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissalPan,
              let pan = gestureRecognizer as? UIPanGestureRecognizer,
              let controller
        else { return false }
        let velocity = pan.velocity(in: controller.view)
        let location = pan.location(in: controller.view)
        return controller.canBeginDownwardDismissal(velocity: velocity, location: location)
    }

    @objc private func didPan(_ pan: UIPanGestureRecognizer) {
        guard let controller else { return }
        let translation = pan.translation(in: controller.view)
        let distance = assetViewerDismissalDistance(for: controller.view.bounds.height)
        let progress = min(1, max(0, translation.y / distance))

        switch pan.state {
        case .began:
            controller.cancelPendingViewerZoomCommand()
            if controller.isPresenting {
                guard beginPresentationSwipe() else {
                    controller.requestDismissal()
                    return
                }
                trackedSwipe = .presentation
                return
            }
            guard controller.isReadyForSwipeDismissal else {
                controller.requestDismissal()
                return
            }
            if controller.beginSwipeDismissal() { trackedSwipe = .dismissal }
        case .changed:
            switch trackedSwipe {
            case .presentation:
                updatePresentationSwipe(progress: progress)
            case .dismissal:
                controller.updateSwipeDismissal(translation: translation, progress: progress)
            case nil:
                break
            }
        case .ended:
            guard let trackedSwipe else { return }
            self.trackedSwipe = nil
            let velocity = pan.velocity(in: controller.view)
            let projectedProgress = max(
                progress,
                (translation.y + max(0, velocity.y) * 0.12) / distance
            )
            let closes = AssetViewerOpeningSwipeInteraction.shouldClose(
                progress: progress,
                projectedProgress: projectedProgress
            )
            switch trackedSwipe {
            case .presentation:
                if closes { controller.commitOpeningSwipeDismissal() }
                endPresentationSwipe(closes: closes)
            case .dismissal:
                if closes {
                    controller.finishSwipeDismissal()
                } else {
                    controller.cancelSwipeDismissal()
                }
            }
        case .cancelled, .failed:
            guard let trackedSwipe else { return }
            self.trackedSwipe = nil
            switch trackedSwipe {
            case .presentation:
                endPresentationSwipe(closes: false)
            case .dismissal:
                controller.cancelSwipeDismissal()
            }
        default:
            break
        }
    }

    private func scrollViews(in root: UIView) -> [UIScrollView] {
        root.subviews.flatMap { subview in
            let nested = scrollViews(in: subview)
            guard let scrollView = subview as? UIScrollView else { return nested }
            return [scrollView] + nested
        }
    }
}

/// weak lookup for live timeline tiles. closing viewers temporarily suppress
/// their source tile while every other tile remains ready for the next open.
@MainActor
final class AssetTileRegistry {
    private final class WeakTile {
        weak var view: UIView?
        weak var session: SessionStore?
        var asset: Asset

        init(_ view: UIView, asset: Asset, session: SessionStore) {
            self.view = view
            self.asset = asset
            self.session = session
        }
    }

    private var tiles: [String: WeakTile] = [:]
    private var suppressedInteractionIDs: Set<String> = []
    private var transitionImageTasks: [String: Task<Void, Never>] = [:]

    func register(_ view: UIView, asset: Asset, session: SessionStore) {
        tiles[asset.id] = WeakTile(view, asset: asset, session: session)
        view.isUserInteractionEnabled = !suppressedInteractionIDs.contains(asset.id)
        primeTransitionImage(for: asset, session: session)
    }

    func unregister(_ view: UIView, for assetID: String) {
        guard tiles[assetID]?.view === view else { return }
        tiles.removeValue(forKey: assetID)
    }

    func suppressInteraction(for assetID: String) {
        suppressedInteractionIDs.insert(assetID)
        tiles[assetID]?.view?.isUserInteractionEnabled = false
    }

    func restoreInteraction(for assetID: String) {
        suppressedInteractionIDs.remove(assetID)
        tiles[assetID]?.view?.isUserInteractionEnabled = true
    }

    fileprivate func zoomSource(for assetID: String, in container: UIView) -> AssetViewerZoomSource? {
        guard let tile = tiles[assetID],
              let view = tile.view,
              let session = tile.session,
              view.window != nil,
              !view.isHidden,
              view.alpha > 0.01
        else {
            tiles.removeValue(forKey: assetID)
            return nil
        }
        let frame = view.convert(view.bounds, to: container)
        guard frame.intersects(container.bounds) else { return nil }
        guard let image = cachedImage(for: tile.asset, session: session)
            ?? renderedImage(of: view)
        else { return nil }
        return AssetViewerZoomSource(view: view, image: image, frame: frame)
    }

    private func cachedImage(for asset: Asset, session: SessionStore) -> UIImage? {
        let pairedLocalID = asset.localIdentifier
            ?? session.backup?.localIdentifierByRemoteId[asset.id]
        if let pairedLocalID {
            if let image = LocalImageLoader.shared.cachedImage(
                localIdentifier: pairedLocalID,
                targetPixelSize: 640,
                contentMode: .aspectFit
            ) {
                return image
            }
            if let image = LocalImageLoader.shared.cachedImage(
                localIdentifier: pairedLocalID,
                targetPixelSize: 640,
                contentMode: .aspectFill
            ) {
                return image
            }
        }
        guard let client = session.client else { return nil }
        let url = client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash)
        return ImageLoader.shared.cachedImage(for: url, targetPixelSize: 640)
    }

    private func primeTransitionImage(for asset: Asset, session: SessionStore) {
        guard let pairedLocalID = asset.localIdentifier
                ?? session.backup?.localIdentifierByRemoteId[asset.id],
              LocalImageLoader.shared.cachedImage(
                  localIdentifier: pairedLocalID,
                  targetPixelSize: 640,
                  contentMode: .aspectFit
              ) == nil,
              transitionImageTasks[pairedLocalID] == nil
        else { return }
        transitionImageTasks[pairedLocalID] = Task { @MainActor [weak self] in
            _ = await LocalImageLoader.shared.image(
                localIdentifier: pairedLocalID,
                targetPixelSize: 640,
                contentMode: .aspectFit
            )
            self?.transitionImageTasks[pairedLocalID] = nil
        }
    }

    private func renderedImage(of view: UIView) -> UIImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(1, view.traitCollection.displayScale)
        format.opaque = view.isOpaque
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            if !view.drawHierarchy(in: view.bounds, afterScreenUpdates: false) {
                view.layer.render(in: context.cgContext)
            }
        }
    }
}

@MainActor
@Observable
final class AssetViewerDisplayState {
    enum Mode {
        case contextPreview
        case viewer
    }

    var mode: Mode
    var currentAssetID: String
    var currentPageZoomed = false
    var viewerContentReady = false
    var viewerChromeRevealed = false
    var transitionMediaVisible = false
    var chromeVisible = true
    var mediaSafeAreaInsets: UIEdgeInsets?
    var openingMediaImage: UIImage?
    let zoomCommandBridge = AssetViewerZoomCommandBridge()
    /// whether the media is unobstructed. while information is open, pans
    /// belong to its sheet rather than the viewer dismissal.
    var mediaAtTop = true

    init(mode: Mode, currentAssetID: String) {
        self.mode = mode
        self.currentAssetID = currentAssetID
    }
}

@MainActor
private final class AssetViewerDismissalRelay {
    weak var controller: AssetViewerHostingController?

    func request() {
        controller?.requestDismissal()
    }

    func presentationMediaReady() {
        controller?.presentationMediaBecameReady()
    }

    func pageZoomChanged(_ isZoomed: Bool) {
        controller?.viewerPageZoomChanged(isZoomed)
    }

    func interactiveMediaInteractionStarted() {
        controller?.viewerInteractiveMediaInteractionStarted()
    }

    func chromeVisibilityChanged(_ visible: Bool) {
        controller?.viewerChromeVisibilityChanged(visible)
    }

    func mediaFrameSourceChanged(
        assetID: String,
        view: UIView,
        aspectRatio: Double,
        isAttached: Bool
    ) {
        controller?.viewerMediaFrameSourceChanged(
            assetID: assetID,
            view: view,
            aspectRatio: aspectRatio,
            isAttached: isAttached
        )
    }
}

/// full-screen viewer and disposable context-menu preview host.
@MainActor
final class AssetViewerHostingController: UIHostingController<AnyView>, UIAdaptivePresentationControllerDelegate {
    private enum Phase {
        case idle
        case presenting
        case presented
        case dismissing
        case finished
    }

    let route: ViewerRoute
    let displayState: AssetViewerDisplayState

    private let willPresent: (ViewerRoute) -> Bool
    private let didPresent: (UUID) -> Void
    private let didDismiss: (UUID) -> Void
    private let dismissalRelay: AssetViewerDismissalRelay
    private let transitionDriver: AssetViewerTransitionDriver
    private let mediaFrameSources = AssetViewerMediaFrameSourceRegistry()
    private let session: SessionStore
    private let openingChromePresentation: AssetViewerOpeningChromePresentation?
    private weak var sourceRegistry: AssetTileRegistry?
    private var preparedViewerRoot: AnyView?
    private var isViewerRootInstalled = false
    private var phase = Phase.idle
    private var isTrackingDismissalTransition = false
    private var dismissalRequested = false
    private var viewerRootInstallationTask: Task<Void, Never>?
    private var viewerContentActivationTask: Task<Void, Never>?
    private var contextCommitPresentationTask: Task<Void, Never>?
    private var presentationAfterDismissal: (() -> Void)?
    private var swipeDismissal: AssetViewerSwipeDismissal?
    private var swipeCancellationAnimator: UIViewPropertyAnimator?
    private var activePresentationZoomView: UIImageView?
    private var presentationZoomView: UIImageView?
    private var presentationZoomReleaseTask: Task<Void, Never>?
    private var presentationZoomFallbackDeadline: CFTimeInterval = 0
    private var presentationMediaReady = false
    private var chromeTransitionDeadline: CFTimeInterval = 0
    private var openingChromeOverlay: AssetViewerOpeningChromeOverlay?
    private var openingChromeHandoffGeneration = 0

    init(
        route: ViewerRoute,
        startsAsContextPreview: Bool,
        previewBounds: CGSize,
        session: SessionStore,
        sourceRegistry: AssetTileRegistry,
        openingChromePresentation: AssetViewerOpeningChromePresentation? = nil,
        album: AlbumContext?,
        personID: String?,
        willPresent: @escaping (ViewerRoute) -> Bool,
        didPresent: @escaping (UUID) -> Void,
        didDismiss: @escaping (UUID) -> Void,
        onChange: @escaping (AssetChange) -> Void
    ) {
        let state = AssetViewerDisplayState(
            mode: startsAsContextPreview ? .contextPreview : .viewer,
            currentAssetID: route.sourceAssetID
        )
        let relay = AssetViewerDismissalRelay()
        let transitionDriver = AssetViewerTransitionDriver()

        self.route = route
        self.displayState = state
        self.willPresent = willPresent
        self.didPresent = didPresent
        self.didDismiss = didDismiss
        self.dismissalRelay = relay
        self.transitionDriver = transitionDriver
        self.session = session
        self.openingChromePresentation = openingChromePresentation
        self.sourceRegistry = sourceRegistry

        let root = AssetViewerHostRoot(
            route: route,
            displayState: state,
            dismissalRelay: relay,
            album: album,
            personID: personID,
            onChange: onChange
        )
        .environment(session)
        preparedViewerRoot = AnyView(root)
        let initialRoot: AnyView
        if startsAsContextPreview,
           let asset = route.assets[safe: route.initialIndex] {
            initialRoot = AnyView(AssetContextPreview(asset: asset).environment(session))
        } else {
            initialRoot = AnyView(Color.clear.ignoresSafeArea())
        }
        super.init(rootView: initialRoot)

        relay.controller = self
        transitionDriver.controller = self
        // keep the source grid mounted so the next tap never waits for uikit
        // to restore the presenting hierarchy.
        modalPresentationStyle = .custom
        transitioningDelegate = transitionDriver

        if startsAsContextPreview,
           let asset = route.assets[safe: route.initialIndex] {
            let ratio = CGFloat(asset.ratio > 0 ? asset.ratio : 1)
            let height = min(previewBounds.height * 0.62, (previewBounds.width - 24) / ratio)
            preferredContentSize = CGSize(width: ratio * height, height: height)
            view.frame = CGRect(origin: .zero, size: preferredContentSize)
            view.layoutIfNeeded()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = displayState.mode == .viewer ? .black : .clear
        transitionDriver.installGesture(on: view)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        synchronizeMediaSafeAreaInsets()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        synchronizeMediaSafeAreaInsets()
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func presentDirectly(from presenter: UIViewController) {
        guard presenter.viewIfLoaded?.window != nil else { return }
        if queueBehindClosingViewer(on: presenter) { return }
        guard presenter.presentedViewController == nil else { return }
        guard beginPresentation() else { return }
        displayState.mode = .viewer
        phase = .presenting
        presenter.present(self, animated: true) { [weak self] in
            self?.presentationFinished()
        }
        verifyPresentationStarted(from: presenter)
    }

    func presentAfterContextCommit(from presenter: UIViewController) {
        guard displayState.mode == .viewer, beginPresentation() else { return }
        phase = .presenting
        if canPresent(from: presenter) {
            attachAfterContextCommit(to: presenter)
            return
        }
        contextCommitPresentationTask = Task { @MainActor [weak self, weak presenter] in
            for _ in 0..<60 {
                guard let self, let presenter, self.phase == .presenting else { return }
                if self.canPresent(from: presenter) {
                    self.contextCommitPresentationTask = nil
                    self.attachAfterContextCommit(to: presenter)
                    return
                }
                try? await Task.sleep(for: .milliseconds(8))
            }
            self?.contextCommitPresentationTask = nil
            self?.finish()
        }
    }

    func prepareViewerContentForContextCommit() {
        guard displayState.mode == .viewer else { return }
        scheduleViewerRootInstallation(after: .milliseconds(4))
    }

    func requestDismissal() {
        guard phase == .presenting || phase == .presented else { return }
        guard !dismissalRequested else { return }
        if phase == .presented { completeOpeningChromeHandoff() }
        dismissalRequested = true
        if phase == .presenting {
            viewerRootInstallationTask?.cancel()
            viewerRootInstallationTask = nil
        }
        suppressSourceInteraction()
        if phase == .presenting, transitionDriver.cancelPresentation() {
            passTouchesToTimeline()
            return
        }
        removePresentationZoomView()
        swipeCancellationAnimator?.stopAnimation(true)
        swipeCancellationAnimator = nil
        dismissWithoutBlockingTimeline()
    }

    fileprivate func transitionZoomSource(in container: UIView) -> AssetViewerZoomSource? {
        guard let source = sourceRegistry?.zoomSource(
            for: displayState.currentAssetID,
            in: container
        ) else { return nil }
        let image = cachedTransitionImage() ?? source.image
        if phase == .presenting,
           displayState.currentAssetID == route.sourceAssetID,
           displayState.openingMediaImage == nil {
            displayState.openingMediaImage = image
        }
        guard let sourceView = source.view else { return source }
        return AssetViewerZoomSource(view: sourceView, image: image, frame: source.frame)
    }

    fileprivate func transitionMediaFrame(in coordinateSpace: UIView) -> CGRect? {
        let source = mediaFrameSources.source(for: displayState.currentAssetID)
        if let source,
           let pageFrame = presentationFrame(of: source.view, in: coordinateSpace) {
            let mediaFrame = AssetViewerPageLayout(viewport: pageFrame.size)
                .fittedMediaFrame(aspectRatio: source.aspectRatio)
            return mediaFrame.offsetBy(dx: pageFrame.minX, dy: pageFrame.minY)
        }

        return layoutTransitionMediaFrame(
            in: coordinateSpace,
            aspectRatio: source?.aspectRatio
        )
    }

    private func layoutTransitionMediaFrame(
        in coordinateSpace: UIView,
        aspectRatio: Double? = nil
    ) -> CGRect? {
        guard let asset = transitionAsset else { return nil }
        let bounds = coordinateSpace.bounds
        let safeAreaInsets = coordinateSpace.window?.safeAreaInsets
            ?? view.window?.safeAreaInsets
            ?? displayState.mediaSafeAreaInsets
            ?? view.safeAreaInsets
        let mediaFrame = AssetViewerPageLayout(viewport: bounds.size)
            .presentationMediaFrame(
                aspectRatio: aspectRatio ?? asset.ratio,
                showsChrome: displayState.mode == .viewer
                    && displayState.chromeVisible
                    && !displayState.currentPageZoomed,
                topSafeAreaInset: safeAreaInsets.top,
                bottomSafeAreaInset: safeAreaInsets.bottom,
                reservesTransportControls: asset.isVideo || asset.isLivePhoto
            )
        return mediaFrame.offsetBy(dx: bounds.minX, dy: bounds.minY)
    }

    private func presentationFrame(of sourceView: UIView, in coordinateSpace: UIView) -> CGRect? {
        guard let sourceWindow = sourceView.window,
              let coordinateWindow = coordinateSpace.window,
              sourceWindow === coordinateWindow,
              !sourceView.bounds.isEmpty
        else { return nil }

        let sourceLayer: CALayer
        let coordinateLayer: CALayer
        if let sourcePresentation = sourceView.layer.presentation(),
           let coordinatePresentation = coordinateSpace.layer.presentation() {
            sourceLayer = sourcePresentation
            coordinateLayer = coordinatePresentation
        } else {
            sourceLayer = sourceView.layer
            coordinateLayer = coordinateSpace.layer
        }
        let bounds = sourceLayer.bounds
        let corners = [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY),
            CGPoint(x: bounds.minX, y: bounds.maxY)
        ].map { sourceLayer.convert($0, to: coordinateLayer) }
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max(),
              minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite,
              maxX > minX, maxY > minY
        else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    fileprivate func viewerMediaFrameSourceChanged(
        assetID: String,
        view: UIView,
        aspectRatio: Double,
        isAttached: Bool
    ) {
        mediaFrameSources.update(
            assetID: assetID,
            view: view,
            aspectRatio: aspectRatio,
            isAttached: isAttached
        )
    }

    fileprivate func viewerChromeVisibilityChanged(_ visible: Bool) {
        guard displayState.chromeVisible != visible else { return }
        displayState.chromeVisible = visible
        let duration = assetViewerChromeTransitionDuration
        chromeTransitionDeadline = CACurrentMediaTime() + duration
        let coordinateSpace = presentationController?.containerView ?? view.superview
        let targetFrame = coordinateSpace.flatMap {
            layoutTransitionMediaFrame(
                in: $0,
                aspectRatio: mediaFrameSources.source(
                    for: displayState.currentAssetID
                )?.aspectRatio
            )
        }
        if phase == .presenting,
           let targetFrame,
           transitionDriver.retargetPresentationZoom(to: targetFrame) {
            return
        }
        guard let zoomView = presentationZoomView, let targetFrame else {
            fadePresentationZoomView()
            return
        }
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut]
        ) {
            zoomView.frame = targetFrame
            zoomView.layer.cornerRadius = 0
        }
        releasePresentationZoomViewWhenReady()
    }

    fileprivate func viewerPageZoomChanged(_ isZoomed: Bool) {
        displayState.currentPageZoomed = isZoomed
    }

    fileprivate func viewerInteractiveMediaInteractionStarted() {
        guard phase == .presented else { return }
        if let swipeDismissal, swipeCancellationAnimator != nil {
            swipeCancellationAnimator?.stopAnimation(true)
            swipeCancellationAnimator = nil
            completeSwipeCancellationHandoff(swipeDismissal)
        }
        guard swipeDismissal == nil else { return }
        guard activePresentationZoomView != nil
            || presentationZoomView != nil
            || openingChromeOverlay != nil
            || !displayState.transitionMediaVisible
            || !displayState.viewerChromeRevealed
        else { return }
        setTransitionMediaVisible(true)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        completeOpeningChromeHandoff()
        removePresentationZoomView()
    }

    fileprivate func prepareViewerContentForPresentation() {
        guard displayState.mode == .viewer else { return }
        // let the first opacity frame reach the compositor before swiftui mounts.
        scheduleViewerRootInstallation(after: .milliseconds(18))
    }

    fileprivate func installDismissalGesture(on container: UIView) {
        transitionDriver.installGesture(on: container)
    }

    fileprivate func setTransitionMediaVisible(_ visible: Bool) {
        guard displayState.transitionMediaVisible != visible else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayState.transitionMediaVisible = visible
        }
        guard isViewLoaded else { return }
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    fileprivate func makeOpeningChromeOverlay(
        in container: UIView
    ) -> AssetViewerOpeningChromeOverlay? {
        guard let openingChromePresentation else { return nil }
        return AssetViewerOpeningChromeCache.shared.take(
            presentation: openingChromePresentation,
            in: container,
            onClose: { [weak self] in self?.requestDismissal() }
        )
    }

    fileprivate func holdOpeningChromeOverlay(
        _ overlay: AssetViewerOpeningChromeOverlay
    ) {
        guard overlay.superview != nil else { return }
        openingChromeHandoffGeneration &+= 1
        openingChromeOverlay?.removeFromSuperview()
        openingChromeOverlay = overlay
        overlay.prepareForHandoff()
    }

    fileprivate func trackPresentationZoomView(_ zoomView: UIImageView) {
        activePresentationZoomView = zoomView
    }

    fileprivate func holdPresentationZoomView(_ zoomView: UIImageView) {
        if activePresentationZoomView === zoomView {
            activePresentationZoomView = nil
        }
        guard zoomView.superview != nil else { return }
        presentationZoomView = zoomView
        presentationZoomFallbackDeadline = CACurrentMediaTime() + 0.8
        releasePresentationZoomViewWhenReady()
    }

    fileprivate func discardTrackedPresentationZoomView(_ zoomView: UIImageView) {
        if activePresentationZoomView === zoomView {
            activePresentationZoomView = nil
        }
    }

    fileprivate func presentationMediaBecameReady() {
        presentationMediaReady = true
        releasePresentationZoomViewWhenReady()
    }

    private func releasePresentationZoomViewWhenReady() {
        guard let zoomView = presentationZoomView else { return }
        presentationZoomReleaseTask?.cancel()
        guard displayState.viewerChromeRevealed else { return }
        let releaseDeadline = presentationMediaReady
            ? chromeTransitionDeadline
            : max(chromeTransitionDeadline, presentationZoomFallbackDeadline)
        let delay = max(0, releaseDeadline - CACurrentMediaTime())
        guard delay > 0.001 else {
            fadePresentationZoomView()
            return
        }
        presentationZoomReleaseTask = Task { @MainActor [weak self, weak zoomView] in
            try? await Task.sleep(for: .milliseconds(Int64(ceil(delay * 1_000))))
            guard let self, !Task.isCancelled, self.presentationZoomView === zoomView else { return }
            self.fadePresentationZoomView()
        }
    }

    private func fadePresentationZoomView() {
        guard let zoomView = presentationZoomView else { return }
        presentationZoomReleaseTask?.cancel()
        presentationZoomReleaseTask = nil
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.1,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut]
        ) {
            zoomView.alpha = 0
        } completion: { [weak self, weak zoomView] _ in
            guard let self, self.presentationZoomView === zoomView else { return }
            zoomView?.removeFromSuperview()
            self.presentationZoomView = nil
            self.presentationZoomFallbackDeadline = 0
        }
    }

    private func removePresentationZoomView() {
        presentationZoomReleaseTask?.cancel()
        presentationZoomReleaseTask = nil
        activePresentationZoomView?.layer.removeAllAnimations()
        activePresentationZoomView?.removeFromSuperview()
        activePresentationZoomView = nil
        presentationZoomView?.layer.removeAllAnimations()
        presentationZoomView?.removeFromSuperview()
        presentationZoomView = nil
        presentationZoomFallbackDeadline = 0
    }

    private func synchronizeMediaSafeAreaInsets() {
        guard view.window != nil else { return }
        let insets = view.safeAreaInsets
        guard displayState.mediaSafeAreaInsets != insets else { return }
        displayState.mediaSafeAreaInsets = insets
    }

    private var transitionAsset: Asset? {
        guard let index = route.indexByAssetID[displayState.currentAssetID] else { return nil }
        return route.assets[safe: index]
    }

    private func cachedTransitionImage() -> UIImage? {
        guard let asset = transitionAsset else { return nil }
        let pairedLocalID = asset.localIdentifier
            ?? session.backup?.localIdentifierByRemoteId[asset.id]
        if let pairedLocalID {
            for targetPixelSize in [pagePixelSize, 1280, 640] {
                if let image = LocalImageLoader.shared.cachedImage(
                    localIdentifier: pairedLocalID,
                    targetPixelSize: targetPixelSize,
                    contentMode: .aspectFit
                ) {
                    return image
                }
            }
        }
        guard let client = session.client else { return nil }
        let previewURL = client.thumbnailURL(
            assetID: asset.id,
            size: "preview",
            cacheKey: asset.thumbhash
        )
        for targetPixelSize in [pagePixelSize, 1280, 640] {
            if let image = ImageLoader.shared.cachedImage(
                for: previewURL,
                targetPixelSize: targetPixelSize
            ) {
                return image
            }
        }
        let thumbnailURL = client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash)
        return ImageLoader.shared.cachedImage(for: thumbnailURL, targetPixelSize: 640)
    }

    fileprivate func makeDetachedTransitionZoomView(frame: CGRect) -> UIImageView? {
        guard let image = cachedTransitionImage() else { return nil }
        return makeAssetViewerZoomView(image: image, frame: frame, cornerRadius: 0)
    }

    fileprivate var isReadyForSwipeDismissal: Bool {
        phase == .presented && !dismissalRequested && swipeDismissal == nil
    }

    fileprivate var isPresenting: Bool {
        phase == .presenting && !dismissalRequested
    }

    fileprivate func canBeginDownwardDismissal(velocity: CGPoint, location: CGPoint) -> Bool {
        guard !dismissalRequested,
              phase == .presenting || isReadyForSwipeDismissal
        else { return false }
        guard velocity.y > 0, abs(velocity.y) > abs(velocity.x) else { return false }
        return !displayState.currentPageZoomed
            && displayState.mediaAtTop
            && !isTouchingControl(at: location)
    }

    fileprivate func cancelPendingViewerZoomCommand() {
        displayState.zoomCommandBridge.cancelPendingFit()
    }

    fileprivate func commitOpeningSwipeDismissal() {
        guard phase == .presenting, !dismissalRequested else { return }
        dismissalRequested = true
        viewerRootInstallationTask?.cancel()
        viewerRootInstallationTask = nil
        suppressSourceInteraction()
        passTouchesToTimeline()
    }

    fileprivate func beginSwipeDismissal() -> Bool {
        guard isReadyForSwipeDismissal,
              let container = presentationController?.containerView ?? view.superview
        else { return false }
        openingChromeHandoffGeneration &+= 1
        let openingChromeOverlay = openingChromeOverlay
        openingChromeOverlay?.isUserInteractionEnabled = false
        removePresentationZoomView()
        suppressSourceInteraction()
        if !UIAccessibility.isReduceMotionEnabled,
           let mediaFrame = transitionMediaFrame(in: container) {
            let source = transitionZoomSource(in: container)
            let zoomView = source?.makeZoomView(frame: mediaFrame, cornerRadius: 0)
                ?? makeDetachedTransitionZoomView(frame: mediaFrame)
            guard let zoomView else {
                let chromeHost: UIView = view.window ?? container
                let chromeSnapshot = openingChromeOverlay == nil
                    ? makeChromeSnapshot(in: chromeHost)
                    : nil
                chromeSnapshot?.install(in: chromeHost)
                swipeDismissal = AssetViewerSwipeDismissal(
                    chromeSnapshot: chromeSnapshot,
                    openingChromeOverlay: openingChromeOverlay
                )
                return true
            }
            setTransitionMediaVisible(false)
            let chromeHost: UIView = view.window ?? container
            let chromeSnapshot = openingChromeOverlay == nil
                ? makeChromeSnapshot(in: chromeHost)
                : nil
            source?.hide()
            container.addSubview(zoomView)
            if let chromeSnapshot {
                chromeSnapshot.install(in: chromeHost)
            }
            swipeDismissal = AssetViewerSwipeDismissal(
                source: source,
                zoomView: zoomView,
                mediaFrame: mediaFrame,
                chromeSnapshot: chromeSnapshot,
                openingChromeOverlay: openingChromeOverlay
            )
        } else {
            let chromeHost: UIView = view.window ?? container
            let chromeSnapshot = openingChromeOverlay == nil
                ? makeChromeSnapshot(in: chromeHost)
                : nil
            chromeSnapshot?.install(in: chromeHost)
            swipeDismissal = AssetViewerSwipeDismissal(
                chromeSnapshot: chromeSnapshot,
                openingChromeOverlay: openingChromeOverlay
            )
        }
        return true
    }

    fileprivate func updateSwipeDismissal(translation: CGPoint, progress: CGFloat) {
        guard let swipeDismissal else { return }
        let progress = min(1, max(0, progress))
        view.alpha = 1 - progress
        swipeDismissal.chromeSnapshot?.setAlpha(1 - progress)
        swipeDismissal.openingChromeOverlay?.alpha = 1 - progress
        if let zoomView = swipeDismissal.zoomView,
           let mediaFrame = swipeDismissal.mediaFrame {
            let scale = 1 - progress * 0.12
            let size = CGSize(
                width: mediaFrame.width * scale,
                height: mediaFrame.height * scale
            )
            zoomView.frame = CGRect(
                x: mediaFrame.midX + translation.x - size.width / 2,
                y: mediaFrame.midY + max(0, translation.y) - size.height / 2,
                width: size.width,
                height: size.height
            )
            return
        }
    }

    fileprivate func finishSwipeDismissal() {
        guard swipeDismissal != nil,
              phase == .presented,
              presentingViewController != nil
        else {
            cancelSwipeDismissal()
            return
        }
        phase = .dismissing
        dismissalRequested = true
        dismissWithoutBlockingTimeline()
    }

    fileprivate func cancelSwipeDismissal() {
        guard let swipeDismissal else { return }
        swipeCancellationAnimator?.stopAnimation(true)
        let returnFrame = swipeDismissal.zoomView?.superview
            .flatMap {
                layoutTransitionMediaFrame(
                    in: $0,
                    aspectRatio: mediaFrameSources.source(
                        for: displayState.currentAssetID
                    )?.aspectRatio
                )
            }
            ?? swipeDismissal.mediaFrame
        let minimumDuration: TimeInterval = UIAccessibility.isReduceMotionEnabled ? 0.08 : 0.14
        let duration = max(
            minimumDuration,
            chromeTransitionDeadline - CACurrentMediaTime()
        )
        let animator = UIViewPropertyAnimator(duration: duration, dampingRatio: 1) {
            self.view.alpha = 1
            self.view.transform = .identity
            swipeDismissal.chromeSnapshot?.setAlpha(1)
            swipeDismissal.openingChromeOverlay?.alpha = 1
            if let zoomView = swipeDismissal.zoomView,
               let returnFrame {
                zoomView.frame = returnFrame
                zoomView.layer.cornerRadius = 0
                zoomView.alpha = 1
                zoomView.transform = .identity
            }
        }
        animator.addCompletion { [weak self] _ in
            self?.completeSwipeCancellationHandoff(swipeDismissal)
        }
        swipeCancellationAnimator = animator
        animator.startAnimation()
    }

    private func completeSwipeCancellationHandoff(
        _ swipeDismissal: AssetViewerSwipeDismissal
    ) {
        guard self.swipeDismissal === swipeDismissal else { return }
        view.layer.removeAllAnimations()
        view.alpha = 1
        view.transform = .identity
        swipeDismissal.chromeSnapshot?.setAlpha(1)
        swipeDismissal.openingChromeOverlay?.alpha = 1
        setTransitionMediaVisible(true)
        swipeDismissal.zoomView?.removeFromSuperview()
        swipeDismissal.source?.restore()
        swipeDismissal.chromeSnapshot?.restore()
        swipeDismissal.openingChromeOverlay?.isUserInteractionEnabled = true
        completeOpeningChromeHandoff()
        self.swipeDismissal = nil
        swipeCancellationAnimator = nil
        restoreSourceInteraction()
    }

    fileprivate func takeSwipeDismissal() -> AssetViewerSwipeDismissal? {
        swipeCancellationAnimator?.stopAnimation(true)
        swipeCancellationAnimator = nil
        let swipeDismissal = swipeDismissal
        self.swipeDismissal = nil
        return swipeDismissal
    }

    fileprivate func presentationWasCancelled() {
        guard phase == .presenting else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.finishIfDetached()
        }
    }

    private func dismissWithoutBlockingTimeline() {
        guard dismissalRequested, let presenter = presentingViewController else { return }
        phase = .dismissing
        if let transition = makeDetachedDismissal() {
            AssetViewerDetachedDismissalStore.run(transition)
        }
        passTouchesToTimeline()
        presenter.dismiss(animated: false) { [weak self] in
            self?.finishIfDetached()
        }
    }

    private func makeDetachedDismissal() -> AssetViewerDetachedDismissal? {
        guard let window = view.window else { return nil }

        let swipe = takeSwipeDismissal()
        var source: AssetViewerZoomSource?
        var zoomView: UIImageView?
        var zoomFrame: CGRect?
        var targetFrame: CGRect?

        if let swipeZoomView = swipe?.zoomView,
           let container = swipeZoomView.superview {
            source = swipe?.source
            zoomView = swipeZoomView
            zoomFrame = container.convert(swipeZoomView.frame, to: window)
            if let source {
                targetFrame = container.convert(source.frame, to: window)
            }
        } else if let mediaFrame = transitionMediaFrame(in: window) {
            source = transitionZoomSource(in: window)
            zoomView = source?.makeZoomView(frame: mediaFrame, cornerRadius: 0)
                ?? makeDetachedTransitionZoomView(frame: mediaFrame)
            zoomFrame = mediaFrame
            source?.hide()
            targetFrame = source?.frame
        }

        let chromeSnapshot: AssetViewerChromeSnapshot?
        let openingChromeOverlay = swipe?.openingChromeOverlay
        if openingChromeOverlay != nil {
            self.openingChromeOverlay = nil
            chromeSnapshot = nil
        } else if let swipeChromeSnapshot = swipe?.chromeSnapshot {
            chromeSnapshot = swipeChromeSnapshot
        } else {
            setTransitionMediaVisible(false)
            chromeSnapshot = makeChromeSnapshot(in: window)
        }
        return AssetViewerDetachedDismissal(
            window: window,
            backdropAlpha: view.alpha,
            chromeSnapshot: chromeSnapshot,
            openingChromeOverlay: openingChromeOverlay,
            contentAlpha: view.alpha,
            zoomView: zoomView,
            zoomFrame: zoomFrame,
            targetFrame: targetFrame,
            source: source
        )
    }

    private func makeChromeSnapshot(in coordinateSpace: UIView) -> AssetViewerChromeSnapshot? {
        return AssetViewerChromeSnapshot(
            chromeViews: viewerChromeViews(in: view),
            in: coordinateSpace
        )
    }

    private func canPresent(from presenter: UIViewController) -> Bool {
        presenter.viewIfLoaded?.window != nil && presenter.presentedViewController == nil
    }

    private func attachAfterContextCommit(to presenter: UIViewController) {
        setTransitionMediaVisible(true)
        installViewerRootIfNeeded()
        presenter.present(self, animated: false) { [weak self] in
            self?.presentationFinished()
        }
        verifyPresentationStarted(from: presenter)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationController?.delegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if phase == .presenting {
            presentationFinished()
            return
        }
        guard phase == .dismissing,
              !isTrackingDismissalTransition,
              !dismissalRequested,
              !isBeingDismissed
        else { return }
        cancelDismissal()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // presenting the editor or profile crop also hides this controller.
        // only an actual viewer dismissal may release the timeline.
        guard phase == .dismissing || dismissalRequested || isBeingDismissed else { return }
        phase = .dismissing
        suppressSourceInteraction()
        trackDismissal(using: transitionCoordinator)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard phase != .idle, phase != .finished else { return }
        finishIfDetached()
    }

    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        guard phase != .idle, phase != .finished else { return }
        phase = .dismissing
        suppressSourceInteraction()
        trackDismissal(using: transitionCoordinator)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finishIfDetached()
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        guard phase == .dismissing else { return }
        cancelDismissal()
    }

    private func beginPresentation() -> Bool {
        guard phase == .idle, willPresent(route) else { return false }
        AssetViewerDetachedDismissalStore.completeAll()
        return true
    }

    private func presentationFinished() {
        guard phase == .presenting else { return }
        guard presentingViewController != nil else {
            finish()
            return
        }
        setTransitionMediaVisible(true)
        phase = .presented
        presentationController?.containerView?.isUserInteractionEnabled = true
        presentationController?.delegate = self
        didPresent(route.id)
        if !dismissalRequested { scheduleViewerContentActivation() }
        retryRequestedDismissalIfNeeded()
    }

    private func scheduleViewerContentActivation() {
        guard !displayState.viewerContentReady, viewerContentActivationTask == nil else { return }
        viewerContentActivationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.viewerContentActivationTask = nil
            guard !Task.isCancelled,
                  self.phase == .presented,
                  !self.dismissalRequested,
                  !self.isBeingDismissed
            else { return }
            self.displayState.viewerContentReady = true
            await Task.yield()
            guard !Task.isCancelled, self.phase == .presented else { return }
            self.view.layoutIfNeeded()
            self.transitionDriver.prioritizeDismissalGesture(in: self.view)
            self.revealViewerChrome()
        }
    }

    private func scheduleViewerRootInstallation(after delay: Duration) {
        guard !isViewerRootInstalled, viewerRootInstallationTask == nil else { return }
        viewerRootInstallationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.viewerRootInstallationTask = nil
            guard !self.dismissalRequested else { return }
            self.installViewerRootIfNeeded()
        }
    }

    private func installViewerRootIfNeeded() {
        guard !isViewerRootInstalled, let root = preparedViewerRoot else { return }
        isViewerRootInstalled = true
        preparedViewerRoot = nil
        rootView = root
        view.layoutIfNeeded()
        transitionDriver.prioritizeDismissalGesture(in: view)
        if displayState.viewerContentReady { revealViewerChrome() }
    }

    private func revealViewerChrome() {
        guard !displayState.viewerChromeRevealed else { return }
        let duration = AssetViewerOpeningChromeReveal.duration(
            reduceMotion: UIAccessibility.isReduceMotionEnabled
        )
        chromeTransitionDeadline = max(
            chromeTransitionDeadline,
            CACurrentMediaTime() + duration
        )
        guard duration > 0 else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                displayState.viewerChromeRevealed = true
            }
            completeOpeningChromeHandoff()
            releasePresentationZoomViewWhenReady()
            return
        }
        openingChromeHandoffGeneration &+= 1
        let handoffGeneration = openingChromeHandoffGeneration
        withAnimation(
            .easeOut(duration: duration),
            completionCriteria: .removed
        ) {
            displayState.viewerChromeRevealed = true
        } completion: { [weak self] in
            guard let self,
                  self.openingChromeHandoffGeneration == handoffGeneration,
                  self.swipeDismissal == nil
            else { return }
            self.completeOpeningChromeHandoff()
        }
        releasePresentationZoomViewWhenReady()
    }

    private func completeOpeningChromeHandoff() {
        openingChromeHandoffGeneration &+= 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayState.viewerChromeRevealed = true
        }
        view.layoutIfNeeded()
        openingChromeOverlay?.removeFromSuperview()
        openingChromeOverlay = nil
    }

    private func viewerChromeViews(in root: UIView) -> [UIView] {
        var result: [UIView] = []
        for subview in root.subviews {
            if subview is UINavigationBar || subview is UIToolbar {
                result.append(subview)
            } else {
                result.append(contentsOf: viewerChromeViews(in: subview))
            }
        }
        return result
    }

    private func verifyPresentationStarted(from presenter: UIViewController) {
        Task { @MainActor [self, weak presenter] in
            await Task.yield()
            guard phase == .presenting else { return }
            guard presentingViewController != nil || presenter?.presentedViewController === self else {
                finish()
                return
            }
        }
    }

    private func trackDismissal(using coordinator: (any UIViewControllerTransitionCoordinator)?) {
        guard !isTrackingDismissalTransition else { return }
        guard let coordinator else {
            passTouchesToTimeline()
            return
        }
        isTrackingDismissalTransition = true
        if coordinator.isInteractive {
            coordinator.notifyWhenInteractionChanges { [weak self] context in
                guard let self, !context.isCancelled else { return }
                self.passTouchesToTimeline()
            }
        } else {
            passTouchesToTimeline()
        }
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard let self else { return }
            self.isTrackingDismissalTransition = false
            if context.isCancelled {
                self.cancelDismissal()
            }
        }
    }

    private func cancelDismissal() {
        clearSwipeDismissal(revealsMedia: true)
        phase = .presented
        dismissalRequested = false
        presentationAfterDismissal = nil
        isTrackingDismissalTransition = false
        viewerContentActivationTask?.cancel()
        viewerContentActivationTask = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayState.viewerContentReady = true
            displayState.viewerChromeRevealed = true
        }
        releasePresentationZoomViewWhenReady()
        setTransitionMediaVisible(true)
        view.alpha = 1
        view.transform = .identity
        view.isUserInteractionEnabled = true
        presentationController?.containerView?.isUserInteractionEnabled = true
        restoreSourceInteraction()
    }

    private func finishIfDetached() {
        guard presentingViewController == nil else { return }
        finish()
    }

    private func finish() {
        guard phase != .idle, phase != .finished else { return }
        let nextPresentation = presentationAfterDismissal
        presentationAfterDismissal = nil
        contextCommitPresentationTask?.cancel()
        contextCommitPresentationTask = nil
        viewerRootInstallationTask?.cancel()
        viewerRootInstallationTask = nil
        viewerContentActivationTask?.cancel()
        viewerContentActivationTask = nil
        openingChromeHandoffGeneration &+= 1
        openingChromeOverlay?.removeFromSuperview()
        openingChromeOverlay = nil
        removePresentationZoomView()
        clearSwipeDismissal(revealsMedia: false)
        phase = .finished
        dismissalRequested = false
        displayState.currentPageZoomed = false
        restoreSourceInteraction()
        didDismiss(route.id)
        guard let nextPresentation else { return }
        nextPresentation()
    }

    private func clearSwipeDismissal(revealsMedia: Bool) {
        swipeCancellationAnimator?.stopAnimation(true)
        swipeCancellationAnimator = nil
        let swipeOpeningChrome = swipeDismissal?.openingChromeOverlay
        if revealsMedia { setTransitionMediaVisible(true) }
        swipeDismissal?.zoomView?.removeFromSuperview()
        swipeDismissal?.source?.restore()
        swipeDismissal?.chromeSnapshot?.restore()
        if revealsMedia {
            swipeOpeningChrome?.alpha = 1
            swipeOpeningChrome?.isUserInteractionEnabled = true
            completeOpeningChromeHandoff()
        } else {
            swipeOpeningChrome?.removeFromSuperview()
            if let swipeOpeningChrome,
               openingChromeOverlay === swipeOpeningChrome {
                openingChromeOverlay = nil
            }
        }
        swipeDismissal = nil
        if isViewLoaded {
            view.alpha = 1
            view.transform = .identity
        }
    }

    private func suppressSourceInteraction() {
        sourceRegistry?.suppressInteraction(for: displayState.currentAssetID)
    }

    private func restoreSourceInteraction() {
        sourceRegistry?.restoreInteraction(for: displayState.currentAssetID)
    }

    private func passTouchesToTimeline() {
        view.isUserInteractionEnabled = false
        presentationController?.containerView?.isUserInteractionEnabled = false
    }

    private func isTouchingControl(at location: CGPoint) -> Bool {
        var candidate = view.hitTest(location, with: nil)
        while let current = candidate {
            if current is UIControl { return true }
            guard current !== view else { return false }
            candidate = current.superview
        }
        return false
    }

    private var isClosing: Bool {
        dismissalRequested || phase == .dismissing || phase == .finished || isBeingDismissed
    }

    private func queueBehindClosingViewer(on presenter: UIViewController) -> Bool {
        guard let outgoing = presenter.presentedViewController as? AssetViewerHostingController,
              outgoing !== self,
              outgoing.isClosing
        else { return false }
        outgoing.enqueuePresentation { [self, weak presenter] in
            guard let presenter else { return }
            presentDirectly(from: presenter)
        }
        outgoing.transitionDriver.completeClosingTransitionImmediately()
        return true
    }

    private func enqueuePresentation(_ presentation: @escaping () -> Void) {
        guard phase != .finished else {
            presentation()
            return
        }
        presentationAfterDismissal = presentation
    }

    private func retryRequestedDismissalIfNeeded() {
        guard dismissalRequested else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  self.phase == .presented,
                  self.dismissalRequested,
                  !self.isBeingDismissed
            else { return }
            self.dismissWithoutBlockingTimeline()
        }
    }
}

@MainActor
private struct AssetViewerHostRoot: View {
    let route: ViewerRoute
    let displayState: AssetViewerDisplayState
    let dismissalRelay: AssetViewerDismissalRelay
    let album: AlbumContext?
    let personID: String?
    let onChange: (AssetChange) -> Void

    @ViewBuilder var body: some View {
        if displayState.viewerContentReady {
            ZStack {
                AssetViewerScreen(
                    assets: route.assets,
                    indexByAssetID: route.indexByAssetID,
                    initialIndex: route.initialIndex,
                    presentationID: route.id,
                    isContextPreview: displayState.mode == .contextPreview,
                    loadsViewerContent: true,
                    transitionMediaVisible: displayState.transitionMediaVisible,
                    usesExternalBackdrop: true,
                    mediaTopSafeAreaInset: displayState.mediaSafeAreaInsets?.top,
                    mediaBottomSafeAreaInset: displayState.mediaSafeAreaInsets?.bottom,
                    openingMediaImage: displayState.openingMediaImage,
                    zoomCommandBridge: displayState.zoomCommandBridge,
                    album: album,
                    personID: personID,
                    onRequestDismissal: { dismissalRelay.request() },
                    onLaunchMediaReady: { dismissalRelay.presentationMediaReady() },
                    onSelectionChanged: { displayState.currentAssetID = $0 },
                    onPageZoomChanged: { dismissalRelay.pageZoomChanged($0) },
                    onInteractiveMediaInteractionStarted: {
                        dismissalRelay.interactiveMediaInteractionStarted()
                    },
                    onChromeVisibilityChanged: { dismissalRelay.chromeVisibilityChanged($0) },
                    onMediaFrameSourceChanged: {
                        dismissalRelay.mediaFrameSourceChanged(
                            assetID: $0,
                            view: $1,
                            aspectRatio: $2,
                            isAttached: $3
                        )
                    },
                    onMediaAtTopChanged: { displayState.mediaAtTop = $0 },
                    onDismissed: {}
                ) { change in
                    onChange(change)
                }

                Color.black
                    .ignoresSafeArea()
                    .opacity(
                        AssetViewerOpeningChromeReveal.coverOpacity(
                            isRevealed: displayState.viewerChromeRevealed
                        )
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(1)
            }
        } else {
            Color.clear
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
