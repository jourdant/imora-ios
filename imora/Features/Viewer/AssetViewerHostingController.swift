import Observation
import SwiftUI
import UIKit

/// Weak lookup for the live Timeline tile views. UIKit asks the zoom transition
/// for its source more than once, including on dismissal, so the answer must be
/// resolved from the grid as it exists at that moment rather than captured.
@MainActor
final class AssetTileRegistry {
    private final class WeakTile {
        weak var view: UIView?

        init(_ view: UIView) {
            self.view = view
        }
    }

    private var tiles: [String: WeakTile] = [:]

    func register(_ view: UIView, for assetID: String) {
        tiles[assetID] = WeakTile(view)
    }

    func unregister(_ view: UIView, for assetID: String) {
        guard tiles[assetID]?.view === view else { return }
        tiles.removeValue(forKey: assetID)
    }

    func liveView(for assetID: String) -> UIView? {
        guard let view = tiles[assetID]?.view else {
            tiles.removeValue(forKey: assetID)
            return nil
        }
        guard let window = view.window,
              !view.isHidden,
              view.alpha > 0.01,
              view.convert(view.bounds, to: window).intersects(window.bounds)
        else { return nil }
        return view
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
    /// whether the viewer's vertical scroll rests on the media page. while
    /// the information page is open, pans belong to that scroll.
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
}

/// The single UIKit destination used by both a normal Timeline tap and a
/// context-menu preview commit. For a long press this exact controller starts
/// as the floating media preview; UIKit expands it with `.pop`, then it is
/// attached full-screen without starting a second presentation animation.
@MainActor
final class AssetViewerHostingController: UIHostingController<AnyView>, UIAdaptivePresentationControllerDelegate {
    private enum Phase {
        case idle
        case committingPreview
        case presenting
        case presented
        case dismissing
        case finished
    }

    let route: ViewerRoute
    let displayState: AssetViewerDisplayState

    private let willPresent: (ViewerRoute) -> Bool
    private let didDismiss: (UUID) -> Void
    private let dismissalRelay: AssetViewerDismissalRelay
    private var contextPreviewController: UIHostingController<AnyView>?
    private var phase = Phase.idle
    private var isTrackingDismissalTransition = false
    private var contextAttachmentAttempts = 0
    private var pendingDismissal = false

