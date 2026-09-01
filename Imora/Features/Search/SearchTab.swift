import CoreLocation
import SwiftUI

struct SearchTab: View {
    @Environment(SessionStore.self) private var session

    @State private var model = SearchModel()
    @State private var query = ""
    @State private var searchScope: SearchFilter.TextType = .context
    @State private var scopeInitialized = false
    @State private var activeSheet: FilterSheet?
    @State private var viewer = ViewerPresentation()
    @Namespace private var zoomNamespace

    /// context and ocr are feature-gated server-side, like the flutter menu.
    private var availableScopes: [SearchFilter.TextType] {
        var scopes: [SearchFilter.TextType] = []
        if session.features?.smartSearch != false { scopes.append(.context) }
        scopes.append(.filename)
        scopes.append(.description)
        if session.features?.ocr == true { scopes.append(.ocr) }
        return scopes
    }

    var body: some View {
        @Bindable var viewer = viewer

        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    FilterChipsRow(filter: model.filter, activeSheet: $activeSheet)

                    if model.hasActiveSearch {
                        SearchResultsGrid(model: model, zoomNamespace: zoomNamespace) { index in
                            viewer.present(assets: model.assets, initialIndex: index)
                        }
                    } else {
                        suggestionsContent
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: searchScope.prompt)
            .searchScopes($searchScope, activation: .onSearchPresentation) {
                ForEach(availableScopes) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .onSubmit(of: .search) { submit() }
            .onChange(of: query) { _, newValue in
                if newValue.isEmpty, !model.filter.activeText.isEmpty {
                    applyFilter { $0.setText("", type: searchScope) }
                }
            }
            .onAppear {
                guard !scopeInitialized else { return }
                scopeInitialized = true
                searchScope = session.features?.smartSearch != false ? .context : .filename
            }
            // keyed on client presence: a slow session start used to leave
            // the model permanently detached and every search a silent no-op.
            .task(id: session.client == nil) {
                if let client = session.client { model.attach(client) }
            }
            .sheet(item: $activeSheet) { sheet in
                filterSheet(for: sheet)
                    .presentationDetents(sheet == .people || sheet == .tags ? [.large] : [.medium, .large])
            }
            .navigationDestination(for: QuickLink.self) { link in
                quickLinkScreen(link)
            }
            .navigationDestination(for: Person.self) { person in
                PersonScreen(person: person)
            }
            .fullScreenCover(item: $viewer.route) { route in
                AssetViewerScreen(
                    assets: route.assets,
                    indexByAssetID: route.indexByAssetID,
                    initialIndex: route.initialIndex,
                    presentationID: route.id,
                    zoomNamespace: zoomNamespace,
                    onRequestDismissal: { viewer.complete(route.id) },
                    onDismissed: { viewer.complete(route.id) }
                ) { change in
                    switch change {
                    case .favorite(let id, let value):
                        if model.filter.isFavorite, !value {
                            model.beginExternalOptimisticRemoval(id: id)
                        } else {
                            if model.filter.isFavorite {
                                model.rollbackExternalOptimisticRemoval(id: id)
                            }
                            model.updateAssets(ids: [id]) { $0.isFavorite = value }
                        }
                    case .favoriteCommitted(let id, let value):
                        if model.filter.isFavorite, !value {
                            model.commitExternalOptimisticRemoval(id: id)
                        }
                    case .optimisticRemoval(let id):
                        model.beginExternalOptimisticRemoval(id: id)
                    case .removalCommitted(let id):
                        model.commitExternalOptimisticRemoval(id: id)
                    case .removalReverted(let id):
                        model.rollbackExternalOptimisticRemoval(id: id)
                    case .albumMembershipProjected, .albumMembershipCommitted, .albumMembershipReverted:
                        break
                    case .removed(let id):
                        model.removeAssets(ids: [id])
                    case .localDeleted:
                        break
                    case .edited(let id, let thumbhash):
                        model.updateAssets(ids: [id]) { asset in
                            if let thumbhash { asset.thumbhash = thumbhash }
                        }
                    }
                }
            }
        }
    }

