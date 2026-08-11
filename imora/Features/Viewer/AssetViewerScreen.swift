import SwiftUI
import AVKit

nonisolated enum AssetChange {
    case favorite(String, Bool)
    case favoriteCommitted(String, Bool)
    case optimisticRemoval(String)
    case removalCommitted(String)
    case removalReverted(String)
    case albumMembershipProjected(String)
    case albumMembershipCommitted(String)
    case albumMembershipReverted(String)
    case removed(String)
    /// deleted from the device only - the server copy remains, so grids keep it.
    case localDeleted(String)
    /// pixels changed server side; the new thumbhash cache-busts stale thumbs.
    case edited(String, thumbhash: String?)
}

private struct ViewerRemoval {
    let asset: Asset
    let index: Int
}

/// full-bleed screen size plus the ignored bottom inset, mirrored into state
/// so gestures and the information panel share the media stage's numbers.
private nonisolated struct ViewerViewport: Equatable, Sendable {
    var size = CGSize.zero
    var bottomInset: CGFloat = 0
}

/// the album a grid belongs to, when it belongs to one. carries the owner so
/// the viewer can offer removal to the same people the server accepts it from.
nonisolated struct AlbumContext: Equatable {
    let id: String
    let ownerID: String?
}

/// destructive flows that need a confirmation dialog before running.
private enum ViewerConfirmation: Identifiable {
    case trash
    case deletePermanently
    case deleteFromDevice

    var id: Int {
        switch self {
        case .trash: 0
        case .deletePermanently: 1
        case .deleteFromDevice: 2
        }
    }
}

/// ios 26 morphs a confirmation dialog out of the control that presented it, so
/// the modifier has to live on that control - on the screen root it anchors to
/// the whole window and the dialog floats in the middle pointing at nothing.
/// every trigger tags its source and only the matching attachment presents.
private enum ViewerConfirmationSource {
    case toolbar
    case menu
}

/// Destinations selected from information are pushed by the viewer after the
/// sheet has fully dismissed, so they use the full screen and native back
/// navigation instead of replacing the sheet's contents.
private enum AssetInformationDestination: Hashable {
    case person(Person)
    case album(Album)
}

/// shared body for the viewer's per-source confirmation attachments.
private struct ViewerConfirmationDialog<Actions: View>: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: $isPresented,
            titleVisibility: .visible,
            actions: actions,
            message: { Text(message) }
        )
    }
}

/// Owns the viewer's nonmodal information surface and any presentation that
/// originates inside it. Keeping the album picker on this sheet avoids asking
/// the underlying viewer controller to present through an existing sheet.
/// used on regular width only, where the sheet floats over unchanged media.
private struct AssetInformationSheet: View {
    private static let detent = PresentationDetent.fraction(
        AssetViewerPageLayout.informationSheetFraction
    )

    let asset: Asset
    let serverAssetID: String?
    let onDateAdjusted: (String, Date, Double) -> Void
    let onAlbumAdded: (String) -> Void
    let onOpenPerson: (Person) -> Void
    let onOpenAlbum: (Album) -> Void

    @State private var showAddToAlbum = false
    @State private var albumMembershipUpdate: AlbumMembershipUpdate?

    var body: some View {
        ScrollView {
            AssetInfoPanel(
                asset: asset,
                onDateAdjusted: onDateAdjusted,
                onAddToAlbum: serverAssetID == nil ? nil : { showAddToAlbum = true },
                onOpenPerson: onOpenPerson,
                onOpenAlbum: onOpenAlbum,
                albumMembershipUpdate: albumMembershipUpdate
            )
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .systemBackground))
        .presentationDetents([Self.detent])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: .systemBackground))
        .presentationBackgroundInteraction(.enabled(upThrough: Self.detent))
        .tint(.accentColor)
        .sheet(isPresented: $showAddToAlbum) {
            if let serverAssetID {
                AddToAlbumSheet(
                    assetIDs: [serverAssetID],
                    onMembershipUpdate: { update in
                        albumMembershipUpdate = AlbumMembershipUpdate(
                            operationID: update.operationID,
                            assetID: asset.id,
                            change: update.change
                        )
                    },
                    onDone: onAlbumAdded
                )
            }
        }
    }
}

/// the compact-width information surface. it lives in the viewer's own
/// hierarchy instead of a modal sheet so its presentation is a plain offset
/// that a drag can drive frame by frame.
private struct AssetInformationPanel: View {
    @Environment(SessionStore.self) private var session

    let asset: Asset
    let serverAssetID: String?
    let bottomInset: CGFloat
    let onDateAdjusted: (String, Date, Double) -> Void
    let onAlbumAdded: (String) -> Void
    let onOpenPerson: (Person) -> Void
    let onOpenAlbum: (Album) -> Void
    let onPullDrag: (CGFloat) -> Void
    let onPullEnd: (CGFloat) -> Void

    @State private var showAddToAlbum = false
    @State private var albumMembershipUpdate: AlbumMembershipUpdate?

    var body: some View {
        InformationSheetScrollView(
            contentKey: contentKey,
            bottomInset: bottomInset,
            onPullDrag: onPullDrag,
            onPullEnd: onPullEnd
        ) {
            AssetInfoPanel(
                asset: asset,
                onDateAdjusted: onDateAdjusted,
                onAddToAlbum: serverAssetID == nil ? nil : { showAddToAlbum = true },
                onOpenPerson: onOpenPerson,
                onOpenAlbum: onOpenAlbum,
                albumMembershipUpdate: albumMembershipUpdate
            )
            .padding(.top, 18)
            // the hosted root does not inherit this screen's environment.
            .environment(session)
            .tint(.accentColor)
        }
        .sheet(isPresented: $showAddToAlbum) {
            if let serverAssetID {
                AddToAlbumSheet(
                    assetIDs: [serverAssetID],
                    onMembershipUpdate: { update in
                        albumMembershipUpdate = AlbumMembershipUpdate(
                            operationID: update.operationID,
                            assetID: asset.id,
                            change: update.change
                        )
                    },
                    onDone: onAlbumAdded
                )
                // the viewer root tints white; this modal wants the accent.
                .tint(.accentColor)
            }
        }
    }

    /// the hosted content re-renders only when this changes, so drag frames
    /// that re-evaluate the screen never touch the info tree.
    private var contentKey: String {
        let membership = albumMembershipUpdate?.operationID.uuidString ?? ""
        return "\(asset.id)|\(serverAssetID ?? "")|\(membership)|\(asset.fileCreatedAt.timeIntervalSince1970)"
    }
}

/// uiscrollview host for the panel content that collaborates with the
/// interactive presentation, photos style: a tracked pull past the top pins
/// the content in place and routes the drag into the panel, pushing back up
/// restores the panel to full before the content scrolls again - all inside
/// one continuous gesture, with no rubber-band detour.
private struct InformationSheetScrollView<Content: View>: UIViewRepresentable {
    let contentKey: String
    let bottomInset: CGFloat
    let onPullDrag: (CGFloat) -> Void
    let onPullEnd: (CGFloat) -> Void
    @ViewBuilder let content: Content

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear

        let hosted = context.coordinator.hostingController
        hosted.view.backgroundColor = .clear
        hosted.sizingOptions = .intrinsicContentSize
        hosted.safeAreaRegions = []
        hosted.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(hosted.view)
        NSLayoutConstraint.activate([
            hosted.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hosted.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hosted.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hosted.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            hosted.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        scrollView.panGestureRecognizer.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        context.coordinator.scrollView = scrollView
        context.coordinator.observeKeyboard()
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onPullDrag = onPullDrag
        context.coordinator.onPullEnd = onPullEnd
        context.coordinator.restingBottomInset = bottomInset
        context.coordinator.applyBottomInset()
        guard context.coordinator.contentKey != contentKey else { return }
        context.coordinator.contentKey = contentKey
        context.coordinator.hostingController.rootView = content
    }

    static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
        scrollView.delegate = nil
        scrollView.panGestureRecognizer.removeTarget(coordinator, action: nil)
        coordinator.stopObservingKeyboard()
        coordinator.hostingController.view.removeFromSuperview()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            contentKey: contentKey,
            content: content,
            bottomInset: bottomInset,
            onPullDrag: onPullDrag,
            onPullEnd: onPullEnd
        )
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let hostingController: UIHostingController<Content>
        var contentKey: String
        var restingBottomInset: CGFloat
        var onPullDrag: (CGFloat) -> Void
        var onPullEnd: (CGFloat) -> Void
        weak var scrollView: UIScrollView?

        private var isPulling = false
        private var pullStartTranslation: CGFloat = 0
        private var keyboardOverlap: CGFloat = 0
        private var keyboardObserver: NSObjectProtocol?

        init(
            contentKey: String,
            content: Content,
            bottomInset: CGFloat,
            onPullDrag: @escaping (CGFloat) -> Void,
            onPullEnd: @escaping (CGFloat) -> Void
        ) {
            self.contentKey = contentKey
            hostingController = UIHostingController(rootView: content)
            restingBottomInset = bottomInset
            self.onPullDrag = onPullDrag
            self.onPullEnd = onPullEnd
        }

