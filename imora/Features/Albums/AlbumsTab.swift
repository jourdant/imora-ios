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
    /// distinguishes "nothing yet" from "the server says none", so the first
    /// frame shows a spinner instead of flashing the empty state.
    @State private var hasLoaded = false
    @State private var loadFailed = false
    @State private var loadTask: Task<Void, Never>?
    @State private var isCreating = false
    @State private var showCreate = false
    @State private var newAlbumName = ""
    @State private var path = NavigationPath()
    @State private var pendingRemovalIDs = Set<String>()
    @State private var albumLoadGate = LatestAlbumLoadGate()
    @State private var pendingAlbumLoadGate = LatestAlbumLoadGate()
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
                            .disabled(album.isPending)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .navigationTitle("Albums")
            .navigationDestination(for: Album.self) { album in
                AlbumDetailScreen(
                    album: album,
                    onAlbumChanged: upsertAlbum,
                    onAlbumRemoved: removeAlbum,
                    onAlbumRestored: restoreAlbum,
                    onAlbumRemovalCommitted: commitAlbumRemoval
                )
            }
            .searchable(text: $searchText, prompt: "Album name")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(isCreating)
                    .accessibilityIdentifier("albums-create")
                }
            }
            .overlay {
                if albums.isEmpty {
                    if !hasLoaded {
                        ProgressView()
                    } else if loadFailed {
                        ContentUnavailableView {
                            Label("Couldn't load albums", systemImage: "wifi.exclamationmark")
                        } actions: {
                            Button("Retry") { reload() }
                                .buttonStyle(.glass)
                        }
                    } else {
                        ContentUnavailableView("No albums", systemImage: "rectangle.stack")
                    }
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
                    reload()
                }
            }
            // server-side album changes arrive over the realtime channel.
            .onChange(of: session.realtime?.albumsGeneration ?? 0) {
                reload()
            }
            .alert("New Album", isPresented: $showCreate) {
                TextField("Album name", text: $newAlbumName)
                Button("Create") {
                    Task { await createAlbum() }
                }
                .disabled(isCreating)
                Button("Cancel", role: .cancel) { newAlbumName = "" }
            }
        }
    }

    @ViewBuilder private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases, id: \.self) { item in
                    Button {
                        // no withAnimation: it would animate the whole grid
                        // diff of potentially thousands of cards. only the
                        // chip styling below animates.
                        filter = item
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
                    .animation(.smooth(duration: 0.2), value: filter)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
    }

    /// restarts the fetch, cancelling the one in flight: a burst of realtime
    /// album events or quick tab hops would otherwise stack whole-list
    /// downloads whose results are thrown away by the gate anyway.
    private func reload() {
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        let ticket = albumLoadGate.begin()
        isLoading = true
        let account = client.apiURL.host().map { SessionCache.accountKey(host: $0) }
        // a fresh tab paints the last known list first, and keeps it when the
        // server is unreachable. read and decoded off main - with enough
        // albums the file is megabytes and this used to hitch the tab open.
        if albums.isEmpty, let account {
            let cached = await Task.detached(priority: .userInitiated) {
                OfflineCache.value([Album].self, key: "albums", account: account)
            }.value
            // Pending rows are session projections. Persisting one could leave
            // a ghost album after the app is terminated mid-request.
            if let cached, albums.isEmpty, albumLoadGate.accepts(ticket) {
                albums = cached.filter { !$0.isPending }
            }
        }
        let fetched = try? await client.albums()
        guard albumLoadGate.accepts(ticket) else { return }
        if let fetched {
            loadFailed = false
            let pending = albums.filter(\.isPending)
            let currentByID = Dictionary(
                albums.lazy.filter { !$0.isPending }.map { ($0.id, $0) },
                uniquingKeysWith: { current, _ in current }
            )
            let reconciled = fetched
                .filter { !pendingRemovalIDs.contains($0.id) }
                .filter { fetched in !pending.contains { $0.id == fetched.id } }
                .map { fetched in
                    currentByID[fetched.id]?.reconcilingServerVersion(fetched) ?? fetched
                }
                .sorted { $0.updatedAt > $1.updatedAt }
            let merged = pending + reconciled
            // most reloads confirm what is already on screen; skipping the
            // assignment spares a full grid diff over every album.
            if albums != merged {
                albums = merged
                if let account {
                    let snapshot = merged.filter { !$0.isPending }
                    Task.detached(priority: .utility) {
                        OfflineCache.store(snapshot, key: "albums", account: account)
                    }
                }
            }
        } else if !Task.isCancelled {
            loadFailed = true
        }
        isLoading = false
        hasLoaded = true
    }

    private func createAlbum() async {
        let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = session.client, !name.isEmpty, !isCreating else { return }
        let pending = Album.pending(name: name, owner: session.user)
        isCreating = true
        defer { isCreating = false }
        await OptimisticAction.perform(
            errorMessage: "Couldn’t create the album.",
            apply: {
                newAlbumName = ""
                upsertAlbum(pending)
            },
            rollback: {
                removeProjectedAlbum(id: pending.id)
                newAlbumName = name
            },
            request: { try await client.createAlbum(name: name) },
            commit: { replaceAlbum(id: pending.id, with: $0) }
        )
    }

    private func upsertAlbum(_ album: Album) {
        invalidateAlbumLoads()
        if let index = albums.firstIndex(where: { $0.id == album.id }) {
            albums[index] = album
        } else {
            albums.insert(album, at: 0)
        }
    }

    private func replaceAlbum(id: String, with album: Album) {
        invalidateAlbumLoads()
        albums.removeAll { $0.id == id || $0.id == album.id }
        albums.insert(album, at: 0)
    }

    private func removeAlbum(_ album: Album) {
        invalidateAlbumLoads()
        pendingRemovalIDs.insert(album.id)
        albums.removeAll { $0.id == album.id }
    }

    private func restoreAlbum(_ album: Album) {
        pendingRemovalIDs.remove(album.id)
        upsertAlbum(album)
        // Reopen only when the user stayed on the albums root. If they already
        // navigated elsewhere while the request failed, restoring the list row
        // is the least surprising precise rollback.
        if path.isEmpty { path.append(album) }
    }

    private func commitAlbumRemoval(_ albumID: String) {
        invalidateAlbumLoads()
        pendingRemovalIDs.remove(albumID)
    }

    private func removeProjectedAlbum(id: String) {
        invalidateAlbumLoads()
        albums.removeAll { $0.id == id }
    }

    private func invalidateAlbumLoads() {
        albumLoadGate.invalidate()
        isLoading = false
    }

    private func openPendingAlbum() async {
        guard let id = router.pendingAlbumID else { return }
        guard let client = session.client else {
            // Preserve the previous one-shot notification behavior when no
            // authenticated client is available to resolve the destination.
            router.pendingAlbumID = nil
            return
        }
        let ticket = pendingAlbumLoadGate.begin()
        let album = try? await client.album(id: id)
        guard pendingAlbumLoadGate.accepts(ticket), router.pendingAlbumID == id else { return }
        router.pendingAlbumID = nil
        guard let album, !Task.isCancelled else { return }
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
    let onApplied: () -> Void
    let onRollback: (Set<String>) -> Void

    @State private var albums: [Album] = []
    @State private var newAlbumName = ""
    @State private var showCreate = false
    @State private var isWorking = false
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showCreate = true
                    } label: {
                        Label("New Album", systemImage: "plus")
                    }
                    .disabled(isWorking || isLoading)
                }
                Section {
                    ForEach(albums) { album in
                        Button {
                            Task { await add(to: album) }
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
                        .disabled(isWorking || isLoading)
                    }
                }
            }
            .navigationTitle("Add to Album")
            .navigationBarTitleDisplayMode(.inline)
            // without this the sheet reads as "you have no albums" for the
            // whole length of a slow fetch. no empty state on purpose - the
            // new album row is the affordance and an overlay would cover it.
            .overlay {
                if isLoading && albums.isEmpty {
                    ProgressView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                defer { isLoading = false }
                if let fetched = try? await session.client?.albums(isOwned: true) {
                    albums = fetched.sorted { $0.updatedAt > $1.updatedAt }
                }
            }
            .alert("New Album", isPresented: $showCreate) {
                TextField("Album name", text: $newAlbumName)
                Button("Create & Add") {
                    Task { await createAndAdd() }
                }
                .disabled(
                    isWorking
                        || newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                Button("Cancel", role: .cancel) { newAlbumName = "" }
            }
            .interactiveDismissDisabled(isWorking)
        }
    }

    private func add(to album: Album) async {
        guard let client = session.client, !isWorking else { return }
        let requested = Set(assetIDs)
        let optimistic = album.withAssetCountDelta(requested.count)
        isWorking = true
        defer { isWorking = false }
        await OptimisticAction.perform(
            errorMessage: "Couldn’t add the selected items to the album.",
            apply: {
                replaceAlbum(id: album.id, with: optimistic)
                dismiss()
                onApplied()
            },
            rollback: {
                replaceAlbum(id: album.id, with: album)
                onRollback(requested)
            },
            request: { try await client.addAssets(albumID: album.id, ids: Array(requested)) },
            commit: { results in
                let outcome = BulkMutationOutcome(requestedIDs: requested, results: results)
                replaceAlbum(
                    id: album.id,
                    with: album.withAssetCountDelta(outcome.successfulIDs.count)
                )
                reportBulkFailures(outcome)
                if !outcome.failedIDs.isEmpty { onRollback(outcome.failedIDs) }
            }
        )
    }

    private func createAndAdd() async {
        let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = session.client, !name.isEmpty, !isWorking else { return }
        let requested = Set(assetIDs)
        let pending = Album.pending(name: name, assetCount: requested.count)
        isWorking = true
        defer { isWorking = false }
        await OptimisticAction.perform(
            errorMessage: "Couldn’t create the album.",
            apply: {
                newAlbumName = ""
                albums.insert(pending, at: 0)
                dismiss()
                onApplied()
            },
            rollback: {
                albums.removeAll { $0.id == pending.id }
                newAlbumName = name
                onRollback(requested)
            },
            request: { try await client.createAlbum(name: name, assetIds: assetIDs) },
            commit: { replaceAlbum(id: pending.id, with: $0) }
        )
    }

    private func replaceAlbum(id: String, with replacement: Album) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        albums[index] = replacement
    }

    private func reportBulkFailures(_ outcome: BulkMutationOutcome) {
        guard !outcome.failedIDs.isEmpty else { return }
        ErrorToastCenter.shared.show(
            "Couldn’t add \(outcome.failedIDs.count) selected item\(outcome.failedIDs.count == 1 ? "" : "s") to the album."
        )
    }
}
