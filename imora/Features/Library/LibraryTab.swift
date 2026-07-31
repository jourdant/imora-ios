import SwiftUI

struct LibraryTab: View {
    @Environment(SessionStore.self) private var session
    @State private var people: [Person] = []

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
                    Section("People") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(people.prefix(24)) { person in
                                    NavigationLink(value: person) {
                                        VStack(spacing: 6) {
                                            if let client = session.client {
                                                RemoteImage(url: client.personThumbnailURL(personID: person.id), targetPixelSize: 160)
                                                    .frame(width: 64, height: 64)
                                                    .clipShape(.circle)
                                            }
                                            Text(person.name.isEmpty ? "Unnamed" : person.name)
                                                .font(.caption2)
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                                .frame(width: 68)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 0))
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
                case .trash:
                    TrashScreen()
                }
            }
            .navigationDestination(for: Person.self) { person in
                PersonScreen(person: person)
            }
            .navigationDestination(for: PlaceLink.self) { place in
                PlaceScreen(city: place.city)
            }
            .task {
                if let response = try? await session.client?.people() {
                    people = response.people.filter { !($0.isHidden ?? false) }
                }
            }
        }
    }
}

nonisolated enum LibraryDestination: Hashable {
    case favorites
    case places
    case archive
    case trash
}

/// searchable list of cities, one representative photo each.
struct PlacesScreen: View {
    @Environment(SessionStore.self) private var session

    @State private var places: [(city: String, asset: AssetDetail)] = []
    @State private var isLoading = true
    @State private var searchText = ""

    private var visible: [(city: String, asset: AssetDetail)] {
        guard !searchText.isEmpty else { return places }
        return places.filter { $0.city.localizedStandardContains(searchText) }
    }

    var body: some View {
        List(visible, id: \.city) { place in
            NavigationLink(value: PlaceLink(city: place.city)) {
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
        .listStyle(.plain)
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Filter places")
        .overlay {
            if isLoading {
                ProgressView()
            } else if places.isEmpty {
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
    }
}

struct TrashScreen: View {
    @Environment(SessionStore.self) private var session
    @State private var confirmEmpty = false

    var body: some View {
        TimelineScreen(
            title: "Trash",
            filter: TimelineFilter(visibility: nil, isTrashed: true),
            emptyIcon: "trash",
            emptyMessage: "Trash is empty",
            showsLargeTitle: false
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { try? await session.client?.restoreTrash() }
                    } label: {
                        Label("Restore All", systemImage: "arrow.uturn.backward")
                    }
                    Button(role: .destructive) {
                        confirmEmpty = true
                    } label: {
                        Label("Empty Trash", systemImage: "trash.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Permanently delete everything in the trash?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) {
                Task { try? await session.client?.emptyTrash() }
            }
        }
    }
}