        func applyBottomInset() {
            guard let scrollView else { return }
            let inset = max(restingBottomInset, keyboardOverlap)
            guard scrollView.contentInset.bottom != inset else { return }
            scrollView.contentInset.bottom = inset
            scrollView.verticalScrollIndicatorInsets.bottom = inset
        }

        // MARK: - keyboard

        /// the scroll view opts out of automatic adjustment, so the caption
        /// field keeps its room above the keyboard through a manual inset.
        func observeKeyboard() {
            keyboardObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let endFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?
                    .cgRectValue
                MainActor.assumeIsolated {
                    guard let self, let scrollView = self.scrollView,
                          scrollView.window != nil, let endFrame
                    else { return }
                    let local = scrollView.convert(endFrame, from: nil)
                    self.keyboardOverlap = max(0, scrollView.bounds.maxY - local.minY)
                    self.applyBottomInset()
                }
            }
        }

        func stopObservingKeyboard() {
            if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
            keyboardObserver = nil
        }

        // MARK: - pull collaboration

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if !isPulling, scrollView.isTracking, scrollView.contentOffset.y < 0 {
                // the finger pulled past the top: the panel takes over.
                isPulling = true
                pullStartTranslation = scrollView.panGestureRecognizer.translation(in: scrollView).y
            }
            if isPulling, scrollView.contentOffset.y != 0 {
                scrollView.contentOffset.y = 0
            }
        }

        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            // a release that was driving the panel must not also decelerate
            // the pinned content.
            if isPulling { targetContentOffset.pointee = .zero }
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let scrollView else { return }
            switch recognizer.state {
            case .changed:
                guard isPulling else { return }
                let delta = recognizer.translation(in: scrollView).y - pullStartTranslation
                if delta <= 0 {
                    // pushed back to fully open: the panel settles and the
                    // content scrolls again from exactly here.
                    isPulling = false
                    onPullDrag(0)
                    onPullEnd(0)
                } else {
                    onPullDrag(delta)
                }
            case .ended:
                guard isPulling else { return }
                isPulling = false
                onPullEnd(recognizer.velocity(in: scrollView).y)
            case .cancelled, .failed:
                guard isPulling else { return }
                isPulling = false
                onPullEnd(0)
            default:
                break
            }
        }
    }
}

/// invisible anchor that installs one vertical pan on the viewer's root
/// view. other pans in the viewer wait for it to fail, so a claimed vertical
/// drag can never page the horizontal strip sideways at the same time, while
/// refused directions fail at the recognition threshold and hand the touch
/// straight back to paging, zooming or dismissal.
private struct ViewerInfoPanRecognizer: UIViewRepresentable {
    let shouldBegin: (CGPoint, CGPoint) -> Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        context.coordinator.shouldBegin = shouldBegin
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        view.coordinator = context.coordinator
        context.coordinator.attachIfNeeded(from: view)
    }

    static func dismantleUIView(_ view: AnchorView, coordinator: Coordinator) {
        coordinator.detach()
        view.coordinator = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(shouldBegin: shouldBegin, onChanged: onChanged, onEnded: onEnded)
    }

    final class AnchorView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attachIfNeeded(from: self)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var shouldBegin: (CGPoint, CGPoint) -> Bool
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat) -> Void

        private var pan: UIPanGestureRecognizer?
        private weak var host: UIView?

        init(
            shouldBegin: @escaping (CGPoint, CGPoint) -> Bool,
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat) -> Void
        ) {
            self.shouldBegin = shouldBegin
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func attachIfNeeded(from anchor: AnchorView) {
            guard anchor.window != nil else {
                detach()
                return
            }
            // the nearest controller-backed ancestor spans the whole viewer
            // content. toolbars and pushed destinations live outside it, so
            // their touches never reach this recognizer.
            var responder: UIResponder? = anchor.next
            while let current = responder, !(current is UIViewController) {
                responder = current.next
            }
            guard let target = (responder as? UIViewController)?.view else { return }
            if host === target, pan != nil { return }
            detach()
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.maximumNumberOfTouches = 1
            recognizer.delegate = self
            target.addGestureRecognizer(recognizer)
            pan = recognizer
            host = target
        }

        func detach() {
            if let pan { pan.view?.removeGestureRecognizer(pan) }
            pan = nil
            host = nil
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let host else { return }
            switch recognizer.state {
            case .began:
                recognizer.setTranslation(.zero, in: host)
            case .changed:
                onChanged(recognizer.translation(in: host).y)
            case .ended:
                onEnded(recognizer.velocity(in: host).y)
            case .cancelled, .failed:
                onEnded(0)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let host else { return false }
            return shouldBegin(pan.velocity(in: host), pan.location(in: host))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer
        }
    }
}

/// pixels a page asks for. every warm-up has to name the same size to land on
/// the request the page will make, so it lives next to both.
let pagePixelSize: CGFloat = 2048

struct AssetViewerScreen: View {
    /// pages either side of the current one kept warm. the pager mounts a page
    /// as it scrolls in, which on a quick swipe leaves no time for a download,
    /// so the neighbours are fetched while the current one is being looked at.
    private static let warmRadius = 2

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL
    @Environment(SessionStore.self) private var session

    let onChange: (AssetChange) -> Void
    let onDismissed: () -> Void
    let onRequestDismissal: (() -> Void)?
    let onSelectionChanged: (String) -> Void
    let onPageZoomChanged: (Bool) -> Void
    /// Mirrors whether the information sheet is absent, so the zoom
    /// transition only claims pans that belong to the unobstructed media.
    let onMediaAtTopChanged: (Bool) -> Void
    let presentationID: UUID
    let zoomNamespace: Namespace.ID?
    let isContextPreview: Bool
    /// set when the grid behind is an album, which adds removal to the menu.
    let album: AlbumContext?

    @State private var assets: [Asset]
    @State private var currentIndex: Int
    @State private var selectedAssetID: String?
    @State private var chromeVisible = true
    @State private var showInfo = false
    /// compact-width information presentation, 0 hidden through 1 presented.
    /// a drag writes it directly so the panel and the media track the finger.
    @State private var infoProgress: CGFloat = 0
    /// progress at the moment the active drag claimed the transition, nil
    /// while no drag drives it.
    @State private var infoDragBase: CGFloat?
    /// true while a release or toggle animation is still moving the panel.
    /// keeps the panel mounted through a closing settle and marks that the
    /// on-screen value differs from the settled state.
    @State private var infoSettling = false
    @State private var infoSettleGeneration: UInt64 = 0
    /// the panel's actual on-screen progress, read back from geometry every
    /// frame. a drag that begins mid-settle starts from here so it catches
    /// the panel where it visually is, without a jump.
    @State private var panelObservedProgress: CGFloat = 0
    /// full-bleed viewport mirrored from the media stage geometry.
    @State private var viewport = ViewerViewport()
    @State private var informationNavigationPath: [AssetInformationDestination] = []
    @State private var pendingInformationDestination: AssetInformationDestination?
    @State private var showAddToAlbum = false
    @State private var showShareLinks = false
    @State private var showSimilar = false
    @State private var showEditor = false
    @State private var showProfileCrop = false
    @State private var confirmation: ViewerConfirmation?
    @State private var confirmationSource: ViewerConfirmationSource = .toolbar
    @State private var airPlayTrigger = 0
    @State private var currentPageZoomed = false
    /// device copy of the current asset, when the backup index proves one exists.
    @State private var localIdentifier: String?
    /// server copy of a still-open local asset after it has been backed up.
    @State private var backedUpRemoteID: String?
    @State private var downloading = false
    @State private var mutatingAssetIDs: Set<String> = []
    @State private var optimisticRemovals: [String: ViewerRemoval] = [:]
    @State private var optimisticEdits: [String: AssetEditProjection] = [:]
    @State private var editCacheKeys: [String: String] = [:]
    @State private var toast: String?
    @State private var isDismissing = false
    @State private var didNotifyDismissal = false
    @State private var prefetcher = ThumbnailPrefetcher(targetPixelSize: pagePixelSize)
    @State private var playback = VideoPlayback()

    init(
        assets: [Asset],
        initialIndex: Int,
        presentationID: UUID,
        zoomNamespace: Namespace.ID? = nil,
        isContextPreview: Bool = false,
        album: AlbumContext? = nil,
        onRequestDismissal: (() -> Void)? = nil,
        onSelectionChanged: @escaping (String) -> Void = { _ in },
        onPageZoomChanged: @escaping (Bool) -> Void = { _ in },
        onMediaAtTopChanged: @escaping (Bool) -> Void = { _ in },
        onDismissed: @escaping () -> Void,
        onChange: @escaping (AssetChange) -> Void
    ) {
        let safeIndex = assets.indices.contains(initialIndex) ? initialIndex : 0
        _assets = State(initialValue: assets)
        _currentIndex = State(initialValue: safeIndex)
        _selectedAssetID = State(initialValue: assets.indices.contains(safeIndex) ? assets[safeIndex].id : nil)
        self.presentationID = presentationID
        self.zoomNamespace = zoomNamespace
        self.isContextPreview = isContextPreview
        self.album = album
        self.onRequestDismissal = onRequestDismissal
        self.onSelectionChanged = onSelectionChanged
        self.onPageZoomChanged = onPageZoomChanged
        self.onMediaAtTopChanged = onMediaAtTopChanged
        self.onDismissed = onDismissed
        self.onChange = onChange
    }

