import CoreLocation
import MapKit
import SwiftUI

struct LibraryTab: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var people: [Person] = []
    @State private var peopleTotal = 0
    @State private var isLoadingPeople = false
    @State private var path = NavigationPath()
    /// serializes the preview quick actions per person.
    @State private var mutatingPersonIDs = Set<String>()

    private static let peopleColumns = [
        GridItem(
            .fixed(LibraryPeoplePreview.cellWidth),
            spacing: LibraryPeoplePreview.gridSpacing,
            alignment: .top
        ),
        GridItem(
            .fixed(LibraryPeoplePreview.cellWidth),
            spacing: LibraryPeoplePreview.gridSpacing,
            alignment: .top
        )
    ]

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: LibraryDestination.favorites) {
                        Label("Favorites", systemImage: "heart")
                    }
                    NavigationLink(value: LibraryDestination.places) {
                        Label("Places", systemImage: "mappin.and.ellipse")
                    }
                    NavigationLink(value: LibraryDestination.archive) {
                        Label("Archive", systemImage: "archivebox")
                    }
                    if session.features?.trash != false {
                        NavigationLink(value: LibraryDestination.trash) {
                            Label("Trash", systemImage: "trash")
                        }
                    }
                }

                if !people.isEmpty && session.preferences?.peopleEnabled != false {
                    Section {
                        peopleGrid
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } header: {
                        Text("People")
                    }
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: LibraryDestination.self) { destination in
                switch destination {
                case .favorites:
                    TimelineScreen(
                        title: "Favorites",
                        filter: TimelineFilter(isFavorite: true),
                        emptyIcon: "heart",
                        emptyMessage: "No favorites yet",
                        showsLargeTitle: false
                    )
                case .archive:
                    TimelineScreen(
                        title: "Archive",
                        filter: TimelineFilter(visibility: .archive),
                        emptyIcon: "archivebox",
                        emptyMessage: "Nothing archived",
                        showsLargeTitle: false
                    )
                case .places:
                    PlacesScreen()
                case .people:
                    PeopleScreen()
                case .trash:
                    TrashScreen()
                }
            }
            .navigationDestination(for: Person.self) { person in
                PersonScreen(person: person)
            }
            .navigationDestination(for: PlaceLink.self) { place in
                PlaceScreen(city: place.city, coordinate: place.coordinate)
            }
            // restarts on every re-appearance, so pop-backs from people
            // screens pick up hides, merges and renames without a second
            // onAppear fetch racing this one.
            .task { await loadPeople() }
            // coming back to the app does not re-appear this tab, so an edit
            // made elsewhere meanwhile - a new featured photo - needs its own
            // pass.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, !people.isEmpty {
                    Task { await loadPeople() }
                }
            }
        }
    }

    private var peopleGrid: some View {
        LazyVGrid(columns: Self.peopleColumns, spacing: LibraryPeoplePreview.gridSpacing) {
            ForEach(LibraryPeoplePreview.people(from: people)) { person in
                Button {
                    path.append(person)
                } label: {
                    LibraryPersonPreviewCell(person: person)
                }
                .buttonStyle(PressableCardStyle())
                .disabled(mutatingPersonIDs.contains(person.id))
                .accessibilityLabel(LibraryPeoplePreview.accessibilityLabel(for: person))
                .contextMenu {
                    previewMenu(for: person)
                }
            }

            Button {
                path.append(LibraryDestination.people)
            } label: {
                LibraryAllPeoplePreviewCell(total: peopleTotal)
            }
            .buttonStyle(PressableCardStyle())
            .accessibilityLabel(allPeopleAccessibilityLabel)
            .accessibilityIdentifier("library-all-people")
        }
        .frame(width: LibraryPeoplePreview.gridWidth)
        .padding(LibraryPeoplePreview.containerPadding)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: .rect(cornerRadius: LibraryPeoplePreview.containerCornerRadius)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, LibraryPeoplePreview.verticalPadding)
    }

    private var allPeopleAccessibilityLabel: String {
        let noun = peopleTotal == 1 ? "person" : "people"
        return "See all \(peopleTotal) \(noun)"
    }

    @ViewBuilder private func previewMenu(for person: Person) -> some View {
        let isFavorite = person.isFavorite == true

        Button {
            Task { await setFavorite(person, to: !isFavorite) }
        } label: {
            Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.slash" : "heart")
        }

        Button {
            Task { await hide(person) }
        } label: {
            Label("Hide Person", systemImage: "eye.slash")
        }
    }

    private func loadPeople() async {
        guard !isLoadingPeople else { return }
        isLoadingPeople = true
        defer { isLoadingPeople = false }
        let account = session.client?.offlineAccountKey
        // the shared people cache paints the grid instantly, offline
        // included; the fetch below reconciles it.
        var cachedWasEmpty = true
        if people.isEmpty, let account {
            let cached = await Task.detached(priority: .userInitiated) {
                OfflineCache.value([Person].self, key: "people", account: account)
            }.value
            cachedWasEmpty = cached == nil
            if let cached, people.isEmpty, mutatingPersonIDs.isEmpty {
                let visible = cached.filter { !($0.isHidden ?? false) }
                people = visible
                peopleTotal = max(peopleTotal, visible.count)
            }
        }
        guard let response = try? await session.client?.people() else { return }
        // a refetch racing an in-flight optimistic mutation would resurrect
        // the value it is busy removing.
        guard mutatingPersonIDs.isEmpty else { return }
        let fresh = response.people.filter { !($0.isHidden ?? false) }
        if people != fresh { people = fresh }
        peopleTotal = max(fresh.count, response.total - (response.hidden ?? 0))
        // seed the cache only when the people screen has never written its
        // full list - this response may be a single page.
        if cachedWasEmpty, let account, !response.people.isEmpty {
            let snapshot = response.people
            Task.detached(priority: .utility) {
                OfflineCache.store(snapshot, key: "people", account: account)
            }
        }
    }

    private func setFavorite(_ person: Person, to value: Bool) async {
        guard let client = session.client, !mutatingPersonIDs.contains(person.id) else { return }
        mutatingPersonIDs.insert(person.id)
        defer { mutatingPersonIDs.remove(person.id) }
        let previous = person.isFavorite
        await OptimisticAction.perform(
            errorMessage: value ? "Couldn’t favorite this person" : "Couldn’t unfavorite this person",
            apply: { updatePerson(person.id) { $0.isFavorite = value } },
            rollback: { updatePerson(person.id) { $0.isFavorite = previous } },
            request: { try await client.updatePerson(id: person.id, isFavorite: value) }
        )
    }

    private func hide(_ person: Person) async {
        guard let client = session.client, !mutatingPersonIDs.contains(person.id) else { return }
        mutatingPersonIDs.insert(person.id)
        defer { mutatingPersonIDs.remove(person.id) }
        let snapshot = people
        let totalSnapshot = peopleTotal
        await OptimisticAction.perform(
            errorMessage: "Couldn’t hide this person",
            apply: {
                people.removeAll { $0.id == person.id }
                peopleTotal = max(0, peopleTotal - 1)
            },
            rollback: {
                people = snapshot
                peopleTotal = totalSnapshot
            },
            request: { try await client.updatePerson(id: person.id, isHidden: true) }
        )
    }

    private func updatePerson(_ id: String, _ mutation: (inout Person) -> Void) {
        guard let index = people.firstIndex(where: { $0.id == id }) else { return }
        mutation(&people[index])
    }
}