    // MARK: - search dispatch

    /// bcp47 tag for smart search, e.g. "en-US".
    private var languageTag: String {
        let locale = Locale.current
        let language = locale.language.languageCode?.identifier ?? "en"
        guard let region = locale.region?.identifier else { return language }
        return "\(language)-\(region)"
    }

    private func submit() {
        applyFilter { $0.setText(query.trimmingCharacters(in: .whitespacesAndNewlines), type: searchScope) }
    }

    private func applyFilter(_ mutate: (inout SearchFilter) -> Void) {
        var next = model.filter
        mutate(&next)
        next.language = languageTag
        model.apply(next)
    }

    @ViewBuilder private func filterSheet(for sheet: FilterSheet) -> some View {
        switch sheet {
        case .people:
            PeoplePickerSheet(filter: model.filter, onApply: applySheetFilter)
        case .location:
            LocationPickerSheet(filter: model.filter, onApply: applySheetFilter)
        case .camera:
            CameraPickerSheet(filter: model.filter, onApply: applySheetFilter)
        case .date:
            DatePickerSheet(filter: model.filter, onApply: applySheetFilter)
        case .mediaType:
            MediaTypePickerSheet(filter: model.filter, onApply: applySheetFilter)
        case .rating:
            RatingPickerSheet(filter: model.filter, onApply: applySheetFilter)
        case .display:
            DisplayOptionsSheet(filter: model.filter, onApply: applySheetFilter)
        case .tags:
            TagsPickerSheet(filter: model.filter, onApply: applySheetFilter)
        }
    }

    private func applySheetFilter(_ newFilter: SearchFilter) {
        applyFilter { $0 = newFilter }
    }

    // MARK: - suggestions (pre-search landing)

    @ViewBuilder private var suggestionsContent: some View {
        VStack(spacing: 0) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.top, 48)

            Text("Search for your photos and videos")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 16)

            quickLinks
                .padding(.horizontal, 16)
                .padding(.top, 32)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var quickLinks: some View {
        VStack(spacing: 0) {
            quickLinkRow(.recentlyTaken, icon: "clock", title: "Recently Taken")
            Divider().padding(.leading, 56)
            quickLinkRow(.recentlyAdded, icon: "tray.and.arrow.down", title: "Recently Added")
            Divider().padding(.leading, 56)
            quickLinkRow(.videos, icon: "play.circle", title: "Videos")
            Divider().padding(.leading, 56)
            quickLinkRow(.favorites, icon: "heart", title: "Favorites")
        }
        .background(.fill.quaternary, in: .rect(cornerRadius: 20))
    }

    @ViewBuilder private func quickLinkRow(_ link: QuickLink, icon: String, title: String) -> some View {
        NavigationLink(value: link) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("quick-link-\(link.rawValue)")
    }

    @ViewBuilder private func quickLinkScreen(_ link: QuickLink) -> some View {
        switch link {
        case .recentlyTaken:
            TimelineScreen(
                title: "Recently Taken",
                filter: TimelineFilter(),
                emptyIcon: "clock",
                emptyMessage: "No photos yet",
                showsLargeTitle: false
            )
        case .recentlyAdded:
            TimelineScreen(
                title: "Recently Added",
                filter: TimelineFilter(orderBy: "createdAt"),
                emptyIcon: "tray.and.arrow.down",
                emptyMessage: "No photos yet",
                showsLargeTitle: false
            )
        case .videos:
            SearchResultsScreen(
                title: "Videos",
                baseFilter: {
                    var filter = SearchFilter()
                    filter.mediaType = .video
                    return filter
                }(),
                emptyIcon: "play.slash",
                emptyMessage: "No videos yet"
            )
        case .favorites:
            TimelineScreen(
                title: "Favorites",
                filter: TimelineFilter(isFavorite: true),
                emptyIcon: "heart",
                emptyMessage: "No favorites yet",
                showsLargeTitle: false
            )
        }
    }
}

nonisolated enum QuickLink: String, Hashable {
    case recentlyTaken
    case recentlyAdded
    case videos
    case favorites
}

