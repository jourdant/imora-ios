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
private let pagePixelSize: CGFloat = 2048

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
    let presentationID: UUID
    let zoomNamespace: Namespace.ID?

    @State private var assets: [Asset]
    @State private var currentIndex: Int
    @State private var selectedAssetID: String?
    @State private var chromeVisible = true
    @State private var showInfo = false
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
    @State private var downloading = false
    @State private var actionError: String?
    @State private var toast: String?
    @State private var isDismissing = false
    @State private var didNotifyDismissal = false
    @State private var prefetcher = ThumbnailPrefetcher(targetPixelSize: pagePixelSize)

    init(
        assets: [Asset],
        initialIndex: Int,
        presentationID: UUID,
        zoomNamespace: Namespace.ID? = nil,
        onDismissed: @escaping () -> Void,
        onChange: @escaping (AssetChange) -> Void
    ) {
        let safeIndex = assets.indices.contains(initialIndex) ? initialIndex : 0
        _assets = State(initialValue: assets)
        _currentIndex = State(initialValue: safeIndex)
        _selectedAssetID = State(initialValue: assets.indices.contains(safeIndex) ? assets[safeIndex].id : nil)
        self.presentationID = presentationID
        self.zoomNamespace = zoomNamespace
        self.onDismissed = onDismissed
        self.onChange = onChange
    }

    private var current: Asset? {
        assets.indices.contains(currentIndex) ? assets[currentIndex] : nil
    }

    /// mutations are only offered on assets the signed-in user owns. an
    /// unknown user - offline restore - is treated as the owner, best effort.
    private var ownsCurrent: Bool {
        guard let asset = current else { return false }
        guard let userID = session.user?.id else { return true }
        return asset.ownerId == userID
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
            ZStack {
                // photos-style backdrop: system background under chrome, pure
                // black once the chrome is tapped away.
                Color(uiColor: chromeVisible ? .systemBackground : .black)
                    .ignoresSafeArea()
                    .accessibilityIdentifier("asset-viewer")
                    // lets ui tests confirm the pager landed on the tapped asset.
                    .accessibilityValue(selectedAssetID ?? "")

                // the pager lives in its own child view so per frame chrome and
                // dismissal state changes in this screen never re-diff the pages.
                AssetPager(
                    assets: assets,
                    selection: $selectedAssetID
                ) { id, isZoomed in
                    guard id == selectedAssetID else { return }
                    currentPageZoomed = isZoomed
                }
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(reduceMotion ? .linear(duration: 0.12) : .smooth(duration: 0.2)) {
                        chromeVisible.toggle()
                    }
                }
                .simultaneousGesture(swipeUpForInfo)

                AirPlayRoutePicker(trigger: $airPlayTrigger)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if chromeVisible, let current, current.isLocal {
                    backupStatePill(current)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }
            }
            .toolbar { toolbarContent }
            .toolbarVisibility(chromeVisible ? .visible : .hidden, for: .navigationBar)
            .toolbarVisibility(chromeVisible ? .visible : .hidden, for: .bottomBar)
            .navigationBarTitleDisplayMode(.inline)
        }
        .statusBarHidden(!chromeVisible)
        .allowsHitTesting(!isDismissing)
        .onChange(of: selectedAssetID) { _, id in
            guard let id, let index = assets.firstIndex(where: { $0.id == id }) else { return }
            currentIndex = index
            currentPageZoomed = false
        }
        .onDisappear {
            prefetcher.cancel()
            guard !didNotifyDismissal else { return }
            didNotifyDismissal = true
            currentPageZoomed = false
            onDismissed()
        }
        .sheet(isPresented: $showInfo) {
            if let current {
                AssetInfoSheet(asset: current) { fileCreatedAt, offsetHours in
                    guard let index = assets.firstIndex(where: { $0.id == current.id }) else { return }
                    assets[index].fileCreatedAt = fileCreatedAt
                    assets[index].localOffsetHours = offsetHours
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(28)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
        .sheet(isPresented: $showAddToAlbum) {
            if let current {
                AddToAlbumSheet(assetIDs: [current.id]) { message in
                    toast = message
                }
            }
        }
        .sheet(isPresented: $showShareLinks) {
            if let current {
                ShareLinksSheet(target: .assets([current.id]))
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
            guard let asset = current, !asset.isLocal, let backup = session.backup else { return }
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

    // MARK: - gestures

    /// photos-style swipe up on the picture reveals the info panel.
    private var swipeUpForInfo: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                guard !currentPageZoomed, !showInfo else { return }
                let up = -value.translation.height
                guard up > 60, up > abs(value.translation.width) else { return }
                showInfo = true
            }
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
                VStack(spacing: 1) {
                    Text(current.localDate, format: dateTitleFormat(for: current.localDate))
                        .font(.subheadline.weight(.semibold))
                    Text(current.localDate, format: .dateTime.hour().minute().utc())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            if current?.isLocal != true {
                moreMenu
                    .accessibilityIdentifier("viewer-menu")
            }
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

    /// bottom bar for server assets, mirroring the photos app: share,
    /// favorite, info, trash as evenly spaced glass circles.
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

        ToolbarItem(placement: .bottomBar) {
            if ownsCurrent {
                Button {
                    Task { await toggleFavorite() }
                } label: {
                    Image(systemName: current.isFavorite ? "heart.fill" : "heart")
                        .contentTransition(.symbolEffect(.replace))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: current.isFavorite)
                }
                .accessibilityIdentifier("viewer-favorite")
            }
        }

        ToolbarSpacer(.flexible, placement: .bottomBar)

        ToolbarItem(placement: .bottomBar) {
            Button {
                showInfo = true
            } label: {
                Image(systemName: "info.circle")
            }
            .accessibilityIdentifier("viewer-info")
        }

        ToolbarSpacer(.flexible, placement: .bottomBar)

        ToolbarItem(placement: .bottomBar) {
            if ownsCurrent {
                Button(role: .destructive) {
                    ask(.trash, from: .toolbar)
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityIdentifier("viewer-trash")
                .modifier(confirmationDialog(from: .toolbar))
            }
        }
    }

    /// trashed assets offer restore and permanent delete, like the photos
    /// app's recently deleted album.
    @ToolbarContentBuilder private func trashedToolbarItems(_ current: Asset) -> some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button {
                Task { await restore() }
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .accessibilityIdentifier("viewer-restore")
        }

        ToolbarSpacer(.flexible, placement: .bottomBar)

        ToolbarItem(placement: .bottomBar) {
            Button(role: .destructive) {
                ask(.deletePermanently, from: .toolbar)
            } label: {
                Image(systemName: "trash")
            }
            .modifier(confirmationDialog(from: .toolbar))
        }
    }

    /// device-only assets can be shared and deleted locally; server actions
    /// come after they are backed up.
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
            Button(role: .destructive) {
                ask(.deleteFromDevice, from: .toolbar)
            } label: {
                Image(systemName: "trash")
            }
            .modifier(confirmationDialog(from: .toolbar))
        }
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button {
                    showInfo = true
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
                if current?.isImage == true, !currentIsTrashed {
                    Button {
                        showEditor = true
                    } label: {
                        Label("Edit", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("viewer-edit")
                }
                Button {
                    showAddToAlbum = true
                } label: {
                    Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
                }
                .accessibilityIdentifier("viewer-add-to-album")
                if ownsCurrent {
                    Button {
                        showShareLinks = true
                    } label: {
                        Label("Share Link", systemImage: "link")
                    }
                    .accessibilityIdentifier("viewer-share-link")
                }
            }

            Section {
                Button {
                    airPlayTrigger += 1
                } label: {
                    Label("Cast", systemImage: "airplay.video")
                }
                if session.features?.smartSearch == true {
                    Button {
                        showSimilar = true
                    } label: {
                        Label("View Similar", systemImage: "sparkle.magnifyingglass")
                    }
                    .accessibilityIdentifier("viewer-similar")
                }
                if current?.isImage == true {
                    Button {
                        showProfileCrop = true
                    } label: {
                        Label("Set as Profile Picture", systemImage: "person.crop.circle")
                    }
                }
                if localIdentifier == nil {
                    if downloading {
                        Button {} label: {
                            Label("Downloading...", systemImage: "arrow.down.circle.dotted")
                        }
                        .disabled(true)
                    } else {
                        Button {
                            Task { await download() }
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                        .accessibilityIdentifier("viewer-download")
                    }
                }
                Button {
                    Task { await openInBrowser() }
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
            }

            if ownsCurrent {
                Section {
                    Button {
                        Task { await archive() }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        ask(.trash, from: .menu)
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                    .accessibilityIdentifier("viewer-delete")
                    if localIdentifier != nil {
                        Button(role: .destructive) {
                            ask(.deleteFromDevice, from: .menu)
                        } label: {
                            Label("Delete from Device Only", systemImage: "iphone.slash")
                        }
                        .accessibilityIdentifier("viewer-delete-device")
                    }
                    Button(role: .destructive) {
                        ask(.deletePermanently, from: .menu)
                    } label: {
                        Label("Delete Permanently", systemImage: "trash.slash")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        // the dialog anchors to the menu button, not to the vanished menu item.
        .modifier(confirmationDialog(from: .menu))
    }

    private func backupStatePill(_ current: Asset) -> some View {
        HStack(spacing: 6) {
            Image(systemName: current.isLocalBackedUp ? "checkmark.icloud" : "icloud.slash")
            Text(current.isLocalBackedUp ? "Backed up" : "Not backed up yet")
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
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

    private var currentIsTrashed: Bool { current?.isTrashed == true }

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
        case .trash: return "Move \(noun) to Trash?"
        case .deletePermanently: return "Delete \(noun) Permanently?"
        case .deleteFromDevice: return "Delete from This Device?"
        case nil: return ""
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .trash:
            if current?.isLocal == true {
                return "This will remove it from your device photo library."
            }
            return localIdentifier != nil
                ? "It will move to the server trash and the copy in your device photo library will be deleted."
                : "It will move to the server trash and can be restored from there."
        case .deletePermanently:
            return localIdentifier != nil
                ? "It will be permanently deleted from the server and from this device. This cannot be undone."
                : "It will be permanently deleted from the server. This cannot be undone."
        case .deleteFromDevice:
            return current?.isLocal == true
                ? "This photo is not backed up. It will be removed from your device photo library permanently."
                : "The copy in your device photo library will be deleted. The server copy is kept."
        case nil:
            return ""
        }
    }

    @ViewBuilder private var confirmationActions: some View {
        switch confirmation {
        case .trash:
            if current?.isLocal == true {
                Button("Delete", role: .destructive) {
                    Task { await deleteLocalOnlyAsset() }
                }
            } else {
                Button("Move to Trash", role: .destructive) {
                    Task { await trash() }
                }
                .accessibilityIdentifier("viewer-trash-confirm")
            }
        case .deletePermanently:
            Button("Delete Permanently", role: .destructive) {
                Task { await deletePermanently() }
            }
        case .deleteFromDevice:
            Button("Delete from Device", role: .destructive) {
                if current?.isLocal == true {
                    Task { await deleteLocalOnlyAsset() }
                } else {
                    Task { await deleteFromDevice() }
                }
            }
            .accessibilityIdentifier("viewer-delete-device-confirm")
        case nil:
            EmptyView()
        }
        Button("Cancel", role: .cancel) {}
    }

    // MARK: - actions

    private func requestDismissal() {
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
        assets[currentIndex].isFavorite = newValue
        onChange(.favorite(asset.id, newValue))
        try? await client.setFavorite(ids: [asset.id], newValue)
    }

    private func archive() async {
        guard let client = session.client, let asset = current else { return }
        try? await client.setVisibility(ids: [asset.id], .archive)
        onChange(.removed(asset.id))
        removeCurrent()
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
        // a server delete also removes the device copy when one exists.
        if await resolveLocalIdentifier() != nil {
            await deleteEverywhere(force: false)
            return
        }
        guard let client = session.client, let asset = current else { return }
        try? await client.trashAssets(ids: [asset.id])
        onChange(.removed(asset.id))
        removeCurrent()
    }

    private func deletePermanently() async {
        if await resolveLocalIdentifier() != nil {
            await deleteEverywhere(force: true)
            return
        }
        guard let client = session.client, let asset = current else { return }
        do {
            try await client.trashAssets(ids: [asset.id], force: true)
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
        guard let asset = current, !asset.isLocal, let backup = session.backup else { return nil }
        let resolved = await backup.localIdentifier(forRemote: asset.id)
        if current?.id == asset.id { localIdentifier = resolved }
        return resolved
    }

    /// device first: declining the system dialog aborts with nothing changed.
    /// after the device copy is gone the index is updated immediately, even if
    /// the server call then fails.
    private func deleteEverywhere(force: Bool) async {
        guard let client = session.client, let asset = current, let localId = localIdentifier else { return }
        do {
            try await PhotoLibraryService.delete(localIdentifiers: [localId])
        } catch {
            return
        }
        session.backup?.noteLocalDeletion([localId])
        localIdentifier = nil
        do {
            try await client.trashAssets(ids: [asset.id], force: force)
            onChange(.removed(asset.id))
            removeCurrent()
        } catch {
            onChange(.localDeleted(asset.id))
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

    private func deleteFromDevice() async {
        guard let asset = current, let localId = localIdentifier else { return }
        do {
            try await PhotoLibraryService.delete(localIdentifiers: [localId])
        } catch {
            return
        }
        session.backup?.noteLocalDeletion([localId])
        localIdentifier = nil
        onChange(.localDeleted(asset.id))
    }

    private func openInBrowser() async {
        guard let client = session.client, let asset = current else { return }
        let base = await client.serverWebURL()
        openURL(base.appending(path: "photos/\(asset.id)"))
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
    let onZoomChanged: (String, Bool) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(assets) { asset in
                    AssetPage(asset: asset, isActive: asset.id == selection) { isZoomed in
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
        if let localId = deviceIdentifier {
            if asset.isVideo {
                LocalVideoPage(
                    localIdentifier: localId,
                    isActive: isActive,
                    allowsNetwork: asset.isLocal,
                    onUnavailable: { localUnavailable = true }
                )
            } else {
                ZoomableScrollView(contentID: asset.id, onZoomChanged: onZoomChanged) {
                    LocalPhotoImage(
                        localIdentifier: localId,
                        targetPixelSize: pagePixelSize,
                        fallbackTargetPixelSize: 640,
                        contentMode: .fit,
                        onUnavailable: { localUnavailable = true }
                    )
                }
            }
        } else if asset.isVideo {
            VideoPage(asset: asset, isActive: isActive)
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

/// plays a device-only video straight from the photo library.
private struct LocalVideoPage: View {
    let localIdentifier: String
    let isActive: Bool
    /// device-only assets have nowhere else to go, so they may pull from
    /// icloud; a backed-up one falls back to the server stream instead.
    var allowsNetwork = true
    var onUnavailable: (() -> Void)?
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: "\(localIdentifier):\(isActive)") {
            guard isActive else {
                tearDownPlayer()
                return
            }
            if player == nil {
                let loaded = await LocalImageLoader.shared.playerItem(
                    localIdentifier: localIdentifier,
                    allowsNetwork: allowsNetwork
                )
                guard let item = loaded else {
                    // the device copy is gone or stuck in icloud - stream the
                    // server one rather than spinning forever.
                    return onUnavailable?() ?? ()
                }
                player = AVPlayer(playerItem: item)
            }
            player?.play()
        }
        .onDisappear { tearDownPlayer() }
    }

    private func tearDownPlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}

private struct VideoPage: View {
    @Environment(SessionStore.self) private var session
    let asset: Asset
    let isActive: Bool
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: "\(asset.id):\(isActive)") {
            guard isActive else {
                tearDownPlayer()
                return
            }
            if player == nil, let client = session.client {
                let asset = AVURLAsset(
                    url: client.playbackURL(assetID: self.asset.id),
                    options: ["AVURLAssetHTTPHeaderFieldsKey": client.authHeaders]
                )
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            }
            player?.play()
        }
        .onDisappear { tearDownPlayer() }
    }

    private func tearDownPlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}

// MARK: - zoom container

private struct ZoomableScrollView<Content: View>: UIViewRepresentable {
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

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { wrapper in
            let url = wrapper.client.editedOriginalURL(assetID: wrapper.asset.id)
            var request = URLRequest(url: url)
            for (key, value) in wrapper.client.authHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            var filename = "photo"
            if let http = response as? HTTPURLResponse,
               let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
               let range = disposition.range(of: "filename=\"") {
                filename = String(disposition[range.upperBound...].prefix(while: { $0 != "\"" }))
            } else if wrapper.asset.isVideo {
                filename = "video.mov"
            } else {
                filename = "photo.jpg"
            }
            let target = FileManager.default.temporaryDirectory.appending(path: filename)
            try? FileManager.default.removeItem(at: target)
            try data.write(to: target)
            return SentTransferredFile(target)
        }
    }
}

/// shares the untouched bytes of a device-only asset.
nonisolated struct LocalSharedAssetFile: Transferable {
    let localIdentifier: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { wrapper in
            let directory = FileManager.default.temporaryDirectory.appending(path: "share")
            let exported = try await PhotoLibraryService.exportPrimary(
                localIdentifier: wrapper.localIdentifier,
                to: directory
            )
            return SentTransferredFile(exported.fileURL)
        }
    }
}
