import SwiftUI
import AVKit

nonisolated enum AssetChange {
    case favorite(String, Bool)
    case removed(String)
    /// deleted from the device only - the server copy remains, so grids keep it.
    case localDeleted(String)
    /// pixels changed server side; the new thumbhash cache-busts stale thumbs.
    case edited(String, thumbhash: String?)
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

private nonisolated enum AssetViewerPage: Hashable, Sendable {
    case media
    case information
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
    @Environment(\.openURL) private var openURL
    @Environment(SessionStore.self) private var session

    let onChange: (AssetChange) -> Void
    let onDismissed: () -> Void
    let onRequestDismissal: (() -> Void)?
    let onSelectionChanged: (String) -> Void
    let onPageZoomChanged: (Bool) -> Void
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
    @State private var viewerScrollPosition = ScrollPosition(edge: .top)
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
    @State private var actionError: String?
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
        NavigationStack {
            GeometryReader { geometry in
                let pageLayout = AssetViewerPageLayout(
                    viewportHeight: geometry.size.height,
                    viewportWidth: geometry.size.width,
                    topSafeAreaInset: geometry.safeAreaInsets.top,
                    bottomSafeAreaInset: geometry.safeAreaInsets.bottom
                )

                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        mediaStage(pageLayout)
                            .frame(height: pageLayout.mediaHeight)
                            .id(AssetViewerPage.media)

                        if let current {
                            AssetInfoPanel(
                                asset: current,
                                onDateAdjusted: { fileCreatedAt, offsetHours in
                                    guard let index = assets.firstIndex(where: { $0.id == current.id }) else { return }
                                    assets[index].fileCreatedAt = fileCreatedAt
                                    assets[index].localOffsetHours = offsetHours
                                },
                                onAddToAlbum: serverAssetID == nil ? nil : { showAddToAlbum = true },
                                topContentInset: pageLayout.informationTopContentInset,
                                bottomContentInset: pageLayout.informationBottomContentInset
                            )
                            .frame(minHeight: pageLayout.informationHeight, alignment: .top)
                            .id(AssetViewerPage.information)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollPosition($viewerScrollPosition)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne, anchor: .top))
                .scrollIndicators(.hidden)
                .scrollDisabled(currentPageZoomed)
                // the outer scroll sits under the nav bar, so without this it
                // paints the top edge dim behind the transparent header.
                .scrollEdgeEffectHidden(true, for: .top)
                .onScrollGeometryChange(for: Bool.self) { scroll in
                    let viewportHeight = scroll.containerSize.height
                    return viewportHeight > 0
                        && max(0, scroll.contentOffset.y) >= viewportHeight * 0.5
                } action: { _, isVisible in
                    guard isVisible != showInfo else { return }
                    showInfo = isVisible
                }
            }
            .ignoresSafeArea()
            .toolbar { toolbarContent }
            .toolbarVisibility(!isContextPreview && chromeVisible ? .visible : .hidden, for: .navigationBar)
            .toolbarVisibility(!isContextPreview && chromeVisible ? .visible : .hidden, for: .bottomBar)
            // the header stays fully transparent: no bar backdrop, no top
            // scroll edge blur, just the floating glass controls and pill.
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
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
                AssetEditScreen(asset: current) { outcome in
                    guard case .saved(let detail) = outcome else { return }
                    // a saved edit whose refresh failed still repainted the
                    // server side, so always confirm it; the thumbhash only
                    // decides whether cached renders can be busted now.
                    apply(.edited(editedID, thumbhash: detail?.thumbhash))
                    toast = "Edits saved"
                }
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
        .alert(
            actionError ?? "",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        }
        .overlay(alignment: .top) {
            if let toast {
                ToastBanner(text: toast) { self.toast = nil }
            }
        }
    }

    private func mediaStage(_ pageLayout: AssetViewerPageLayout) -> some View {
        ZStack {
            Color(uiColor: chromeVisible ? .systemBackground : .black)
                .accessibilityIdentifier("asset-viewer")
                .accessibilityValue(selectedAssetID ?? "")

            AssetPager(
                assets: assets,
                selection: $selectedAssetID,
                mutesVideo: isContextPreview,
                playback: playback
            ) { id, isZoomed in
                guard id == selectedAssetID else { return }
                currentPageZoomed = isZoomed
                onPageZoomChanged(isZoomed)
            }
            .scrollEdgeEffectHidden(true, for: .top)
            .onTapGesture {
                withAnimation(reduceMotion ? .linear(duration: 0.12) : .smooth(duration: 0.2)) {
                    chromeVisible.toggle()
                }
            }

            AirPlayRoutePicker(trigger: $airPlayTrigger)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            if !isContextPreview, chromeVisible, let current,
               current.isVideo, playback.ownerID == current.id, playback.player != nil {
                VideoControlsBar(playback: playback)
                    .padding(.bottom, pageLayout.videoControlsBottomInset)
                    .transition(.opacity)
            }
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
        showInfo = visible
        if reduceMotion {
            scroll(to: visible ? .information : .media)
        } else {
            withAnimation(.smooth(duration: 0.35)) {
                scroll(to: visible ? .information : .media)
            }
        }
    }

    private func scroll(to page: AssetViewerPage) {
        viewerScrollPosition.scrollTo(id: page, anchor: .top)
    }

    // MARK: - chrome

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
                trashedToolbarItems(current)
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
    @ToolbarContentBuilder private func trashedToolbarItems(_ current: Asset) -> some ToolbarContent {
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
                Button(role: .destructive) {
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
            Image(systemName: "ellipsis.circle")
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
        case .removed(let id):
            if let index = assets.firstIndex(where: { $0.id == id }) {
                assets.remove(at: index)
                if assets.isEmpty {
                    requestDismissal()
                } else if currentIndex >= assets.count {
                    currentIndex = assets.count - 1
                    selectedAssetID = assets[currentIndex].id
                }
            }
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

    private func toggleFavorite() async {
        guard let client = session.client, let asset = current else { return }
        let newValue = !asset.isFavorite
        do {
            try await client.setFavorite(ids: [asset.id], newValue)
            apply(.favorite(asset.id, newValue))
        } catch {
            actionError = "Could not update the favorite: \(error.localizedDescription)"
        }
    }

    private func toggleArchive() async {
        guard let client = session.client, let asset = current else { return }
        let visibility: AssetVisibility = asset.visibility == .archive ? .timeline : .archive
        do {
            try await client.setVisibility(ids: [asset.id], visibility)
            onChange(.removed(asset.id))
            removeCurrent()
        } catch {
            actionError = "Could not update the archive: \(error.localizedDescription)"
        }
    }

    /// takes the photo out of the album only - it stays in the library, which
    /// is why this needs no confirmation, matching the official mobile client.
    private func removeFromAlbum() async {
        guard let client = session.client, let album, let asset = current else { return }
        do {
            try await client.removeAssets(albumID: album.id, ids: [asset.id])
            onChange(.removed(asset.id))
            removeCurrent()
            toast = "Removed from the album"
        } catch {
            actionError = "Could not remove from the album: \(error.localizedDescription)"
        }
    }

    private func restore() async {
        guard let client = session.client, let asset = current else { return }
        do {
            try await client.restoreAssets(ids: [asset.id])
            onChange(.removed(asset.id))
            removeCurrent()
        } catch {
            actionError = "Could not restore: \(error.localizedDescription)"
        }
    }

    private func trash() async {
        guard let asset = current else { return }
        guard let serverAssetID else {
            await deleteLocalOnlyAsset()
            return
        }
        guard let client = session.client else { return }
        if let localID = await resolveLocalIdentifier() {
            await deleteEverywhere(
                serverID: serverAssetID,
                sourceAssetID: asset.id,
                localIdentifier: localID,
                force: false
            )
            return
        }
        do {
            try await client.trashAssets(ids: [serverAssetID])
            onChange(.removed(asset.id))
            removeCurrent()
        } catch {
            actionError = "Could not move to trash: \(error.localizedDescription)"
        }
    }

    private func deletePermanently() async {
        guard let client = session.client, let asset = current, let serverAssetID else { return }
        if let localID = await resolveLocalIdentifier() {
            await deleteEverywhere(
                serverID: serverAssetID,
                sourceAssetID: asset.id,
                localIdentifier: localID,
                force: true
            )
            return
        }
        do {
            try await client.trashAssets(ids: [serverAssetID], force: true)
            onChange(.removed(asset.id))
            removeCurrent()
        } catch {
            actionError = "Could not delete: \(error.localizedDescription)"
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
        guard let client = session.client else { return }
        do {
            try await PhotoLibraryService.delete(localIdentifiers: [localIdentifier])
        } catch {
            return
        }
        session.backup?.noteLocalDeletion([localIdentifier])
        self.localIdentifier = nil
        do {
            try await client.trashAssets(ids: [serverID], force: force)
            onChange(.removed(sourceAssetID))
            removeCurrent()
        } catch {
            onChange(.localDeleted(sourceAssetID))
            actionError = "Deleted from this device, but the server copy could not be deleted."
        }
    }

    /// removes a device-only asset that has no server copy yet.
    private func deleteLocalOnlyAsset() async {
        guard let asset = current, let localId = asset.localIdentifier else { return }
        do {
            try await PhotoLibraryService.delete(localIdentifiers: [localId])
        } catch {
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
            actionError = "Could not download: \(error.localizedDescription)"
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
            actionError = "Could not back up: \(error.localizedDescription)"
        }
    }

    private func deleteFromDevice() async {
        guard let asset = current, let localId = await resolveLocalIdentifier() else { return }
        do {
            try await PhotoLibraryService.delete(localIdentifiers: [localId])
        } catch {
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
    let onZoomChanged: (String, Bool) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(assets) { asset in
                    AssetPage(
                        asset: asset,
                        isActive: asset.id == selection,
                        mutesVideo: mutesVideo,
                        playback: playback
                    ) { isZoomed in
                        onZoomChanged(asset.id, isZoomed)
                    }
                    .containerRelativeFrame([.horizontal, .vertical])
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
        ZStack {
            Color.clear
            pageContent
        }
    }

    @ViewBuilder private var pageContent: some View {
        if asset.isVideo {
            VideoPlayerPage(
                asset: asset,
                deviceIdentifier: deviceIdentifier,
                isActive: isActive,
                forcesMute: mutesVideo,
                playback: playback,
                onZoomChanged: onZoomChanged
            )
        } else if let localId = deviceIdentifier {
            ZoomableScrollView(contentID: asset.id, onZoomChanged: onZoomChanged) {
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
            ZoomableScrollView(contentID: "\(asset.id)#\(asset.thumbhash ?? "")", onZoomChanged: onZoomChanged) {
                RemoteImage(
                    url: client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: asset.thumbhash),
                    targetPixelSize: pagePixelSize,
                    thumbhash: asset.thumbhash,
                    fallbackURL: client.thumbnailURL(assetID: asset.id, cacheKey: asset.thumbhash),
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
        var filename = "photo"
        if let http = response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
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
