import SwiftUI

struct SearchTab: View {
    @Environment(SessionStore.self) private var session

    @State private var query = ""
    @State private var results: [Asset] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var nextPage: Int?
    @State private var people: [Person] = []
    @State private var places: [ExploreResponse] = []
    @State private var viewer = ViewerPresentation()
    @Namespace private var zoomNamespace

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 200), spacing: 2)]

    var body: some View {
        @Bindable var viewer = viewer

        NavigationStack {
            ScrollView {
                if hasSearched {
                    resultsGrid
                } else {
                    discoverContent
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Search your photos")
            .onSubmit(of: .search) {
                Task { await search(reset: true) }
            }
            .onChange(of: query) { _, newValue in
                if newValue.isEmpty {
                    hasSearched = false
                    results = []
                    nextPage = nil
                }
            }
            .navigationDestination(for: Person.self) { person in
                PersonScreen(person: person)
            }
            .navigationDestination(for: PlaceLink.self) { place in
                PlaceScreen(city: place.city)
            }
            .task { await loadDiscover() }
            .fullScreenCover(item: $viewer.route) { route in
                AssetViewerScreen(
                    assets: route.assets,
                    initialIndex: route.initialIndex,
                    presentationID: route.id,
                    zoomNamespace: zoomNamespace,
                    onDismissed: { viewer.complete(route.id) }
                ) { change in
                    if case .removed(let id) = change {
                        results.removeAll { $0.id == id }
                    }
                }
            }
        }
    }

    // MARK: - results

    @ViewBuilder private var resultsGrid: some View {
        if isSearching && results.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 120)
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
                .padding(.top, 60)
        } else {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, asset in
                    AssetTile(asset: asset)
                        .matchedTransitionSource(id: asset.id, in: zoomNamespace)
                        .onTapGesture {
                            viewer.present(assets: results, initialIndex: index)
                        }
                        .onAppear {
                            if index >= results.count - 12, nextPage != nil, !isSearching {
                                Task { await search(reset: false) }
                            }
                        }
                }
            }
            if isSearching {
                ProgressView()
                    .padding(.vertical, 20)
            }
        }
    }

    // MARK: - discover

    @ViewBuilder private var discoverContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !people.isEmpty && session.preferences?.peopleEnabled != false {
                VStack(alignment: .leading, spacing: 10) {
                    Text("People")
                        .font(.title3.weight(.bold))
                        .padding(.horizontal, 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(people.prefix(20)) { person in
                                NavigationLink(value: person) {
                                    VStack(spacing: 6) {
                                        if let client = session.client {
                                            RemoteImage(url: client.personThumbnailURL(personID: person.id), targetPixelSize: 180)
                                                .frame(width: 72, height: 72)
                                                .clipShape(.circle)
                                        }
                                        Text(person.name.isEmpty ? "Unnamed" : person.name)
                                            .font(.caption)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .frame(width: 76)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }

            if let cityExplore = places.first(where: { $0.fieldName.contains("city") }) ?? places.first,
               !cityExplore.items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Places")
                        .font(.title3.weight(.bold))
                        .padding(.horizontal, 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(cityExplore.items, id: \.value) { item in
                                NavigationLink(value: PlaceLink(city: item.value)) {
                                    placeCard(item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }

            if people.isEmpty && places.isEmpty {
                ContentUnavailableView(
                    "Search your library",
                    systemImage: "magnifyingglass",
                    description: Text("Find photos by content, people or places.")
                )
                .padding(.top, 80)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private func placeCard(_ item: ExploreItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let client = session.client {
                RemoteImage(url: client.thumbnailURL(assetID: item.data.id), targetPixelSize: 480, thumbhash: item.data.thumbhash)
                    .frame(width: 140, height: 180)
                    .clipped()
            }
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            Text(item.value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(10)
        }
        .frame(width: 140, height: 180)
        .clipShape(.rect(cornerRadius: 14))
    }

    // MARK: - data

    private func loadDiscover() async {
        guard let client = session.client else { return }
        async let peopleTask = try? client.people()
        async let placesTask = try? client.explorePlaces()
        people = (await peopleTask)?.people.filter { !($0.isHidden ?? false) } ?? []
        places = (await placesTask) ?? []
    }

    private func search(reset: Bool) async {
        guard let client = session.client, !query.isEmpty else { return }
        if reset {
            results = []
            nextPage = 1
        }
        guard let page = nextPage else { return }
        isSearching = true
        hasSearched = true
        defer { isSearching = false }
        if let response = try? await client.searchSmart(query: query, page: page) {
            results.append(contentsOf: response.assets.items.map { $0.asAsset() })
            nextPage = response.assets.nextPage.flatMap { Int($0) }
        }
    }
}

nonisolated struct PlaceLink: Hashable {
    let city: String
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

    @State private var assets: [Asset] = []
    @State private var isLoading = true
    @State private var viewer = ViewerPresentation()
    @Namespace private var zoomNamespace

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 200), spacing: 2)]

    var body: some View {
        @Bindable var viewer = viewer

        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                    AssetTile(asset: asset)
                        .matchedTransitionSource(id: asset.id, in: zoomNamespace)
                        .onTapGesture {
                            viewer.present(assets: assets, initialIndex: index)
                        }
                }
            }
        }
        .navigationTitle(city)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading {
                ProgressView()
            } else if assets.isEmpty {
                ContentUnavailableView("No photos", systemImage: "mappin.slash")
            }
        }
        .task {
            guard let client = session.client else { return }
            if let response = try? await client.searchMetadata(filters: [
                "city": AnyEncodable(city),
                "size": AnyEncodable(1000),
            ]) {
                assets = response.assets.items.map { $0.asAsset() }
            }
            isLoading = false
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
                    assets.removeAll { $0.id == id }
                }
            }
        }
    }
}
