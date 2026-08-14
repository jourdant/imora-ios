import CoreLocation
import MapKit
import SwiftUI

struct LibraryTab: View {
    @Environment(SessionStore.self) private var session
    @State private var people: [Person] = []
    @State private var peopleTotal = 0
    /// serializes the carousel quick actions per person.
    @State private var mutatingPersonIDs = Set<String>()

    private static let carouselLimit = 16

    var body: some View {
        NavigationStack {
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
                        peopleCarousel
                            .listRowInsets(EdgeInsets())

                        NavigationLink(value: LibraryDestination.people) {
                            HStack {
                                Label("All People", systemImage: "person.2")
                                Spacer()
                                if peopleTotal > 0 {
                                    Text("\(peopleTotal)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("library-all-people")
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
            .task { await loadPeople() }
            // returning from people screens picks up hides, merges and renames.
            .onAppear {
                if !people.isEmpty {
                    Task { await loadPeople() }
                }
            }
        }
    }

    // MARK: - people carousel

    private var peopleCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(people.prefix(Self.carouselLimit)) { person in
                    NavigationLink(value: person) {
                        VStack(spacing: 7) {
                            PersonAvatar(person: person, targetPixelSize: 240)
                                .frame(width: 76, height: 76)
                            Text(person.name.isEmpty ? "Unnamed" : person.name)
                                .font(.caption)
                                .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .frame(width: 82)
                        }
                    }
                    .buttonStyle(PressableCardStyle())
                    .disabled(mutatingPersonIDs.contains(person.id))
                    .accessibilityLabel(person.name.isEmpty ? "Unnamed person" : person.name)
                    .contextMenu {
                        carouselMenu(for: person)
                    }
                }

                if peopleTotal > Self.carouselLimit || people.count > Self.carouselLimit {
                    NavigationLink(value: LibraryDestination.people) {
                        VStack(spacing: 7) {
                            Circle()
                                .fill(Color(.secondarySystemFill))
                                .frame(width: 76, height: 76)
                                .overlay {
                                    Image(systemName: "chevron.right")
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            Text("View All")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 82)
                        }
                    }
                    .buttonStyle(PressableCardStyle())
                    .accessibilityIdentifier("library-people-view-all")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder private func carouselMenu(for person: Person) -> some View {
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
        guard let response = try? await session.client?.people() else { return }
        people = response.people.filter { !($0.isHidden ?? false) }
        peopleTotal = max(people.count, response.total - (response.hidden ?? 0))
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
    @State private var searchText = ""
    @State private var markers: [MapMarker] = []
    @State private var showMap = false

    private var visible: [(city: String, asset: AssetDetail)] {
        guard !searchText.isEmpty else { return places }
        return places.filter { $0.city.localizedStandardContains(searchText) }
    }

    private var showsMapHeader: Bool {
        searchText.isEmpty && !markers.isEmpty && session.features?.map != false
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
                        PlacesMapHeader(markers: markers)
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
            if isLoading {
                ProgressView()
            } else if places.isEmpty && markers.isEmpty {
                ContentUnavailableView("No places", systemImage: "mappin.slash")
            }
        }
        .task {
            guard places.isEmpty, let client = session.client else { return }
            let assets = (try? await client.cities()) ?? []
            places = assets.compactMap { asset in
                guard let city = asset.exifInfo?.city, !city.isEmpty else { return nil }
                return (city: city, asset: asset)
            }
            isLoading = false
        }
        .task {
            guard markers.isEmpty, session.features?.map != false, let client = session.client else { return }
            // primes the cache the map screen reads, so opening it is instant.
            markers = (try? await MapMarkerCache.shared.markers(
                client: client,
                options: MapSettings.load().markerOptions
            )) ?? []
        }
    }
}

/// non-interactive preview of the photo map, coarse enough that it reads as a
/// density plot rather than a pin soup.
private struct PlacesMapHeader: View {
    private let dots: [MapCluster]
    private let focus: MapBoundingBox?

    init(markers: [MapMarker]) {
        let clusters = MapClustering.clusters(markers: markers, zoom: 4)
            .sorted { $0.count > $1.count }
        dots = Array(clusters.prefix(60))
        focus = MapClustering.focusBounds(of: clusters, coverage: 0.75)?.scaled(by: 1.5)
    }

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