nonisolated enum LibraryDestination: Hashable {
    case favorites
    case places
    case people
    case archive
    case trash
}

/// map of every geotagged photo on top, searchable list of cities below - the
/// same shape the official mobile client gives its places page.
struct PlacesScreen: View {
    @Environment(SessionStore.self) private var session

    @State private var places: [(city: String, asset: AssetDetail)] = []
    @State private var isLoading = true
    @State private var isLoadingMarkers = true
    @State private var searchText = ""
    @State private var markers: [MapMarker] = []
    /// header dots and framing, clustered once off main when the markers
    /// land. clustering the full set inside the header's init ran on every
    /// body pass, on the main thread.
    @State private var headerDots: [MapCluster] = []
    @State private var headerFocus: MapBoundingBox?
    @State private var showMap = false

    private var visible: [(city: String, asset: AssetDetail)] {
        guard !searchText.isEmpty else { return places }
        return places.filter { $0.city.localizedStandardContains(searchText) }
    }

    private var showsMapHeader: Bool {
        searchText.isEmpty && !headerDots.isEmpty && session.features?.map != false
    }

    var body: some View {
        List {
            if showsMapHeader {
                Section {
                    Button {
                        showMap = true
                    } label: {
                        // the map inside refuses hits so it never eats the tap,
                        // which leaves the button with no shape of its own.
                        PlacesMapHeader(dots: headerDots, focus: headerFocus)
                            .contentShape(.rect(cornerRadius: 20))
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("places-map")
                }
            }

            Section {
                ForEach(visible, id: \.city) { place in
                    NavigationLink(value: PlaceLink(
                        city: place.city,
                        latitude: place.asset.exifInfo?.latitude,
                        longitude: place.asset.exifInfo?.longitude
                    )) {
                        HStack(spacing: 14) {
                            if let client = session.client {
                                RemoteImage(
                                    url: client.thumbnailURL(assetID: place.asset.id),
                                    targetPixelSize: 240,
                                    thumbhash: place.asset.thumbhash
                                )
                                .frame(width: 64, height: 64)
                                .clipShape(.rect(cornerRadius: 14))
                            }
                            Text(place.city)
                                .font(.body.weight(.medium))
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Filter places")
        .navigationDestination(isPresented: $showMap) {
            MapScreen()
        }
        .overlay {
            // both fetches count: cities alone answering empty while the
            // markers are still on the wire used to flash "no places".
            if isLoading || isLoadingMarkers {
                ProgressView()
            } else if places.isEmpty && markers.isEmpty {
                ContentUnavailableView("No places", systemImage: "mappin.slash")
            }
        }
        // keyed on client presence so a slow session start retries instead of
        // spinning forever behind a nil client.
        .task(id: session.client == nil) {
            guard places.isEmpty else { return }
            defer { isLoading = false }
            guard let client = session.client else { return }
            let assets = (try? await client.cities()) ?? []
            places = assets.compactMap { asset in
                guard let city = asset.exifInfo?.city, !city.isEmpty else { return nil }
                return (city: city, asset: asset)
            }
        }
        .task(id: session.client == nil) {
            guard markers.isEmpty else { return }
            defer { isLoadingMarkers = false }
            guard session.features?.map != false, let client = session.client else { return }
            // primes the cache the map screen reads, so opening it is instant.
            let fetched = (try? await MapMarkerCache.shared.markers(
                client: client,
                options: MapSettings.load().markerOptions
            )) ?? []
            markers = fetched
            guard !fetched.isEmpty else { return }
            let built = await Task.detached(priority: .userInitiated) {
                let clusters = MapClustering.clusters(markers: fetched, zoom: 4)
                    .sorted { $0.count > $1.count }
                return (
                    dots: Array(clusters.prefix(60)),
                    focus: MapClustering.focusBounds(of: clusters, coverage: 0.75)?.scaled(by: 1.5)
                )
            }.value
            headerDots = built.dots
            headerFocus = built.focus
        }
    }
}

/// non-interactive preview of the photo map, coarse enough that it reads as a
/// density plot rather than a pin soup.
private struct PlacesMapHeader: View {
    let dots: [MapCluster]
    let focus: MapBoundingBox?

    var body: some View {
        Map(initialPosition: focus.map { .rect($0.mapRect) } ?? .automatic, interactionModes: []) {
            ForEach(dots) { dot in
                Annotation("", coordinate: dot.coordinate) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 10, height: 10)
                        .overlay { Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5) }
                }
            }
            .annotationTitles(.hidden)
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .frame(height: 180)
        .clipShape(.rect(cornerRadius: 20))
        .allowsHitTesting(false)
        .overlay(alignment: .bottomTrailing) {
            Label("Open Map", systemImage: "map")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
                .padding(10)
        }
    }
}

struct TrashScreen: View {
    @State private var confirmEmpty = false
    @State private var serverCommand: TimelineServerCommand?

    var body: some View {
        TimelineScreen(
            title: "Trash",
            filter: TimelineFilter(visibility: nil, isTrashed: true),
            emptyIcon: "trash",
            emptyMessage: "Trash is empty",
            showsLargeTitle: false,
            serverCommand: $serverCommand
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        serverCommand = .restoreAllTrash
                    } label: {
                        Label("Restore All", systemImage: "arrow.uturn.backward")
                    }
                    Button(role: .destructive) {
                        confirmEmpty = true
                    } label: {
                        Label("Empty Trash", systemImage: "trash.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
                // ios 26 morphs the dialog out of its source control, so it sits
                // on the menu button - on the screen root it floats detached.
                .confirmationDialog("Permanently delete everything in the trash?", isPresented: $confirmEmpty, titleVisibility: .visible) {
                    Button("Empty Trash", role: .destructive) {
                        serverCommand = .emptyTrash
                    }
                }
            }
        }
    }
}