    private var current: Asset? {
        assets.indices.contains(currentIndex) ? assets[currentIndex] : nil
    }

    private var serverAssetID: String? {
        guard let current else { return nil }
        return current.isLocal ? backedUpRemoteID : current.id
    }

    private var actionAvailability: AssetActionAvailability? {
        guard let current else { return nil }
        return AssetActionAvailability(
            asset: current,
            ownsAsset: current.isLocal || ownsCurrent,
            localRemoteIdentifier: backedUpRemoteID,
            pairedLocalIdentifier: current.isLocal ? current.localIdentifier : localIdentifier
        )
    }

    /// mutations are only offered on assets the signed-in user owns. an
    /// unknown user - offline restore - is treated as the owner, best effort.
    private var ownsCurrent: Bool {
        guard let asset = current else { return false }
        guard let userID = session.user?.id else { return true }
        return asset.ownerId == userID
    }

    /// the server takes a removal from the album's owner or from the owner of
    /// the photo, and the web client offers it to exactly those two.
    private var canRemoveFromAlbum: Bool {
        guard let album, let asset = current, !asset.isLocal else { return false }
        guard let userID = session.user?.id else { return true }
        return asset.ownerId == userID || album.ownerID == userID
    }

    @ViewBuilder var body: some View {
        // zooming out targets the currently paged asset's tile when visible.
        if let zoomNamespace, !reduceMotion {
            core
                .id(presentationID)
                .navigationTransition(.zoom(sourceID: current?.id ?? "", in: zoomNamespace))
        } else {
            core.id(presentationID)
        }
    }

