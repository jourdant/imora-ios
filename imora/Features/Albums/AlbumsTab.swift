import SwiftUI

struct AlbumsTab: View {
    @Environment(SessionStore.self) private var session

    private enum Filter: String, CaseIterable {
        case all = "All"
        case mine = "Mine"
        case shared = "Shared"
    }

    @State private var albums: [Album] = []
    @State private var filter: Filter = .all
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var showCreate = false
    @State private var newAlbumName = ""
    @State private var path = NavigationPath()
    private var router: NotificationRouter { .shared }

    private var visibleAlbums: [Album] {
        var result = albums
        switch filter {
        case .all: break
        case .mine: result = result.filter { $0.owner?.id == session.user?.id }
        case .shared: result = result.filter(\.shared)
        }
        if !searchText.isEmpty {
            result = result.filter { $0.albumName.localizedCaseInsensitiveContains(searchText) }
        }
        return result
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    filterChips

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 18) {
                        ForEach(visibleAlbums) { album in
                            NavigationLink(value: album) {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(PressableCardStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .navigationTitle("Albums")
            .navigationDestination(for: Album.self) { album in
                AlbumDetailScreen(album: album)
            }
            .searchable(text: $searchText, prompt: "Album name")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("albums-create")
                }
            }
            .overlay {
                if isLoading && albums.isEmpty {
                    ProgressView()
                } else if albums.isEmpty && !isLoading {
                    ContentUnavailableView("No albums", systemImage: "rectangle.stack")
                }
            }
            .task { await load() }
            // a notification tap arrives as an id; .task(id:) also covers the
            // case where this tab is only created by the switch itself.
            .task(id: router.pendingAlbumID) { await openPendingAlbum() }
            // reloads after returning from a detail where the album may have
            // been renamed or deleted. the initial load stays with .task.
            .onAppear {
                if !albums.isEmpty {
                    Task { await load() }
                }
            }
            // server-side album changes arrive over the realtime channel.
            .onChange(of: session.realtime?.albumsGeneration ?? 0) {
                Task { await load() }
            }
            .alert("New Album", isPresented: $showCreate) {
                TextField("Album name", text: $newAlbumName)
                Button("Create") {
                    Task { await createAlbum() }
                }
                Button("Cancel", role: .cancel) { newAlbumName = "" }
            }
        }
    }

    @ViewBuilder private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases, id: \.self) { item in
                    Button {
                        withAnimation(.smooth(duration: 0.2)) { filter = item }
                    } label: {
                        Text(item.rawValue)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        filter == item ? .regular.tint(.indigo.opacity(0.7)) : .regular,
                        in: .capsule
                    )
                    .foregroundStyle(filter == item ? .white : .primary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        isLoading = true
        let account = client.apiURL.host().map { SessionCache.accountKey(host: $0) }
        // a fresh tab paints the last known list first, and keeps it when the
        // server is unreachable.
        if albums.isEmpty, let account,
           let cached: [Album] = OfflineCache.value(key: "albums", account: account) {
            albums = cached
        }
        if let fetched = try? await client.albums() {
            albums = fetched.sorted { $0.updatedAt > $1.updatedAt }
            if let account {
                let snapshot = albums
                Task.detached(priority: .utility) {
                    OfflineCache.store(snapshot, key: "albums", account: account)
                }
            }
        }
        isLoading = false
    }

    private func createAlbum() async {
        guard let client = session.client, !newAlbumName.isEmpty else { return }
        _ = try? await client.createAlbum(name: newAlbumName)
        newAlbumName = ""
        await load()
    }

    private func openPendingAlbum() async {
        guard let id = router.pendingAlbumID else { return }
        defer { router.pendingAlbumID = nil }
        guard let album = try? await session.client?.album(id: id) else { return }
        path = NavigationPath()
        path.append(album)
    }
}

struct AlbumCard: View {
    @Environment(SessionStore.self) private var session
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // clear square keeps the fill image bounded to the grid cell.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let thumbID = album.albumThumbnailAssetId, let client = session.client {
                        RemoteImage(url: client.thumbnailURL(assetID: thumbID), targetPixelSize: 640)
                    } else {
                        Rectangle()
                            .fill(Color(.secondarySystemFill))
                            .overlay {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.title)
                                    .foregroundStyle(.tertiary)
                            }
                    }
                }
                .clipShape(.rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text(album.albumName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text("\(album.assetCount) item\(album.assetCount == 1 ? "" : "s")")
                    if album.shared {
                        Image(systemName: "person.2.fill")
                            .font(.caption2)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// sheet used by multi-select to add assets to an album.
struct AlbumPickerSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    let assetIDs: [String]
    let onDone: () -> Void

    @State private var albums: [Album] = []
    @State private var newAlbumName = ""
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showCreate = true
                    } label: {
                        Label("New Album", systemImage: "plus")
                    }
                }
                Section {
                    ForEach(albums) { album in
                        Button {
                            Task { await add(to: album.id) }
                        } label: {
                            HStack(spacing: 12) {
                                if let thumbID = album.albumThumbnailAssetId, let client = session.client {
                                    RemoteImage(url: client.thumbnailURL(assetID: thumbID), targetPixelSize: 120)
                                        .frame(width: 44, height: 44)
                                        .clipShape(.rect(cornerRadius: 8))
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(.secondarySystemFill))
                                        .frame(width: 44, height: 44)
                                }
                                VStack(alignment: .leading) {
                                    Text(album.albumName)
                                        .foregroundStyle(.primary)
                                    Text("\(album.assetCount) items")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                if let fetched = try? await session.client?.albums(isOwned: true) {
                    albums = fetched.sorted { $0.updatedAt > $1.updatedAt }
                }
            }
            .alert("New Album", isPresented: $showCreate) {
                TextField("Album name", text: $newAlbumName)
                Button("Create & Add") {
                    Task { await createAndAdd() }
                }
                Button("Cancel", role: .cancel) { newAlbumName = "" }
            }
        }
    }

    private func add(to albumID: String) async {
        _ = try? await session.client?.addAssets(albumID: albumID, ids: assetIDs)
        dismiss()
        onDone()
    }

    private func createAndAdd() async {
        guard let client = session.client, !newAlbumName.isEmpty else { return }
        _ = try? await client.createAlbum(name: newAlbumName, assetIds: assetIDs)
        newAlbumName = ""
        dismiss()
        onDone()
    }
}