// MARK: - results grid

/// flat paged grid shared by the search tab and canned searches like videos.
struct SearchResultsGrid: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(SessionStore.self) private var session

    let model: SearchModel
    let zoomNamespace: Namespace.ID
    let onTap: (Int) -> Void

    @State private var albumAsset: Asset?
    @State private var editingAsset: Asset?
    @State private var shareRequest: AssetShareRequest?
    @State private var workingAssetIDs: Set<String> = []
    @State private var toast: String?

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 200), spacing: 2)]

    var body: some View {
        gridContent
            .background {
                AssetSharePresenter(request: $shareRequest)
            }
            .sheet(item: $albumAsset) { asset in
                AddToAlbumSheet(assetIDs: [asset.id]) { message in
                    toast = message
                }
            }
            .fullScreenCover(item: $editingAsset) { asset in
                AssetEditScreen(asset: asset) { outcome in
                    guard case .saved(let detail) = outcome else { return }
                    model.updateAssets(ids: [asset.id]) { current in
                        if let thumbhash = detail?.thumbhash { current.thumbhash = thumbhash }
                    }
                    session.backup?.noteRemoteEdits([asset.id])
                    toast = "Edits saved"
                }
            }
            .overlay(alignment: .top) {
                if let toast {
                    ToastBanner(text: toast) { self.toast = nil }
                        .padding(.top, 8)
                }
            }
    }

    @ViewBuilder private var gridContent: some View {
        if model.isLoading && model.assets.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 120)
        } else if model.assets.isEmpty, model.loadFailed {
            // a timed-out first page is not a zero-result answer, and with no
            // tiles there is no tail row to scroll back onto for the retry.
            ContentUnavailableView {
                Label("Couldn't search", systemImage: "wifi.exclamationmark")
            } actions: {
                Button("Retry") { model.loadMore() }
                    .buttonStyle(.glass)
            }
            .padding(.top, 60)
        } else if model.assets.isEmpty {
            ContentUnavailableView(
                "No results",
                systemImage: "magnifyingglass",
                description: Text("Try another search term or change the filters.")
            )
            .padding(.top, 60)
        } else {
            // the tail that pulls the next page, as ids: enumerating the
            // results copied every asset in the grid on every pass, and the
            // list only grows as it is scrolled.
            let paginationIDs = Set(model.assets.suffix(12).lazy.map(\.id))
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(model.assets) { asset in
                    AssetTile(asset: asset)
                        .transition(.opacity)
                        .matchedTransitionSource(id: asset.id, in: zoomNamespace)
                        .hoverEffect()
                        .onTapGesture {
                            if let index = model.assets.firstIndex(where: { $0.id == asset.id }) {
                                onTap(index)
                            }
                        }
                        .contextMenu {
                            assetMenu(for: asset)
                        } preview: {
                            contextPreview(for: asset)
                        }
                        .onAppear {
                            if paginationIDs.contains(asset.id) {
                                model.loadMore()
                            }
                        }
                }
            }

            if model.isLoading {
                ProgressView()
                    .padding(.vertical, 24)
            } else if model.loadFailed {
                Button("Couldn't load more. Retry") { model.loadMore() }
                    .font(.subheadline)
                    .padding(.vertical, 24)
            } else if model.nextPage == nil {
                Text("No more results")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            }
        }
    }

    // MARK: - context menu

    private func pairedLocalIdentifier(for asset: Asset) -> String? {
        session.backup?.pairedLocalIdentifierByRemoteId[asset.id]
    }

    private func owns(_ asset: Asset) -> Bool {
        guard let userID = session.user?.id else { return true }
        return asset.ownerId == userID
    }

    private func availability(for asset: Asset) -> AssetActionAvailability {
        AssetActionAvailability(
            asset: asset,
            ownsAsset: owns(asset),
            pairedLocalIdentifier: pairedLocalIdentifier(for: asset)
        )
    }

    @ViewBuilder private func assetMenu(for asset: Asset) -> some View {
        let actions = availability(for: asset)
        let isWorking = workingAssetIDs.contains(asset.id)

        Section {
            Button {
                shareRequest = AssetShareRequest(assets: [asset])
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            if actions.canFavorite {
                Button {
                    Task { await toggleFavorite(asset) }
                } label: {
                    Label(
                        asset.isFavorite ? "Unfavorite" : "Favorite",
                        systemImage: asset.isFavorite ? "heart.slash" : "heart"
                    )
                }
                .disabled(isWorking)
            }

            if actions.canAddToAlbum {
                Button {
                    albumAsset = asset
                } label: {
                    Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
                }
                .disabled(isWorking)
            }

            if actions.canEdit {
                Button {
                    editingAsset = asset
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
                .disabled(isWorking)
            }

            if actions.canArchive {
                Button {
                    Task { await toggleArchive(asset) }
                } label: {
                    Label(
                        asset.visibility == .archive ? "Unarchive" : "Archive",
                        systemImage: asset.visibility == .archive ? "tray.and.arrow.up" : "archivebox"
                    )
                }
                .disabled(isWorking)
            }

            if !asset.isTrashed {
                Button {
                    Task { await openInBrowser(asset) }
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
            }
        }

        if actions.canDownload || actions.canDeleteFromDevice {
            Section {
                if actions.canDownload {
                    Button {
                        Task { await download(asset) }
                    } label: {
                        Label("Download to Device", systemImage: "arrow.down.circle")
                    }
                    .disabled(isWorking)
                }

                if actions.canDeleteFromDevice {
                    Button(role: .destructive) {
                        Task { await deleteFromDevice(asset) }
                    } label: {
                        Label("Delete from This Device", systemImage: "iphone.slash")
                    }
                    .disabled(isWorking)
                }
            }
        }

        if actions.canTrashEverywhere {
            Section {
                Button(role: .destructive) {
                    Task { await moveToTrash(asset) }
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .disabled(isWorking)
            }
        }
    }

    private func contextPreview(for asset: Asset) -> some View {
        let ratio = CGFloat(min(max(asset.ratio, 0.65), 1.8))
        return AssetContextPreview(asset: asset)
            .frame(width: 300, height: 300 / ratio)
            .clipShape(.rect(cornerRadius: 18))
    }

    // MARK: - asset actions

    private func toggleFavorite(_ asset: Asset) async {
        guard beginAction(for: asset) else { return }
        defer { finishAction(for: asset) }
        guard let client = session.client else {
            ErrorToastCenter.shared.show("Couldn’t update the favorite. The server is not available.")
            return
        }

        let newValue = !asset.isFavorite
        let leavesFavoriteFilter = model.filter.isFavorite && !newValue
        var removal: SearchRemoval?
        let _: Void? = await OptimisticAction.perform(
            errorMessage: "Couldn’t update the favorite",
            apply: {
                if leavesFavoriteFilter {
                    removal = removeOptimistically(asset.id)
                } else {
                    model.updateAssets(ids: [asset.id]) { $0.isFavorite = newValue }
                }
            },
            rollback: {
                if let removal {
                    restoreOptimistically(removal)
                } else {
                    model.updateAssets(ids: [asset.id]) { current in
                        guard current.isFavorite == newValue else { return }
                        current.isFavorite = asset.isFavorite
                    }
                }
            },
            request: { try await client.setFavorite(ids: [asset.id], newValue) }
        )
    }

    private func toggleArchive(_ asset: Asset) async {
        guard beginAction(for: asset) else { return }
        defer { finishAction(for: asset) }
        guard let client = session.client else {
            ErrorToastCenter.shared.show("The server is not available.")
            return
        }

        let visibility: AssetVisibility = asset.visibility == .archive ? .timeline : .archive
        var removal: SearchRemoval?
        let _: Void? = await OptimisticAction.perform(
            errorMessage: visibility == .archive ? "Couldn’t archive" : "Couldn’t unarchive",
            apply: { removal = removeOptimistically(asset.id) },
            rollback: { if let removal { restoreOptimistically(removal) } },
            request: { try await client.setVisibility(ids: [asset.id], visibility) }
        )
    }

    private func download(_ asset: Asset) async {
        guard beginAction(for: asset) else { return }
        defer { finishAction(for: asset) }
        guard let backup = session.backup else {
            reportUnavailableAction()
            return
        }

        do {
            _ = try await backup.download(asset: asset)
            toast = "Saved to your photo library"
        } catch {
            ErrorToastCenter.shared.show("Couldn’t download", error: error)
        }
    }

    private func deleteFromDevice(_ asset: Asset) async {
        guard beginAction(for: asset) else { return }
        defer { finishAction(for: asset) }
        guard let backup = session.backup,
              let localIdentifier = pairedLocalIdentifier(for: asset)
        else {
            reportUnavailableAction()
            return
        }

        do {
            try await PhotoLibraryService.delete(localIdentifiers: [localIdentifier])
            backup.noteLocalDeletion([localIdentifier])
            toast = "Deleted from this device"
        } catch {
            guard !PhotoLibraryService.isUserCancelled(error) else { return }
            ErrorToastCenter.shared.show("Couldn’t delete from this device", error: error)
        }
    }

    private func moveToTrash(_ asset: Asset) async {
        guard beginAction(for: asset) else { return }
        defer { finishAction(for: asset) }
        guard let client = session.client else {
            ErrorToastCenter.shared.show("The server is not available.")
            return
        }

        let localIdentifier = pairedLocalIdentifier(for: asset)
        if let localIdentifier {
            do {
                try await PhotoLibraryService.delete(localIdentifiers: [localIdentifier])
                session.backup?.noteLocalDeletion([localIdentifier])
            } catch {
                guard !PhotoLibraryService.isUserCancelled(error) else { return }
                ErrorToastCenter.shared.show("Couldn’t delete from this device", error: error)
                return
            }
        }

        let errorMessage = localIdentifier == nil
            ? "Couldn’t move to trash"
            : "Deleted from this device, but couldn’t move the server copy to trash"
        var removal: SearchRemoval?
        let _: Void? = await OptimisticAction.perform(
            errorMessage: errorMessage,
            apply: { removal = removeOptimistically(asset.id) },
            rollback: { if let removal { restoreOptimistically(removal) } },
            request: { try await client.trashAssets(ids: [asset.id]) }
        )
    }

    private func removeOptimistically(_ id: String) -> SearchRemoval {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
            model.removeAssetsForOptimisticAction(ids: [id])
        }
    }

    private func restoreOptimistically(_ removal: SearchRemoval) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
            model.restore(removal)
        }
    }

    private func openInBrowser(_ asset: Asset) async {
        guard let client = session.client else {
            reportUnavailableAction()
            return
        }
        let baseURL = await client.serverWebURL()
        openURL(baseURL.appending(path: "photos/\(asset.id)"))
    }

    private func beginAction(for asset: Asset) -> Bool {
        workingAssetIDs.insert(asset.id).inserted
    }

    private func finishAction(for asset: Asset) {
        workingAssetIDs.remove(asset.id)
    }

    private func reportUnavailableAction() {
        ErrorToastCenter.shared.show("This action is no longer available.")
    }
}

