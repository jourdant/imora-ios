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
            .task {
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
                    initialIndex: route.initialIndex,
                    presentationID: route.id,
                    zoomNamespace: zoomNamespace,
                    onDismissed: { viewer.complete(route.id) }
                ) { change in
                    switch change {
                    case .removed(let id):
                        model.removeAssets(ids: [id])
                    case .favorite(let id, let value):
                        model.updateAssets(ids: [id]) { $0.isFavorite = value }
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
    let model: SearchModel
    let zoomNamespace: Namespace.ID
    let onTap: (Int) -> Void

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 200), spacing: 2)]

    var body: some View {
        if model.isLoading && model.assets.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 120)
        } else if model.assets.isEmpty {
            ContentUnavailableView(
                "No results",
                systemImage: "magnifyingglass",
                description: Text("Try another search term or change the filters.")
            )
            .padding(.top, 60)
        } else {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(model.assets.enumerated()), id: \.element.id) { index, asset in
                    AssetTile(asset: asset)
                        .matchedTransitionSource(id: asset.id, in: zoomNamespace)
                        .onTapGesture { onTap(index) }
                        .onAppear {
                            if index >= model.assets.count - 12 {
                                model.loadMore()
                            }
                        }
                }
            }

            if model.isLoading {
                ProgressView()
                    .padding(.vertical, 24)
            } else if model.nextPage == nil {
                Text("No more results")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            }
        }
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
        .task {
            if let client = session.client { model.attach(client) }
            model.apply(baseFilter)
        }
        .fullScreenCover(item: $viewer.route) { route in
            AssetViewerScreen(
                assets: route.assets,
                initialIndex: route.initialIndex,
                presentationID: route.id,
                zoomNamespace: zoomNamespace,
                onDismissed: { viewer.complete(route.id) }
            ) { change in
                switch change {
                case .removed(let id):
                    model.removeAssets(ids: [id])
                case .favorite(let id, let value):
                    model.updateAssets(ids: [id]) { $0.isFavorite = value }
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

/// timeline filtered to a person.
struct PersonScreen: View {
    @Environment(SessionStore.self) private var session
    let person: Person

    @State private var name: String
    @State private var showRename = false
    @State private var draftName = ""

    init(person: Person) {
        self.person = person
        _name = State(initialValue: person.name)
    }

    var body: some View {
        TimelineScreen(
            title: name.isEmpty ? "Unnamed" : name,
            filter: TimelineFilter(personId: person.id),
            emptyIcon: "person.crop.circle",
            emptyMessage: "No photos of this person",
            showsLargeTitle: false
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        draftName = name
                        showRename = true
                    } label: {
                        Label(name.isEmpty ? "Add Name" : "Rename", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Name", isPresented: $showRename) {
            TextField("Name", text: $draftName)
            Button("Save") {
                Task {
                    try? await session.client?.updatePerson(id: person.id, name: draftName)
                    name = draftName
                }
            }
            Button("Cancel", role: .cancel) {}
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
        .task {
            if let client = session.client { model.attach(client) }
            var filter = SearchFilter()
            filter.city = city
            model.apply(filter)
        }
        .fullScreenCover(item: $viewer.route) { route in
            AssetViewerScreen(
                assets: route.assets,
                initialIndex: route.initialIndex,
                presentationID: route.id,
                zoomNamespace: zoomNamespace,
                onDismissed: { viewer.complete(route.id) }
            ) { change in
                if case .removed(let id) = change {
                    model.removeAssets(ids: [id])
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