    private var core: some View {
        NavigationStack(path: $informationNavigationPath) {
            ZStack(alignment: .bottom) {
                GeometryReader { geometry in
                    mediaStage(size: geometry.size)
                        .onGeometryChange(for: ViewerViewport.self) { proxy in
                            ViewerViewport(
                                size: proxy.size,
                                bottomInset: proxy.safeAreaInsets.bottom
                            )
                        } action: { viewport = $0 }
                }
                .ignoresSafeArea()
                .safeAreaBar(edge: .bottom) {
                    if !isContextPreview, chromeVisible, !showInfo,
                       infoDragBase == nil, infoProgress == 0, let current,
                       current.isVideo, playback.ownerID == current.id, playback.player != nil {
                        VideoControlsBar(playback: playback)
                            .padding(.bottom, 4)
                            .transition(.opacity)
                    }
                }

                if horizontalSizeClass != .regular {
                    informationPanel
                }
            }
            .toolbar { toolbarContent }
            .toolbarVisibility(
                !isContextPreview && chromeVisible && !showInfo && infoDragBase == nil
                    ? .visible : .hidden,
                for: .navigationBar
            )
            .toolbarVisibility(
                !isContextPreview && chromeVisible && !showInfo && infoDragBase == nil
                    ? .visible : .hidden,
                for: .bottomBar
            )
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar, .bottomBar)
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
            .navigationBarTitleDisplayMode(.inline)
            .tint(.white)
            .navigationDestination(for: AssetInformationDestination.self) { destination in
                informationDestinationView(destination)
                    .tint(.accentColor)
                    .toolbarBackgroundVisibility(.automatic, for: .navigationBar)
                    .toolbarColorScheme(nil, for: .navigationBar)
            }
            .onChange(of: showInfo, initial: true) { _, _ in
                reportMediaAtTop()
            }
            .onChange(of: informationNavigationPath) {
                reportMediaAtTop()
            }
            .onChange(of: pendingInformationDestination) {
                reportMediaAtTop()
            }
            .onChange(of: horizontalSizeClass) {
                // presentation style swaps with the size class, so the panel
                // progress resyncs to whichever surface owns information now.
                infoProgress = showInfo && horizontalSizeClass != .regular ? 1 : 0
            }
        }
        .statusBarHidden(isContextPreview || !chromeVisible)
        .allowsHitTesting(!isContextPreview && !isDismissing)
        .onAppear {
            if let selectedAssetID { onSelectionChanged(selectedAssetID) }
        }
        .onChange(of: selectedAssetID) { _, id in
            guard let id, let index = assets.firstIndex(where: { $0.id == id }) else { return }
            currentIndex = index
            currentPageZoomed = false
            onSelectionChanged(id)
            onPageZoomChanged(false)
        }
        .onDisappear {
            prefetcher.cancel()
            guard !didNotifyDismissal else { return }
            didNotifyDismissal = true
            currentPageZoomed = false
            onPageZoomChanged(false)
            onDismissed()
        }
        .sheet(isPresented: regularInformationPresented, onDismiss: openPendingInformationDestination) {
            if let current {
                AssetInformationSheet(
                    asset: current,
                    serverAssetID: serverAssetID,
                    onDateAdjusted: applyDateAdjustment,
                    onAlbumAdded: { toast = $0 },
                    onOpenPerson: { queueInformationDestination(.person($0)) },
                    onOpenAlbum: { queueInformationDestination(.album($0)) }
                )
            }
        }
        .sheet(isPresented: $showAddToAlbum) {
            if let serverAssetID {
                AddToAlbumSheet(assetIDs: [serverAssetID]) { message in
                    toast = message
                }
            }
        }
        .sheet(isPresented: $showShareLinks) {
            if let serverAssetID {
                ShareLinksSheet(target: .assets([serverAssetID]))
            }
        }
        .sheet(isPresented: $showSimilar) {
            if let current {
                NavigationStack {
                    SearchResultsScreen(
                        title: "Similar Photos",
                        baseFilter: {
                            var filter = SearchFilter()
                            filter.queryAssetID = current.id
                            return filter
                        }(),
                        emptyIcon: "sparkle.magnifyingglass",
                        emptyMessage: "No similar photos"
                    )
                }
            }
        }
        .fullScreenCover(isPresented: $showEditor) {
            if let current {
                let editedID = current.id
                AssetEditScreen(
                    asset: current,
                    onProjected: projectEdit,
                    onReverted: { revertEdit(assetID: editedID, operationID: $0) },
                    onCommitted: { operationID, detail in
                        commitEdit(assetID: editedID, operationID: operationID, detail: detail)
                    },
                    onFinished: { _ in }
                )
            }
        }
        .fullScreenCover(isPresented: $showProfileCrop) {
            if let current {
                ProfilePictureCropScreen(asset: current) { message in
                    toast = message
                }
            }
        }
        .task(id: current?.id) {
            warmNeighbours()
            localIdentifier = nil
            backedUpRemoteID = nil
            guard let asset = current, let backup = session.backup else { return }
            if let localID = asset.localIdentifier {
                localIdentifier = localID
                let remoteID = await backup.remoteIdentifier(forLocal: localID)
                guard !Task.isCancelled, current?.id == asset.id else { return }
                backedUpRemoteID = remoteID
                return
            }
            let identifier = await backup.localIdentifier(forRemote: asset.id)
            guard !Task.isCancelled, current?.id == asset.id else { return }
            localIdentifier = identifier
        }
        .overlay(alignment: .top) {
            if let toast {
                ToastBanner(text: toast) { self.toast = nil }
            }
        }
    }

    private func mediaStage(size: CGSize) -> some View {
        ZStack {
            Color(uiColor: chromeVisible ? .systemBackground : .black)
                .accessibilityIdentifier("asset-viewer")
                .accessibilityValue(selectedAssetID ?? "")

            AssetPager(
                assets: assets,
                selection: $selectedAssetID,
                mutesVideo: isContextPreview,
                playback: playback,
                infoProgress: horizontalSizeClass == .regular ? 0 : infoProgress,
                viewport: size,
                optimisticEdits: optimisticEdits,
                editCacheKeys: editCacheKeys
            ) { id, isZoomed in
                guard id == selectedAssetID else { return }
                currentPageZoomed = isZoomed
                onPageZoomChanged(isZoomed)
            }
            .scrollEdgeEffectHidden(true, for: .top)
            .onTapGesture {
                // photos closes an open information panel from a tap on the
                // media before anything else.
                if horizontalSizeClass != .regular, showInfo {
                    setInfoVisible(false)
                    return
                }
                withAnimation(reduceMotion ? .linear(duration: 0.12) : .smooth(duration: 0.2)) {
                    chromeVisible.toggle()
                }
            }
            .simultaneousGesture(infoSwipeGesture)

            // compact width drives the information transition through this
            // exclusive uikit pan instead of a swiftui gesture.
            ViewerInfoPanRecognizer(
                shouldBegin: shouldBeginInfoPan,
                onChanged: { driveInfoDrag(translationY: $0) },
                onEnded: { endInfoDrag(velocityY: $0) }
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)

            AirPlayRoutePicker(trigger: $airPlayTrigger)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
    }

    // MARK: - prefetching

    /// downloads and decodes the pages around the current one so a swipe lands
    /// on pixels instead of a placeholder. videos are skipped - their page
    /// streams from the server and never asks for a still.
    private func warmNeighbours() {
        guard assets.indices.contains(currentIndex) else { return prefetcher.cancel() }
        let lower = max(0, currentIndex - Self.warmRadius)
        let upper = min(assets.count - 1, currentIndex + Self.warmRadius)

        var remote: Set<URL> = []
        var local: Set<String> = []
        for asset in assets[lower...upper] where !asset.isVideo {
            if let localIdentifier = asset.localIdentifier ?? session.backup?.localIdentifierByRemoteId[asset.id] {
                local.insert(localIdentifier)
            } else if let client = session.client {
                remote.insert(
                    client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: asset.thumbhash)
                )
            }
        }
        prefetcher.warm(remote: remote, local: local)
    }

    private func toggleInfo() {
        setInfoVisible(!showInfo)
    }

    private func setInfoVisible(_ visible: Bool) {
        guard showInfo != visible else { return }
        guard !visible || !currentPageZoomed else { return }
        showInfo = visible
        guard horizontalSizeClass != .regular else { return }
        animateInfo(
            to: visible ? 1 : 0,
            animation: reduceMotion ? .linear(duration: 0.15) : .smooth(duration: 0.35)
        )
    }

    /// the native floating sheet serves regular width only. compact width
    /// renders the in-hierarchy panel instead.
    private var regularInformationPresented: Binding<Bool> {
        Binding(
            get: { showInfo && horizontalSizeClass == .regular },
            set: { value in
                showInfo = value
                if !value { infoProgress = 0 }
            }
        )
    }

    private func applyDateAdjustment(_ assetID: String, _ fileCreatedAt: Date, _ offsetHours: Double) {
        guard let index = assets.firstIndex(where: { $0.id == assetID }) else { return }
        assets[index].fileCreatedAt = fileCreatedAt
        assets[index].localOffsetHours = offsetHours
    }

    private func queueInformationDestination(_ destination: AssetInformationDestination) {
        chromeVisible = true
        if horizontalSizeClass == .regular {
            pendingInformationDestination = destination
            onMediaAtTopChanged(false)
            showInfo = false
        } else {
            // the panel is part of this hierarchy, so the destination pushes
            // right over it and pops back to it intact.
            informationNavigationPath.append(destination)
            reportMediaAtTop()
        }
    }

    private func openPendingInformationDestination() {
        guard let destination = pendingInformationDestination else { return }
        informationNavigationPath.append(destination)
        pendingInformationDestination = nil
        reportMediaAtTop()
    }

    private func reportMediaAtTop() {
        onMediaAtTopChanged(
            !showInfo
                && infoProgress == 0
                && infoDragBase == nil
                && pendingInformationDestination == nil
                && informationNavigationPath.isEmpty
        )
    }

    // MARK: - interactive information transition

    /// fluid-interfaces mechanics: the drag maps one to one onto the panel's
    /// travel, release projects the momentum to pick a side and the settle
    /// spring inherits the finger's velocity, so the surface tracks in real
    /// time and can be caught mid-flight without a jump.

    private func driveInfoDrag(translationY: CGFloat) {
        guard viewport.size.height > 0 else { return }
        let travel = AssetViewerPageLayout.informationPanelTravel(viewportHeight: viewport.size.height)
        if infoDragBase == nil {
            // a settling panel is grabbed where it visually is, an at-rest
            // one at its settled state. the claim is animated so chrome and
            // video controls fade away while tracking begins - the tracking
            // writes themselves stay unanimated to follow the finger exactly.
            let base = infoSettling ? min(1, max(0, panelObservedProgress)) : infoProgress
            infoSettleGeneration &+= 1
            infoSettling = false
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                infoDragBase = base
            }
            reportMediaAtTop()
        }
        guard let base = infoDragBase else { return }
        var transaction = Transaction()
        transaction.isContinuous = true
        withTransaction(transaction) {
            infoProgress = min(1, max(0, base - translationY / travel))
        }
    }

    private func endInfoDrag(velocityY: CGFloat) {
        guard infoDragBase != nil, viewport.size.height > 0 else { return }
        infoDragBase = nil
        let travel = AssetViewerPageLayout.informationPanelTravel(viewportHeight: viewport.size.height)
        let progressVelocity = -velocityY / travel
        // where the finger's momentum would coast to with the standard
        // scroll deceleration rate decides the resting side.
        let projected = infoProgress + progressVelocity * 0.499
        let target: CGFloat = projected > 0.5 ? 1 : 0
        let delta = target - infoProgress
        let initialVelocity = abs(delta) > 0.001 ? max(-30, min(30, progressVelocity / delta)) : 0
        showInfo = target == 1
        animateInfo(
            to: target,
            animation: reduceMotion
                ? .linear(duration: 0.15)
                : .interpolatingSpring(stiffness: 320, damping: 32, initialVelocity: initialVelocity)
        )
        reportMediaAtTop()
    }

    /// animated settle with completion bookkeeping. the generation guards
    /// against an interrupted settle clearing the flag of the one that
    /// replaced it.
    private func animateInfo(to target: CGFloat, animation: Animation?) {
        infoSettleGeneration &+= 1
        let generation = infoSettleGeneration
        infoSettling = true
        withAnimation(animation) {
            infoProgress = target
        } completion: {
            guard infoSettleGeneration == generation else { return }
            infoSettling = false
        }
    }

    @ViewBuilder private func informationDestinationView(
        _ destination: AssetInformationDestination
    ) -> some View {
        switch destination {
        case .person(let person):
            PersonScreen(person: person)
        case .album(let album):
            AlbumDetailScreen(
                album: album,
                onAlbumRestored: restoreInformationAlbum
            )
        }
    }

    private func restoreInformationAlbum(_ album: Album) {
        Task { @MainActor in
            // Let AlbumDetail's optimistic pop finish before replaying the
            // failed command's destination into this viewer-owned stack.
            await Task.yield()
            guard !informationNavigationPath.contains(where: { destination in
                guard case .album(let current) = destination else { return false }
                return current.id == album.id
            }) else { return }
            informationNavigationPath.append(.album(album))
        }
    }

    /// gate for the exclusive media pan: a clearly vertical drag on the
    /// unobstructed media, pointing somewhere the transition can go. refused
    /// pans fail instantly and leave paging, zooming and dismissal untouched.
    private func shouldBeginInfoPan(velocity: CGPoint, location: CGPoint) -> Bool {
        guard horizontalSizeClass != .regular, !isContextPreview else { return false }
        guard !currentPageZoomed, informationNavigationPath.isEmpty else { return false }
        let height = viewport.size.height
        guard height > 0 else { return false }
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        let travel = AssetViewerPageLayout.informationPanelTravel(viewportHeight: height)
        let progress = infoSettling ? min(1, max(0, panelObservedProgress)) : infoProgress
        // the panel owns everything below its top edge through its own
        // scroll collaboration and grabber.
        guard location.y < height - travel * progress else { return false }
        if showInfo || infoProgress > 0 {
            return velocity.y > 0
        }
        return velocity.y < 0
    }

    /// regular width keeps the original swipe-to-open commit - the floating
    /// sheet cannot track a finger there. compact width is driven by the
    /// exclusive uikit pan instead.
    private var infoSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard horizontalSizeClass == .regular else { return }
                guard !currentPageZoomed, !showInfo else { return }
                let upwardDistance = -value.translation.height
                guard upwardDistance > 60,
                      upwardDistance > abs(value.translation.width)
                else { return }
                setInfoVisible(true)
            }
    }

    /// compact information surface pinned under the media stage. its offset,
    /// the media transform and the panel geometry all derive from the same
    /// progress value, so the two views adapt together frame by frame.
    @ViewBuilder private var informationPanel: some View {
        let travel = AssetViewerPageLayout.informationPanelTravel(viewportHeight: viewport.size.height)
        let panelVisible = showInfo || infoDragBase != nil || infoProgress > 0 || infoSettling
        if panelVisible, viewport.size.height > 0, let current {
            AssetInformationPanel(
                asset: current,
                serverAssetID: serverAssetID,
                bottomInset: viewport.bottomInset,
                onDateAdjusted: applyDateAdjustment,
                onAlbumAdded: { toast = $0 },
                onOpenPerson: { queueInformationDestination(.person($0)) },
                onOpenAlbum: { queueInformationDestination(.album($0)) },
                onPullDrag: { driveInfoDrag(translationY: $0) },
                onPullEnd: { endInfoDrag(velocityY: $0) }
            )
            .frame(height: travel, alignment: .top)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemBackground))
            .clipShape(.rect(topLeadingRadius: 24, topTrailingRadius: 24))
            .shadow(color: .black.opacity(0.18), radius: 16, y: -2)
            .overlay(alignment: .top) { informationGrabber }
            // measured inside the offset effect, which applies to descendant
            // geometry frame by frame even mid-animation. a new drag reads
            // this back to catch a settling panel where it actually is.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .global).minY
            } action: { top in
                guard travel > 0 else { return }
                let observed = (viewport.size.height - top) / travel
                panelObservedProgress = observed < 0.004 ? 0 : min(1, observed)
            }
            .offset(y: viewport.bottomInset + travel * (1 - infoProgress))
        }
    }

    /// grabber strip along the panel's top edge. dragging it drives the same
    /// transition the media drag does, in either direction.
    private var informationGrabber: some View {
        Capsule()
            .fill(.tertiary)
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 26, alignment: .center)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        driveInfoDrag(translationY: value.translation.height)
                    }
                    .onEnded { value in
                        endInfoDrag(velocityY: value.velocity.height)
                    }
            )
    }

    // MARK: - chrome

    /// Native toolbar placements own Dynamic Island, status-bar and home-
    /// indicator clearance and supply the platform's standard hit targets.
    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                requestDismissal()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .accessibilityIdentifier("viewer-close")
        }

        ToolbarItem(placement: .principal) {
            if let current {
                titlePill(current)
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if let current {
                backupStatusControl(current)
            }
            moreMenu
                .accessibilityIdentifier("viewer-menu")
        }

        if let current {
            if current.isLocal {
                localToolbarItems(current)
            } else if current.isTrashed {
                trashedToolbarItems
            } else {
                remoteToolbarItems(current)
            }
        }
    }

    /// Photos-style placement: share stands alone on the left, the common
    /// nondestructive controls form the center cluster, and delete stays at the
    /// far right with explicit device/everywhere choices.
    @ToolbarContentBuilder private func remoteToolbarItems(_ current: Asset) -> some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            if let client = session.client {
                ShareLink(
                    item: SharedAssetFile(client: client, asset: current),
                    preview: SharePreview(current.localDate.formatted(date: .abbreviated, time: .omitted))
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityIdentifier("viewer-share")
            }
        }

        ToolbarSpacer(.flexible, placement: .bottomBar)

        if actionAvailability?.canFavorite == true {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    Task { await toggleFavorite() }
                } label: {
                    Image(systemName: current.isFavorite ? "heart.fill" : "heart")
                        .contentTransition(.symbolEffect(.replace))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: current.isFavorite)
                }
                .accessibilityIdentifier("viewer-favorite")
                .disabled(mutatingAssetIDs.contains(current.id))
            }
            ToolbarSpacer(.fixed, placement: .bottomBar)
        }

        ToolbarItem(placement: .bottomBar) {
            Button {
                toggleInfo()
            } label: {
                Image(systemName: showInfo ? "info.circle.fill" : "info.circle")
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityIdentifier("viewer-info")
        }

        if actionAvailability?.canEdit == true {
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button {
                    showEditor = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityIdentifier("viewer-edit")
                .disabled(optimisticEdits[current.id] != nil)
            }
        }

        if actionAvailability?.canDeleteFromDevice == true
            || actionAvailability?.canTrashEverywhere == true {
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                deleteMenu
            }
        }
    }

    /// trashed assets offer restore and permanent delete, like the photos
    /// app's recently deleted album.
    @ToolbarContentBuilder private var trashedToolbarItems: some ToolbarContent {
        if actionAvailability?.canRestore == true {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    Task { await restore() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .accessibilityIdentifier("viewer-restore")
            }
        }

        if actionAvailability?.canRestore == true,
           actionAvailability?.canDeletePermanently == true {
            ToolbarSpacer(.flexible, placement: .bottomBar)
        }

        if actionAvailability?.canDeletePermanently == true {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    ask(.deletePermanently, from: .toolbar)
                } label: {
                    Image(systemName: "trash")
                }
                .modifier(confirmationDialog(from: .toolbar))
            }
        }
    }

    /// device-only assets can be shared, inspected and deleted locally;
    /// server actions come after they are backed up.
    @ToolbarContentBuilder private func localToolbarItems(_ current: Asset) -> some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            if let localId = current.localIdentifier {
                ShareLink(
                    item: LocalSharedAssetFile(localIdentifier: localId),
                    preview: SharePreview(current.localDate.formatted(date: .abbreviated, time: .omitted))
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }

        ToolbarSpacer(.flexible, placement: .bottomBar)

        ToolbarItem(placement: .bottomBar) {
            Button {
                toggleInfo()
            } label: {
                Image(systemName: showInfo ? "info.circle.fill" : "info.circle")
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityIdentifier("viewer-info")
        }

        ToolbarSpacer(.flexible, placement: .bottomBar)

        ToolbarItem(placement: .bottomBar) {
            deleteMenu
        }
    }

    private var deleteMenu: some View {
        Menu {
            if actionAvailability?.canDeleteFromDevice == true {
                Button(role: .destructive) {
                    ask(.deleteFromDevice, from: .toolbar)
                } label: {
                    Label("Delete from This Device", systemImage: "iphone.slash")
                }
                .accessibilityIdentifier("viewer-delete-device")
            }
            if actionAvailability?.canTrashEverywhere == true {
                Button(role: .destructive) {
                    ask(.trash, from: .toolbar)
                } label: {
                    Label(
                        localIdentifier == nil ? "Move to Trash" : "Move to Trash Everywhere",
                        systemImage: "trash"
                    )
                }
                .accessibilityIdentifier("viewer-trash")
            }
        } label: {
            Image(systemName: "trash")
        }
        .accessibilityLabel("Delete")
        .modifier(confirmationDialog(from: .toolbar))
    }

    private var moreMenu: some View {
        Menu {
            if let current {
                Section {
                    Button { toggleInfo() } label: {
                        Label(showInfo ? "Hide Info" : "Show Info", systemImage: "info.circle")
                    }
                    if actionAvailability?.canEdit == true {
                        Button { showEditor = true } label: {
                            Label("Edit", systemImage: "slider.horizontal.3")
                        }
                        .accessibilityIdentifier("viewer-edit")
                        .disabled(optimisticEdits[current.id] != nil)
                    }
                    if actionAvailability?.canAddToAlbum == true {
                        Button { showAddToAlbum = true } label: {
                            Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
                        }
                        .accessibilityIdentifier("viewer-add-to-album")
                    }
                    if canRemoveFromAlbum {
                        Button { Task { await removeFromAlbum() } } label: {
                            Label("Remove from Album", systemImage: "rectangle.stack.badge.minus")
                        }
                        .accessibilityIdentifier("viewer-remove-from-album")
                    }
                    if serverAssetID != nil, (current.isLocal || ownsCurrent) {
                        Button { showShareLinks = true } label: {
                            Label("Share Link", systemImage: "link")
                        }
                        .accessibilityIdentifier("viewer-share-link")
                    }
                }

                if current.isLocal, serverAssetID != nil {
                    Section {
                        Button { Task { await openInBrowser() } } label: {
                            Label("Open in Browser", systemImage: "safari")
                        }
                    }
                } else if !current.isTrashed {
                    Section {
                        Button { airPlayTrigger += 1 } label: {
                            Label("Cast", systemImage: "airplay.video")
                        }
                        if session.features?.smartSearch == true {
                            Button { showSimilar = true } label: {
                                Label("View Similar", systemImage: "sparkle.magnifyingglass")
                            }
                            .accessibilityIdentifier("viewer-similar")
                        }
                        if current.isImage, ownsCurrent {
                            Button { showProfileCrop = true } label: {
                                Label("Set as Profile Picture", systemImage: "person.crop.circle")
                            }
                            .disabled(session.isProfileImageMutationInFlight)
                        }
                        if actionAvailability?.canDownload == true {
                            if downloading {
                                Button {} label: {
                                    Label("Downloading…", systemImage: "arrow.down.circle.dotted")
                                }
                                .disabled(true)
                            } else {
                                Button { Task { await download() } } label: {
                                    Label("Download to Device", systemImage: "arrow.down.circle")
                                }
                                .accessibilityIdentifier("viewer-download")
                            }
                        }
                        Button { Task { await openInBrowser() } } label: {
                            Label("Open in Browser", systemImage: "safari")
                        }
                    }
                }

                if actionAvailability?.canArchive == true {
                    Section {
                        Button { Task { await toggleArchive() } } label: {
                            Label(
                                current.visibility == .archive ? "Unarchive" : "Archive",
                                systemImage: current.visibility == .archive ? "tray.and.arrow.up" : "archivebox"
                            )
                        }
                    }
                }

                if actionAvailability?.canDeleteFromDevice == true
                    || actionAvailability?.canTrashEverywhere == true
                    || actionAvailability?.canDeletePermanently == true {
                    Section {
                        if actionAvailability?.canDeleteFromDevice == true {
                            Button(role: .destructive) {
                                ask(.deleteFromDevice, from: .menu)
                            } label: {
                                Label("Delete from This Device", systemImage: "iphone.slash")
                            }
                            .accessibilityIdentifier("viewer-delete-device")
                        }
                        if actionAvailability?.canTrashEverywhere == true {
                            Button(role: .destructive) {
                                ask(.trash, from: .menu)
                            } label: {
                                Label(
                                    localIdentifier == nil ? "Move to Trash" : "Move to Trash Everywhere",
                                    systemImage: "trash"
                                )
                            }
                            .accessibilityIdentifier("viewer-delete")
                        }
                        if actionAvailability?.canDeletePermanently == true {
                            Button(role: .destructive) {
                                ask(.deletePermanently, from: .menu)
                            } label: {
                                Label("Delete Permanently", systemImage: "trash.slash")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        // the dialog anchors to the menu button, not to the vanished menu item.
        .modifier(confirmationDialog(from: .menu))
    }

    @ViewBuilder private func backupStatusControl(_ current: Asset) -> some View {
        if let localID = current.localIdentifier {
            switch session.backup?.uploadStates[localID] {
            case .uploading(let fraction):
                ProgressView(value: fraction)
                    .progressViewStyle(.circular)
                    .frame(width: 24, height: 24)
                    .accessibilityLabel("Backing up")
                    .accessibilityValue("\(Int(fraction * 100)) percent")
            case .failed:
                Button { Task { await backUpCurrent() } } label: {
                    Image(systemName: "exclamationmark.icloud")
                }
                .accessibilityLabel("Backup failed. Try again")
            case nil:
                if current.isLocalBackedUp || backedUpRemoteID != nil {
                    Menu {
                        Button {} label: {
                            Label("Backed Up", systemImage: "checkmark.icloud")
                        }
                        .disabled(true)
                        if serverAssetID != nil {
                            Button { showAddToAlbum = true } label: {
                                Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
                            }
                        }
                    } label: {
                        Image(systemName: "checkmark.icloud")
                    }
                    .accessibilityLabel("Backed up")
                } else {
                    Button { Task { await backUpCurrent() } } label: {
                        Image(systemName: "icloud.slash")
                    }
                    .accessibilityLabel("Not backed up. Back up now")
                    .accessibilityIdentifier("viewer-back-up")
                }
            }
        } else if !current.isTrashed {
            Menu {
                Button {} label: {
                    Label("Backed Up", systemImage: "checkmark.icloud")
                }
                .disabled(true)
                if actionAvailability?.canDownload == true {
                    Button { Task { await download() } } label: {
                        Label(
                            downloading ? "Downloading…" : "Download to Device",
                            systemImage: downloading ? "arrow.down.circle.dotted" : "arrow.down.circle"
                        )
                    }
                    .disabled(downloading)
                }
                if actionAvailability?.canAddToAlbum == true {
                    Button { showAddToAlbum = true } label: {
                        Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
                    }
                }
            } label: {
                Image(systemName: "checkmark.icloud")
            }
            .accessibilityLabel("Backed up")
        }
    }

    /// floating glass title: the place when known, the relative day and time.
    private func titlePill(_ current: Asset) -> some View {
        let date = current.localDate
        let day = relativeDayLabel(for: date) ?? date.formatted(dateTitleFormat(for: date))
        let time = date.formatted(.dateTime.hour().minute().utc())
        let place = current.city ?? current.country
        return VStack(spacing: 1) {
            Text(place ?? day)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(place == nil ? time : "\(day), \(time)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 136, idealWidth: 156, maxWidth: 210)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }

    /// today and yesterday compare the asset's local wall clock against the
    /// device's, both mapped into the utc calendar space the viewer formats in.
    private func relativeDayLabel(for date: Date) -> String? {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let todayWall = Date().addingTimeInterval(TimeInterval(TimeZone.current.secondsFromGMT()))
        if calendar.isDate(date, inSameDayAs: todayWall) { return String(localized: "Today") }
        if let yesterdayWall = calendar.date(byAdding: .day, value: -1, to: todayWall),
           calendar.isDate(date, inSameDayAs: yesterdayWall) {
            return String(localized: "Yesterday")
        }
        return nil
    }

    /// photos-style title: day and month, with the year once it differs from
    /// the current one.
    private func dateTitleFormat(for date: Date) -> Date.FormatStyle {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day().utc()
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return style
        }
        return style.year()
    }

    // MARK: - confirmation dialogs

    private func ask(_ kind: ViewerConfirmation, from source: ViewerConfirmationSource) {
        confirmationSource = source
        confirmation = kind
    }

    private func confirmationDialog(from source: ViewerConfirmationSource) -> some ViewModifier {
        ViewerConfirmationDialog(
            isPresented: Binding(
                get: { confirmation != nil && confirmationSource == source },
                set: { if !$0 { confirmation = nil } }
            ),
            title: confirmationTitle,
            message: confirmationMessage,
            actions: { confirmationActions }
        )
    }

    private var confirmationTitle: String {
        let noun = current?.isVideo == true ? "Video" : "Photo"
        switch confirmation {
        case .trash:
            return localIdentifier == nil
                ? "Move \(noun) to Trash?"
                : "Move \(noun) to Trash Everywhere?"
        case .deletePermanently: return "Delete \(noun) Permanently?"
        case .deleteFromDevice: return "Delete from This Device?"
        case nil: return ""
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .trash:
            if current?.isLocal == true {
                return serverAssetID == nil
                    ? "This photo is not backed up. It will be removed from your device photo library."
                    : "It will move to the server trash and the copy in your device photo library will be deleted."
            }
            return localIdentifier != nil
                ? "It will move to the server trash and the copy in your device photo library will be deleted."
                : "It will move to the server trash and can be restored from there."
        case .deletePermanently:
            return localIdentifier != nil
                ? "It will be permanently deleted from the server and from this device. This cannot be undone."
                : "It will be permanently deleted from the server. This cannot be undone."
        case .deleteFromDevice:
            if current?.isLocal == true, serverAssetID == nil {
                return "This photo is not backed up. It will be removed from your device photo library permanently."
            }
            return "The copy in your device photo library will be deleted. The server copy is kept."
        case nil:
            return ""
        }
    }

    @ViewBuilder private var confirmationActions: some View {
        switch confirmation {
        case .trash:
            Button(localIdentifier == nil ? "Move to Trash" : "Move to Trash Everywhere", role: .destructive) {
                Task { await trash() }
            }
            .accessibilityIdentifier("viewer-trash-confirm")
        case .deletePermanently:
            Button("Delete Permanently", role: .destructive) {
                Task { await deletePermanently() }
            }
        case .deleteFromDevice:
            Button("Delete from Device", role: .destructive) {
                Task { await deleteFromDevice() }
            }
            .accessibilityIdentifier("viewer-delete-device-confirm")
        case nil:
            EmptyView()
        }
        Button("Cancel", role: .cancel) {}
    }

    // MARK: - actions

    private func requestDismissal() {
        // UIKit-owned viewers dedupe and track cancellation in their controller
        // phase. Keeping this local latch set after a cancelled fluid zoom-out
        // would leave the restored viewer permanently unable to receive taps.
        if let onRequestDismissal {
            onRequestDismissal()
            return
        }
        guard !isDismissing else { return }
        isDismissing = true
        dismiss()
    }

    private func apply(_ change: AssetChange) {
        switch change {
        case .favorite(let id, let value):
            if let index = assets.firstIndex(where: { $0.id == id }) {
                assets[index].isFavorite = value
            }
        case .favoriteCommitted:
            break
        case .albumMembershipProjected, .albumMembershipCommitted, .albumMembershipReverted:
            break
        case .optimisticRemoval(let id), .removed(let id):
            if let index = assets.firstIndex(where: { $0.id == id }) {
                assets.remove(at: index)
                if assets.isEmpty {
                    requestDismissal()
                } else if currentIndex >= assets.count {
                    currentIndex = assets.count - 1
                    selectedAssetID = assets[currentIndex].id
                }
            }
        case .removalCommitted, .removalReverted:
            break
        case .localDeleted:
            break
        case .edited(let id, let thumbhash):
            if let index = assets.firstIndex(where: { $0.id == id }), let thumbhash {
                assets[index].thumbhash = thumbhash
            }
            // the device copy is now the pre-edit original, so it stops
            // standing in for this asset anywhere in the app.
            session.backup?.noteRemoteEdits([id])
        }
        onChange(change)
    }

    private func projectEdit(_ projection: AssetEditProjection) {
        optimisticEdits[projection.assetID] = projection
    }

    private func revertEdit(assetID: String, operationID: UUID) {
        guard optimisticEdits[assetID]?.operationID == operationID else { return }
        optimisticEdits.removeValue(forKey: assetID)
    }

    private func commitEdit(assetID: String, operationID: UUID, detail: AssetDetail?) {
        guard optimisticEdits[assetID]?.operationID == operationID else { return }
        editCacheKeys[assetID] = detail?.thumbhash ?? operationID.uuidString
        optimisticEdits.removeValue(forKey: assetID)
        apply(.edited(assetID, thumbhash: detail?.thumbhash))
        toast = "Edits saved"
    }

    private func toggleFavorite() async {
        guard let client = session.client, let asset = current else { return }
        guard mutatingAssetIDs.insert(asset.id).inserted else { return }
        defer { mutatingAssetIDs.remove(asset.id) }
        let newValue = !asset.isFavorite
        apply(.favorite(asset.id, newValue))
        do {
            try await client.setFavorite(ids: [asset.id], newValue)
            apply(.favoriteCommitted(asset.id, newValue))
        } catch {
            apply(.favorite(asset.id, asset.isFavorite))
            ErrorToastCenter.shared.show("Couldn’t update the favorite", error: error)
        }
    }

    private func toggleArchive() async {
        guard let client = session.client, let asset = current else { return }
        guard mutatingAssetIDs.insert(asset.id).inserted else { return }
        defer { mutatingAssetIDs.remove(asset.id) }
        let visibility: AssetVisibility = asset.visibility == .archive ? .timeline : .archive
        beginOptimisticRemoval(asset)
        do {
            try await client.setVisibility(ids: [asset.id], visibility)
            commitOptimisticRemoval(asset.id)
        } catch {
            rollbackOptimisticRemoval(asset.id)
            ErrorToastCenter.shared.show("Couldn’t update the archive", error: error)
        }
    }

    /// takes the photo out of the album only - it stays in the library, which
    /// is why this needs no confirmation, matching the official mobile client.
    private func removeFromAlbum() async {
        guard let client = session.client, let album, let asset = current else { return }
        guard mutatingAssetIDs.insert(asset.id).inserted else { return }
        defer { mutatingAssetIDs.remove(asset.id) }
        onChange(.albumMembershipProjected(asset.id))
        beginOptimisticRemoval(asset)
        do {
            let results = try await client.removeAssets(albumID: album.id, ids: [asset.id])
            guard results.first(where: { $0.id == asset.id })?.success == true else {
                rollbackOptimisticRemoval(asset.id)
                onChange(.albumMembershipReverted(asset.id))
                ErrorToastCenter.shared.show("Couldn’t remove this photo from the album. The change was undone.")
                return
            }
            commitOptimisticRemoval(asset.id)
            onChange(.albumMembershipCommitted(asset.id))
            toast = "Removed from the album"
        } catch {
            rollbackOptimisticRemoval(asset.id)
            onChange(.albumMembershipReverted(asset.id))
            ErrorToastCenter.shared.show("Couldn’t remove this photo from the album", error: error)
        }
    }

    private func restore() async {
        guard let client = session.client, let asset = current else { return }
        guard mutatingAssetIDs.insert(asset.id).inserted else { return }
        defer { mutatingAssetIDs.remove(asset.id) }
        beginOptimisticRemoval(asset)
        do {
            try await client.restoreAssets(ids: [asset.id])
            commitOptimisticRemoval(asset.id)
        } catch {
            rollbackOptimisticRemoval(asset.id)
            ErrorToastCenter.shared.show("Couldn’t restore this photo", error: error)
        }
    }

    private func trash() async {
        guard let asset = current else { return }
        guard let serverAssetID else {
            await deleteLocalOnlyAsset()
            return
        }
        guard let client = session.client else { return }
        guard mutatingAssetIDs.insert(asset.id).inserted else { return }
        defer { mutatingAssetIDs.remove(asset.id) }
        if let localID = await resolveLocalIdentifier() {
            await deleteEverywhere(
                serverID: serverAssetID,
                sourceAssetID: asset.id,
                localIdentifier: localID,
                force: false
            )
            return
        }
        beginOptimisticRemoval(asset)
        do {
            try await client.trashAssets(ids: [serverAssetID])
            commitOptimisticRemoval(asset.id)
        } catch {
            rollbackOptimisticRemoval(asset.id)
            ErrorToastCenter.shared.show("Couldn’t move this photo to trash", error: error)
        }
    }

    private func deletePermanently() async {
        guard let client = session.client, let asset = current, let serverAssetID else { return }
        guard mutatingAssetIDs.insert(asset.id).inserted else { return }
        defer { mutatingAssetIDs.remove(asset.id) }
        if let localID = await resolveLocalIdentifier() {
            await deleteEverywhere(
                serverID: serverAssetID,
                sourceAssetID: asset.id,
                localIdentifier: localID,
                force: true
            )
            return
        }
        beginOptimisticRemoval(asset)
        do {
            try await client.trashAssets(ids: [serverAssetID], force: true)
            commitOptimisticRemoval(asset.id)
        } catch {
            rollbackOptimisticRemoval(asset.id)
            ErrorToastCenter.shared.show("Couldn’t delete this photo", error: error)
        }
    }

    /// the background lookup may still be in flight right after paging, and
    /// missing it would leave an orphaned copy on the device.
    private func resolveLocalIdentifier() async -> String? {
        if let localIdentifier { return localIdentifier }
        guard let asset = current else { return nil }
        if let localID = asset.localIdentifier {
            localIdentifier = localID
            return localID
        }
        guard let backup = session.backup else { return nil }
        let resolved = await backup.localIdentifier(forRemote: asset.id)
        if current?.id == asset.id { localIdentifier = resolved }
        return resolved
    }

    /// device first: declining the system dialog aborts with nothing changed.
    /// after the device copy is gone the index is updated immediately, even if
    /// the server call then fails.
    private func deleteEverywhere(
        serverID: String,
        sourceAssetID: String,
        localIdentifier: String,
        force: Bool
    ) async {
        guard let client = session.client,
              let removedAsset = assets.first(where: { $0.id == sourceAssetID })
        else { return }
        do {
            try await PhotoLibraryService.delete(localIdentifiers: [localIdentifier])
        } catch {
            if !PhotoLibraryService.isUserCancelled(error) {
                ErrorToastCenter.shared.show("Couldn’t delete from this device", error: error)
            }
            return
        }
        session.backup?.noteLocalDeletion([localIdentifier])
        self.localIdentifier = nil
        beginOptimisticRemoval(removedAsset)
        do {
            try await client.trashAssets(ids: [serverID], force: force)
            commitOptimisticRemoval(sourceAssetID)
        } catch {
            rollbackOptimisticRemoval(sourceAssetID)
            onChange(.localDeleted(sourceAssetID))
            ErrorToastCenter.shared.show(
                "Deleted from this device, but couldn’t delete the server copy",
                error: error
            )
        }
    }

    /// removes a device-only asset that has no server copy yet.
    private func deleteLocalOnlyAsset() async {
        guard let asset = current, let localId = asset.localIdentifier else { return }
        do {
            try await PhotoLibraryService.delete(localIdentifiers: [localId])
        } catch {
            if !PhotoLibraryService.isUserCancelled(error) {
                ErrorToastCenter.shared.show("Couldn’t delete from this device", error: error)
            }
            return
        }
        session.backup?.noteLocalDeletion([localId])
        onChange(.removed(asset.id))
        removeCurrent()
    }

    /// saves the server original into the photo library; the index pairing is
    /// recorded by the backup manager so the delete options appear right away.
    private func download() async {
        guard let asset = current, let backup = session.backup else { return }
        downloading = true
        defer { downloading = false }
        do {
            let localId = try await backup.download(asset: asset)
            if current?.id == asset.id { localIdentifier = localId }
            toast = "Saved to your photo library"
        } catch {
            ErrorToastCenter.shared.show("Couldn’t download this photo", error: error)
        }
    }

    private func backUpCurrent() async {
        guard let asset = current,
              let localID = asset.localIdentifier,
              let backup = session.backup
        else { return }
        do {
            let remoteID = try await backup.backUp(localIdentifier: localID)
            guard current?.id == asset.id else { return }
            backedUpRemoteID = remoteID
            assets[currentIndex].isLocalBackedUp = true
            toast = "Backed up"
        } catch {
            ErrorToastCenter.shared.show("Couldn’t back up this photo", error: error)
        }
    }

    private func deleteFromDevice() async {
        guard let asset = current, let localId = await resolveLocalIdentifier() else { return }
        do {
            try await PhotoLibraryService.delete(localIdentifiers: [localId])
        } catch {
            if !PhotoLibraryService.isUserCancelled(error) {
                ErrorToastCenter.shared.show("Couldn’t delete from this device", error: error)
            }
            return
        }
        session.backup?.noteLocalDeletion([localId])
        localIdentifier = nil
        if asset.isLocal {
            if serverAssetID == nil {
                onChange(.removed(asset.id))
            } else {
                onChange(.localDeleted(asset.id))
            }
            removeCurrent()
            return
        }
        onChange(.localDeleted(asset.id))
    }

    private func openInBrowser() async {
        guard let client = session.client, let serverAssetID else { return }
        let base = await client.serverWebURL()
        openURL(base.appending(path: "photos/\(serverAssetID)"))
    }

    private func beginOptimisticRemoval(_ asset: Asset) {
        guard optimisticRemovals[asset.id] == nil,
              let index = assets.firstIndex(where: { $0.id == asset.id })
        else { return }
        optimisticRemovals[asset.id] = ViewerRemoval(asset: asset, index: index)
        apply(.optimisticRemoval(asset.id))
    }

    private func commitOptimisticRemoval(_ id: String) {
        optimisticRemovals[id] = nil
        onChange(.removalCommitted(id))
    }

    private func rollbackOptimisticRemoval(_ id: String) {
        guard let removal = optimisticRemovals.removeValue(forKey: id) else { return }
        if !assets.contains(where: { $0.id == id }) {
            assets.insert(removal.asset, at: min(removal.index, assets.count))
            if selectedAssetID == nil || assets.count == 1 {
                currentIndex = min(removal.index, assets.count - 1)
                selectedAssetID = id
            }
        }
        onChange(.removalReverted(id))
    }

    private func removeCurrent() {
        guard assets.indices.contains(currentIndex) else { return }
        assets.remove(at: currentIndex)
        if assets.isEmpty {
            requestDismissal()
        } else {
            currentIndex = min(currentIndex, assets.count - 1)
            selectedAssetID = assets[currentIndex].id
        }
    }
}

// MARK: - toast

/// short-lived confirmation banner, photos style: unobtrusive capsule at the
/// top that fades on its own.
struct ToastBanner: View {
    let text: String
    let onDone: () -> Void

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task {
                try? await Task.sleep(for: .seconds(2.2))
                withAnimation(.smooth(duration: 0.3)) { onDone() }
            }
    }
}

// MARK: - airplay

/// invisible system route picker; bumping `trigger` opens the airplay sheet.
private struct AirPlayRoutePicker: UIViewRepresentable {
    @Binding var trigger: Int

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.alpha = 0.02
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        guard trigger != context.coordinator.lastTrigger else { return }
        context.coordinator.lastTrigger = trigger
        guard trigger > 0 else { return }
        DispatchQueue.main.async {
            for case let button as UIButton in view.subviews {
                button.sendActions(for: .touchUpInside)
                break
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastTrigger = 0
    }
}

// MARK: - pager

/// lazy horizontal pager. lazyhstack only materializes pages near the
/// viewport, so opening and closing the viewer costs o(visible) instead of
/// o(library) like the page style tabview, which froze the zoom transition.
private struct AssetPager: View {
    let assets: [Asset]
    @Binding var selection: String?
    let mutesVideo: Bool
    let playback: VideoPlayback
    let infoProgress: CGFloat
    let viewport: CGSize
    let optimisticEdits: [String: AssetEditProjection]
    let editCacheKeys: [String: String]
    let onZoomChanged: (String, Bool) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(assets) { asset in
                    AssetPage(
                        asset: asset,
                        isActive: asset.id == selection,
                        mutesVideo: mutesVideo,
                        playback: playback,
                        infoProgress: infoProgress,
                        viewport: viewport,
                        optimisticEdit: optimisticEdits[asset.id],
                        editCacheKey: editCacheKeys[asset.id]
                    ) { isZoomed in
                        onZoomChanged(asset.id, isZoomed)
                    }
                    .containerRelativeFrame([.horizontal, .vertical])
                    .clipped()
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $selection)
        .scrollIndicators(.hidden)
    }
}

// MARK: - single page

private struct AssetPage: View {
    @Environment(SessionStore.self) private var session
    let asset: Asset
    let isActive: Bool
    let mutesVideo: Bool
    let playback: VideoPlayback
    let infoProgress: CGFloat
    let viewport: CGSize
    let optimisticEdit: AssetEditProjection?
    let editCacheKey: String?
    let onZoomChanged: (Bool) -> Void

    /// photokit could not serve the device copy after all; the page falls back
    /// to the server for the rest of its life.
    @State private var localUnavailable = false

    /// full-size pixels already on the device beat a download of the same
    /// photo. the index only pairs assets whose server copy still matches.
    private var deviceIdentifier: String? {
        guard !localUnavailable else { return nil }
        return asset.localIdentifier ?? session.backup?.localIdentifierByRemoteId[asset.id]
    }

    var body: some View {
        // content mounts with the page, on the lazy stack's schedule - as it
        // scrolls in, not once the pager has settled on it. gating on the
        // selection instead built the hosting controller mid-swipe, which is
        // exactly when a stall shows. kept transparent so the screen backdrop
        // still fades during drag dismiss.
        // the information transition is a pure transform of the fit-rendered
        // page, never a relayout or content swap, so it can run every frame
        // of a drag without flicker.
        let transform = AssetViewerPageLayout.mediaTransform(
            ratio: asset.ratio,
            viewport: viewport,
            progress: infoProgress
        )
        ZStack {
            Color.clear
            pageContent
        }
        .scaleEffect(transform.scale)
        .offset(y: transform.offsetY)
    }

    @ViewBuilder private var pageContent: some View {
        if let optimisticEdit, let image = UIImage(data: optimisticEdit.imageData) {
            ZoomableScrollView(
                contentID: "\(asset.id)#edit-\(optimisticEdit.operationID)",
                onZoomChanged: onZoomChanged
            ) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        } else if asset.isVideo {
            VideoPlayerPage(
                asset: asset,
                deviceIdentifier: deviceIdentifier,
                isActive: isActive,
                forcesMute: mutesVideo,
                playback: playback,
                onZoomChanged: onZoomChanged
            )
        } else if let localId = deviceIdentifier {
            ZoomableScrollView(
                contentID: asset.id,
                onZoomChanged: onZoomChanged
            ) {
                LocalPhotoImage(
                    localIdentifier: localId,
                    targetPixelSize: pagePixelSize,
                    fallbackTargetPixelSize: 640,
                    contentMode: .fit,
                    onUnavailable: { localUnavailable = true }
                )
            }
        } else if let client = session.client {
            // the thumbhash cache key re-renders the page when edits land.
            let cacheKey = editCacheKey ?? asset.thumbhash
            ZoomableScrollView(
                contentID: "\(asset.id)#\(cacheKey ?? "")",
                onZoomChanged: onZoomChanged
            ) {
                RemoteImage(
                    url: client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: cacheKey),
                    targetPixelSize: pagePixelSize,
                    thumbhash: asset.thumbhash,
                    fallbackURL: client.thumbnailURL(assetID: asset.id, cacheKey: cacheKey),
                    fallbackTargetPixelSize: 640,
                    contentMode: .fit
                )
            }
        }
    }
}

// MARK: - zoom container

struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    let contentID: String
    let onZoomChanged: (Bool) -> Void
    @ViewBuilder let content: Content

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 6
        scrollView.minimumZoomScale = 1
        scrollView.bounces = true
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.isDirectionalLockEnabled = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        // a page at rest fills the frame and has nothing to pan, but its scroll
        // view still claims the touch and only hands it over once it decides it
        // cannot scroll. that hand-off is the lag before a flick pages or a
        // swipe down starts the dismissal, so panning is off until zoomed in.
        scrollView.panGestureRecognizer.isEnabled = false

        let hosted = context.coordinator.hostingController
        hosted.view.backgroundColor = .clear
        hosted.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(hosted.view)
        NSLayoutConstraint.activate([
            hosted.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hosted.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hosted.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hosted.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            hosted.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            hosted.view.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onZoomChanged = onZoomChanged
        guard context.coordinator.contentID != contentID else { return }
        context.coordinator.contentID = contentID
        context.coordinator.hostingController.rootView = content
        context.coordinator.resetZoomReporting()
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
        scrollView.panGestureRecognizer.isEnabled = false
    }

    static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
        scrollView.delegate = nil
        coordinator.onZoomChanged = { _ in }
        coordinator.hostingController.view.removeFromSuperview()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentID: contentID, content: content, onZoomChanged: onZoomChanged)
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let hostingController: UIHostingController<Content>
        var contentID: String
        var onZoomChanged: (Bool) -> Void
        private var lastReportedZoomed = false

        init(contentID: String, content: Content, onZoomChanged: @escaping (Bool) -> Void) {
            self.contentID = contentID
            hostingController = UIHostingController(rootView: content)
            self.onZoomChanged = onZoomChanged
        }

        func resetZoomReporting() {
            lastReportedZoomed = false
            onZoomChanged(false)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostingController.view
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let isZoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            scrollView.panGestureRecognizer.isEnabled = isZoomed
            guard isZoomed != lastReportedZoomed else { return }
            lastReportedZoomed = isZoomed
            onZoomChanged(isZoomed)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }

            let point = gesture.location(in: hostingController.view)
            let size = CGSize(
                width: scrollView.bounds.width / 2.5,
                height: scrollView.bounds.height / 2.5
            )
            let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
            scrollView.zoom(to: CGRect(origin: origin, size: size), animated: true)
        }
    }
}

// MARK: - share support

nonisolated struct SharedAssetFile: Transferable {
    let client: ImmichClient
    let asset: Asset

    func exportedURL() async throws -> URL {
        let url = client.editedOriginalURL(assetID: asset.id)
        var request = URLRequest(url: url)
        for (key, value) in client.authHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImmichError.unreachable }
        guard (200..<300).contains(http.statusCode) else {
            throw ImmichError.http(http.statusCode, ImmichClient.serverMessage(from: data))
        }
        var filename = "photo"
        if let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           let range = disposition.range(of: "filename=\"") {
            filename = String(disposition[range.upperBound...].prefix(while: { $0 != "\"" }))
        } else if asset.isVideo {
            filename = "video.mov"
        } else {
            filename = "photo.jpg"
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "share")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "\(UUID().uuidString)-\(filename)")
        try data.write(to: target)
        return target
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { wrapper in
            SentTransferredFile(try await wrapper.exportedURL())
        }
    }
}

/// shares the untouched bytes of a device-only asset.
nonisolated struct LocalSharedAssetFile: Transferable {
    let localIdentifier: String

    func exportedURL() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "share")
        return try await PhotoLibraryService.exportPrimary(
            localIdentifier: localIdentifier,
            to: directory
        ).fileURL
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { wrapper in
            SentTransferredFile(try await wrapper.exportedURL())
        }
    }
}