/// standalone paged search screen for canned filters, e.g. the videos quick
/// link.
struct SearchResultsScreen: View {
    @Environment(SessionStore.self) private var session
    let title: String
    let baseFilter: SearchFilter
    var emptyIcon = "magnifyingglass"
    var emptyMessage = "No results"

    @State private var model = SearchModel()
    @State private var viewer = ViewerPresentation()
    @Namespace private var zoomNamespace

    var body: some View {
        @Bindable var viewer = viewer

        ScrollView {
            SearchResultsGrid(model: model, zoomNamespace: zoomNamespace) { index in
                viewer.present(assets: model.assets, initialIndex: index)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.client == nil) {
            if let client = session.client { model.attach(client) }
            model.apply(baseFilter)
        }
        .fullScreenCover(item: $viewer.route) { route in
            AssetViewerScreen(
                assets: route.assets,
                indexByAssetID: route.indexByAssetID,
                initialIndex: route.initialIndex,
                presentationID: route.id,
                zoomNamespace: zoomNamespace,
                onRequestDismissal: { viewer.complete(route.id) },
                onDismissed: { viewer.complete(route.id) }
            ) { change in
                switch change {
                case .favorite(let id, let value):
                    if model.filter.isFavorite, !value {
                        model.beginExternalOptimisticRemoval(id: id)
                    } else {
                        if model.filter.isFavorite {
                            model.rollbackExternalOptimisticRemoval(id: id)
                        }
                        model.updateAssets(ids: [id]) { $0.isFavorite = value }
                    }
                case .favoriteCommitted(let id, let value):
                    if model.filter.isFavorite, !value {
                        model.commitExternalOptimisticRemoval(id: id)
                    }
                case .optimisticRemoval(let id):
                    model.beginExternalOptimisticRemoval(id: id)
                case .removalCommitted(let id):
                    model.commitExternalOptimisticRemoval(id: id)
                case .removalReverted(let id):
                    model.rollbackExternalOptimisticRemoval(id: id)
                case .albumMembershipProjected, .albumMembershipCommitted, .albumMembershipReverted:
                    break
                case .removed(let id):
                    model.removeAssets(ids: [id])
                case .localDeleted:
                    break
                case .edited(let id, let thumbhash):
                    model.updateAssets(ids: [id]) { asset in
                        if let thumbhash { asset.thumbhash = thumbhash }
                    }
                }
            }
        }
    }
}

/// metadata search results for a city.
struct PlaceScreen: View {
    @Environment(SessionStore.self) private var session
    let city: String
    /// where the city sits, taken from its representative photo. drives the
    /// map shortcut in the toolbar.
    var coordinate: CLLocationCoordinate2D?

