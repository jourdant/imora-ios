import SwiftUI

nonisolated struct AlbumMembershipUpdate: Equatable {
    nonisolated enum Change: Equatable {
        case project(Album)
        case commit(Album)
        case rollback(String)
        case replace(String, Album)
    }

    let id = UUID()
    let operationID: UUID
    let assetID: String
    let change: Change
}

/// pick an album for the current asset, or create a new one with it inside.
struct AddToAlbumSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session

    let assetIDs: [String]
    let onMembershipUpdate: (AlbumMembershipUpdate) -> Void
    let onDone: (String) -> Void

    init(
        assetIDs: [String],
        onMembershipUpdate: @escaping (AlbumMembershipUpdate) -> Void = { _ in },
        onDone: @escaping (String) -> Void
    ) {
        self.assetIDs = assetIDs
        self.onMembershipUpdate = onMembershipUpdate
        self.onDone = onDone
    }

    @State private var albums: [Album] = []
    @State private var containingIDs: Set<String> = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var query = ""
    @State private var showNewAlbum = false
    @State private var newAlbumName = ""

    private var visibleAlbums: [Album] {
        guard !query.isEmpty else { return albums }
        return albums.filter { $0.albumName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newAlbumName = ""
                        showNewAlbum = true
                    } label: {
                        Label("New Album", systemImage: "plus")
                    }
                    .disabled(isWorking || isLoading)
                    .accessibilityIdentifier("add-to-album-new")
                }

                Section {
                    ForEach(visibleAlbums) { album in
                        albumRow(album)
                    }
                } footer: {
                    if !isLoading, albums.isEmpty {
                        Text("No albums yet. Create one to get started.")
                    }
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                }
            }
            .searchable(text: $query, prompt: "Search albums")
            .navigationTitle("Add to Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load() }
            .alert("New Album", isPresented: $showNewAlbum) {
                TextField("Album name", text: $newAlbumName)
                Button("Create") {
                    Task { await createAlbum() }
                }
                .disabled(isWorking || newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .interactiveDismissDisabled(isWorking)
        }
    }

    @ViewBuilder private func albumRow(_ album: Album) -> some View {
        let alreadyIn = containingIDs.contains(album.id)

        Button {
            Task { await add(to: album) }
        } label: {
            HStack(spacing: 12) {
                if let client = session.client, let cover = album.albumThumbnailAssetId {
                    RemoteImage(url: client.thumbnailURL(assetID: cover), targetPixelSize: 120)
                        .frame(width: 48, height: 48)
                        .clipShape(.rect(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .frame(width: 48, height: 48)
                        .overlay {
                            Image(systemName: "rectangle.stack")
                                .foregroundStyle(.secondary)
                        }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(album.albumName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text("^[\(album.assetCount) item](inflect: true)")
                        if album.shared {
                            Text("·")
                            Text("Shared")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if alreadyIn {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(alreadyIn || isWorking)
    }

    // MARK: - actions

    private func load() async {
        guard let client = session.client else { return }
        // the albums tab's offline copy paints the list instantly while the
        // fresh one loads. membership ticks still wait for the server - a
        // guessed tick invites a duplicate add.
        if albums.isEmpty, let account = client.offlineAccountKey {
            let cached = await Task.detached(priority: .userInitiated) {
                OfflineCache.value([Album].self, key: "albums", account: account)
            }.value
            if let cached, albums.isEmpty {
                albums = cached.filter { !$0.isPending }.sorted { $0.updatedAt > $1.updatedAt }
            }
        }
        async let allTask = try? client.albums()
        async let containingTask = try? client.albums(assetID: assetIDs.first ?? "")
        let all = await allTask
        let containing = await containingTask ?? []
        // a failed refresh keeps the cached list instead of blanking it.
        if let all {
            albums = all.sorted { $0.updatedAt > $1.updatedAt }
        }
        containingIDs = Set(containing.map(\.id))
        isLoading = false
    }

    private func add(to album: Album) async {
        guard let client = session.client, !isWorking else { return }
        let requested = Set(assetIDs)
        let originalContaining = containingIDs
        let optimistic = album.withAssetCountDelta(requested.count)
        let operationID = UUID()
        isWorking = true
        defer { isWorking = false }
        let result = await OptimisticAction.perform(
            errorMessage: "Couldn’t add the selected items to the album.",
            apply: {
                containingIDs.insert(album.id)
                replaceAlbum(id: album.id, with: optimistic)
                emit(.project(optimistic), operationID: operationID)
                dismiss()
            },
            rollback: {
                containingIDs = originalContaining
                replaceAlbum(id: album.id, with: album)
                emit(.rollback(album.id), operationID: operationID)
            },
            request: { try await client.addAssets(albumID: album.id, ids: Array(requested)) },
            commit: { results in
                let outcome = BulkMutationOutcome(requestedIDs: requested, results: results)
                replaceAlbum(
                    id: album.id,
                    with: album.withAssetCountDelta(outcome.successfulIDs.count)
                )
                if !outcome.successfulIDs.isEmpty {
                    emit(
                        .commit(album.withAssetCountDelta(outcome.successfulIDs.count)),
                        operationID: operationID
                    )
                } else if !outcome.duplicateIDs.isEmpty {
                    emit(.commit(album), operationID: operationID)
                } else {
                    containingIDs = originalContaining
                    emit(.rollback(album.id), operationID: operationID)
                }
                reportFailures(outcome.failedIDs.count, action: "add")
            }
        )
        guard let results = result else { return }
        let outcome = BulkMutationOutcome(requestedIDs: requested, results: results)
        guard outcome.failedIDs.isEmpty else { return }
        if !outcome.successfulIDs.isEmpty {
            onDone("Added to \(album.albumName)")
        } else if !outcome.duplicateIDs.isEmpty {
            onDone("Already in \(album.albumName)")
        }
    }

    private func createAlbum() async {
        guard let client = session.client, !isWorking else { return }
        let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let pending = Album.pending(name: name, assetCount: Set(assetIDs).count)
        let operationID = UUID()
        isWorking = true
        defer { isWorking = false }
        let saved = await OptimisticAction.perform(
            errorMessage: "Couldn’t create the album.",
            apply: {
                newAlbumName = ""
                albums.insert(pending, at: 0)
                containingIDs.insert(pending.id)
                emit(.project(pending), operationID: operationID)
                dismiss()
            },
            rollback: {
                albums.removeAll { $0.id == pending.id }
                containingIDs.remove(pending.id)
                newAlbumName = name
                emit(.rollback(pending.id), operationID: operationID)
            },
            request: { try await client.createAlbum(name: name, assetIds: assetIDs) },
            commit: { album in
                replaceAlbum(id: pending.id, with: album)
                containingIDs.remove(pending.id)
                containingIDs.insert(album.id)
                emit(.replace(pending.id, album), operationID: operationID)
            }
        )
        if let saved { onDone("Added to \(saved.albumName)") }
    }

    private func replaceAlbum(id: String, with replacement: Album) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        albums[index] = replacement
    }

    private func reportFailures(_ count: Int, action: String) {
        guard count > 0 else { return }
        ErrorToastCenter.shared.show(
            "Couldn’t \(action) \(count) selected item\(count == 1 ? "" : "s")."
        )
    }

    private func emit(_ change: AlbumMembershipUpdate.Change, operationID: UUID) {
        guard let assetID = assetIDs.first else { return }
        onMembershipUpdate(AlbumMembershipUpdate(
            operationID: operationID,
            assetID: assetID,
            change: change
        ))
    }
}
