import SwiftUI

/// pick an album for the current asset, or create a new one with it inside.
struct AddToAlbumSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session

    let assetIDs: [String]
    let onDone: (String) -> Void

    @State private var albums: [Album] = []
    @State private var containingIDs: Set<String> = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var query = ""
    @State private var showNewAlbum = false
    @State private var newAlbumName = ""
    @State private var error: String?

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
                    .disabled(isWorking)
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
                Button("Cancel", role: .cancel) {}
            }
            .alert(error ?? "", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) {}
            }
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
        async let allTask = try? client.albums()
        async let containingTask = try? client.albums(assetID: assetIDs.first ?? "")
        let all = await allTask ?? []
        let containing = await containingTask ?? []
        albums = all.sorted { $0.updatedAt > $1.updatedAt }
        containingIDs = Set(containing.map(\.id))
        isLoading = false
    }

    private func add(to album: Album) async {
        guard let client = session.client else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let results = try await client.addAssets(albumID: album.id, ids: assetIDs)
            let added = results.filter(\.success).count
            let duplicates = results.filter { $0.error == "duplicate" }.count
            if added > 0 {
                onDone("Added to \(album.albumName)")
            } else if duplicates > 0 {
                onDone("Already in \(album.albumName)")
            } else {
                onDone("Could not add to \(album.albumName)")
            }
            dismiss()
        } catch {
            self.error = "Could not add to the album: \(error.localizedDescription)"
        }
    }

    private func createAlbum() async {
        guard let client = session.client else { return }
        let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let album = try await client.createAlbum(name: name, assetIds: assetIDs)
            onDone("Added to \(album.albumName)")
            dismiss()
        } catch {
            self.error = "Could not create the album: \(error.localizedDescription)"
        }
    }
}