    init(
        route: ViewerRoute,
        startsAsContextPreview: Bool,
        previewBounds: CGSize,
        session: SessionStore,
        sourceRegistry: AssetTileRegistry,
        album: AlbumContext?,
        willPresent: @escaping (ViewerRoute) -> Bool,
        didDismiss: @escaping (UUID) -> Void,
        onChange: @escaping (AssetChange) -> Void
    ) {
        let state = AssetViewerDisplayState(
            mode: startsAsContextPreview ? .contextPreview : .viewer,
            currentAssetID: route.sourceAssetID
        )
        let relay = AssetViewerDismissalRelay()

        self.route = route
        self.displayState = state
        self.willPresent = willPresent
        self.didDismiss = didDismiss
        self.dismissalRelay = relay

        let root = AssetViewerHostRoot(
            route: route,
            displayState: state,
            dismissalRelay: relay,
            album: album,
            onChange: onChange
        )
        .environment(session)
        super.init(rootView: AnyView(root))

        relay.controller = self
        modalPresentationStyle = .fullScreen
        view.backgroundColor = .clear

        let options = UIViewController.Transition.ZoomOptions()
        // vertical pans feed the media-info scroll. only a downward pull with
        // the media page at rest hands the gesture to the dismissal, otherwise
        // the transition's recognizer eats every swipe and the scroll is dead.
        options.interactiveDismissShouldBegin = { [weak state] context in
            guard context.willBegin, let state else { return false }
            return !state.currentPageZoomed && state.mediaAtTop && context.velocity.dy > 0
        }
        preferredTransition = .zoom(options: options) { [weak state, weak sourceRegistry] _ in
            guard let assetID = state?.currentAssetID else { return nil }
            return sourceRegistry?.liveView(for: assetID)
        }

        if startsAsContextPreview,
           let asset = route.assets[safe: route.initialIndex] {
            let ratio = CGFloat(asset.ratio > 0 ? asset.ratio : 1)
            let height = min(previewBounds.height * 0.62, (previewBounds.width - 24) / ratio)
            preferredContentSize = CGSize(width: ratio * height, height: height)
            view.frame = CGRect(origin: .zero, size: preferredContentSize)
            installContextPreview(for: asset, session: session)
            view.layoutIfNeeded()
        }
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Used by a regular tile tap. The native zoom transition is the only
    /// presentation animation in this path.
    func presentDirectly(from presenter: UIViewController) {
        guard presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil
        else { return }
        guard beginPresentation() else { return }
        displayState.mode = .viewer
        phase = .presenting
        presenter.present(self, animated: true) { [weak self] in
            self?.presentationFinished()
        }
        verifyPresentationStarted(from: presenter)
    }

    /// Locks the Timeline before UIKit starts expanding the floating preview.
    /// The already-mounted viewer is then revealed inside the commit animator.
    func prepareForContextCommit() -> Bool {
        guard displayState.mode == .contextPreview, beginPresentation() else { return false }
        phase = .committingPreview
        return true
    }

    /// Runs inside the context-menu commit animator. The real viewer is already
    /// mounted below this media overlay, so fading the overlay reveals that
    /// persistent hierarchy while UIKit expands the same controller.
    func revealViewerForContextCommit() {
        guard phase == .committingPreview else { return }
        displayState.mode = .viewer
        contextPreviewController?.view.alpha = 0
    }

    /// Called only after the context-menu `.pop` has completed and UIKit has
    /// released the preview controller. Attaching the same instance without an
    /// animation makes the expanded preview become the live viewer immediately.
    func attachAfterContextCommit(to presenter: UIViewController) {
        guard phase == .committingPreview else { return }
        let previewStillOwned = parent != nil || presentingViewController != nil
        let presenterUnavailable = presenter.viewIfLoaded?.window == nil
            || presenter.presentedViewController != nil
        if previewStillOwned || presenterUnavailable {
            guard contextAttachmentAttempts < 3 else {
                finish()
                return
            }
            contextAttachmentAttempts += 1
            Task { @MainActor [self, presenter] in
                await Task.yield()
                attachAfterContextCommit(to: presenter)
            }
            return
        }

        contextAttachmentAttempts = 0
        preferredContentSize = .zero
        revealViewerForContextCommit()
        removeContextPreview()
        phase = .presenting
        presenter.present(self, animated: false) { [weak self] in
            self?.presentationFinished()
        }
        verifyPresentationStarted(from: presenter)
    }

    func requestDismissal() {
        if phase == .committingPreview || phase == .presenting {
            pendingDismissal = true
            return
        }
        guard phase == .presented else { return }
        phase = .dismissing
        dismiss(animated: true) { [weak self] in
            guard let self else { return }
            if self.presentingViewController == nil {
                self.finish()
            } else if self.phase == .dismissing {
                self.phase = .presented
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if phase == .presenting {
            presentationFinished()
        } else if phase == .dismissing {
            // An interactive dismissal that returned to the viewer.
            phase = .presented
            isTrackingDismissalTransition = false
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // Presenting the editor/profile crop also hides this controller. It is
        // not a viewer dismissal and must leave Timeline suspended.
        guard phase == .dismissing || (phase == .presented && isBeingDismissed) else { return }
        if phase == .presented { phase = .dismissing }
        trackDismissal(using: transitionCoordinator)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard phase == .dismissing, presentingViewController == nil else { return }
        finish()
    }

    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        guard phase == .presented else { return }
        phase = .dismissing
        trackDismissal(using: transitionCoordinator)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard phase == .dismissing else { return }
        finish()
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        guard phase == .dismissing else { return }
        phase = .presented
        isTrackingDismissalTransition = false
    }

    private func beginPresentation() -> Bool {
        guard phase == .idle, willPresent(route) else { return false }
        return true
    }

    private func presentationFinished() {
        guard phase == .presenting else { return }
        guard presentingViewController != nil else {
            finish()
            return
        }
        phase = .presented
        presentationController?.delegate = self
        if pendingDismissal {
            pendingDismissal = false
            requestDismissal()
        }
    }

    private func installContextPreview(for asset: Asset, session: SessionStore) {
        let preview = UIHostingController(
            rootView: AnyView(AssetContextPreview(asset: asset).environment(session))
        )
        preview.view.backgroundColor = .clear
        preview.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(preview)
        view.addSubview(preview.view)
        NSLayoutConstraint.activate([
            preview.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.view.topAnchor.constraint(equalTo: view.topAnchor),
            preview.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        preview.didMove(toParent: self)
        contextPreviewController = preview
    }

    private func removeContextPreview() {
        guard let preview = contextPreviewController else { return }
        preview.willMove(toParent: nil)
        preview.view.removeFromSuperview()
        preview.removeFromParent()
        contextPreviewController = nil
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
        guard !isTrackingDismissalTransition, let coordinator else { return }
        isTrackingDismissalTransition = true
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard let self else { return }
            self.isTrackingDismissalTransition = false
            if context.isCancelled {
                self.phase = .presented
            } else {
                self.finish()
            }
        }
    }

    private func finish() {
        guard phase != .idle, phase != .finished else { return }
        phase = .finished
        pendingDismissal = false
        removeContextPreview()
        displayState.currentPageZoomed = false
        didDismiss(route.id)
    }
}

@MainActor
private struct AssetViewerHostRoot: View {
    let route: ViewerRoute
    let displayState: AssetViewerDisplayState
    let dismissalRelay: AssetViewerDismissalRelay
    let album: AlbumContext?
    let onChange: (AssetChange) -> Void

    @ViewBuilder var body: some View {
        AssetViewerScreen(
            assets: route.assets,
            initialIndex: route.initialIndex,
            presentationID: route.id,
            isContextPreview: displayState.mode == .contextPreview,
            album: album,
            onRequestDismissal: { dismissalRelay.request() },
            onSelectionChanged: { displayState.currentAssetID = $0 },
            onPageZoomChanged: { displayState.currentPageZoomed = $0 },
            onMediaAtTopChanged: { displayState.mediaAtTop = $0 },
            onDismissed: {}
        ) { change in
            onChange(change)
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