    @State private var model = SearchModel()
    @State private var viewer = ViewerPresentation()
    @State private var showMap = false
    @Namespace private var zoomNamespace

    var body: some View {
        @Bindable var viewer = viewer

        ScrollView {
            SearchResultsGrid(model: model, zoomNamespace: zoomNamespace) { index in
                viewer.present(assets: model.assets, initialIndex: index)
            }
        }
        .navigationTitle(city)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if coordinate != nil, session.features?.map != false {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showMap = true
                    } label: {
                        Image(systemName: "map")
                    }
                    .accessibilityIdentifier("place-map")
                }
            }
        }
        .navigationDestination(isPresented: $showMap) {
            MapScreen(initialCoordinate: coordinate)
        }
        .task(id: session.client == nil) {
            if let client = session.client { model.attach(client) }
            var filter = SearchFilter()
            filter.city = city
            model.apply(filter)
        }
        .fullScreenCover(item: $viewer.route) { route in
            AssetViewerScreen(
                assets: route.assets,
                indexByAssetID: route.indexByAssetID,
                initialIndex: route.initialIndex,
                presentationID: route.id,
                zoomNamespace: zoomNamespace,
                onRequestDismissal: { viewer.complete(route.id) },
                onDismissed: { viewer.complete(route.id) }
            ) { change in
                switch change {
                case .favorite(let id, let value):
                    model.updateAssets(ids: [id]) { $0.isFavorite = value }
                case .favoriteCommitted:
                    break
                case .optimisticRemoval(let id):
                    model.beginExternalOptimisticRemoval(id: id)
                case .removalCommitted(let id):
                    model.commitExternalOptimisticRemoval(id: id)
                case .removalReverted(let id):
                    model.rollbackExternalOptimisticRemoval(id: id)
                case .albumMembershipProjected, .albumMembershipCommitted, .albumMembershipReverted:
                    break
                case .removed(let id):
                    model.removeAssets(ids: [id])
                case .localDeleted:
                    break
                case .edited(let id, let thumbhash):
                    model.updateAssets(ids: [id]) { asset in
                        if let thumbhash { asset.thumbhash = thumbhash }
                    }
                }
            }
        }
    }
}

nonisolated struct PlaceLink: Hashable {
    let city: String
    var latitude: Double?
    var longitude: Double?

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
