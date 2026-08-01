import SwiftUI

/// paged library grid used to pick photos to add to an album. the server
/// dedups anything already in the album, so only real additions count.
struct AlbumAddAssetsSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let album: Album
    let onAdded: (Int) async -> Void

    @State private var model = SearchModel()
    @State private var selection = Set<String>()
    @State private var isAdding = false
    @State private var error: String?
    /// what the album already holds. both official clients show these in the
    /// picker as already ticked and locked, so the grid reads as the album's
    /// contents plus whatever else you are adding.
    @State private var existingIDs: Set<String> = []
    @State private var membershipFailed = false

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 180), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if model.isLoading && model.assets.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                } else {
                    if membershipFailed {
                        Label("Couldn't check what's already in this album", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }

                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(Array(model.assets.enumerated()), id: \.element.id) { index, asset in
                            tile(asset)
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
                    }
                }
            }
            .navigationTitle("Add Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selection.isEmpty ? "Add" : "Add (\(selection.count))") {
                        Task { await add() }
                    }
                    .disabled(selection.isEmpty || isAdding)
                    .accessibilityIdentifier("album-picker-add")
                }
            }
            .interactiveDismissDisabled(isAdding)
            .alert("Couldn't add photos", isPresented: .init(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
            .task {
                guard let client = session.client else { return }
                model.attach(client)
                model.apply(SearchFilter(), allowEmpty: true)
                do {
                    let members = try await client.albumAssetIDs(id: album.id)
                    existingIDs = members
                    // anything ticked before the album answered is already in it.
                    selection.subtract(members)
                } catch {
                    // saying so beats a grid that silently claims the album is
                    // empty; adding still works, the server rejects duplicates.
                    membershipFailed = true
                }
            }
        }
    }

    @ViewBuilder private func tile(_ asset: Asset) -> some View {
        let isMember = existingIDs.contains(asset.id)
        // a member reads as ticked like anything else picked in this session,
        // just in grey and immovable - the immich clients both inset and lock
        // these rather than hiding them.
        let isTicked = isMember || selection.contains(asset.id)
        let tint = isMember ? Color.secondary : Color.accentColor
        AssetTile(asset: asset)
            // rounded first, then inset over a tinted cell: a ticked photo
            // shrinks back to reveal the tint, the way both clients do it.
            .clipShape(.rect(cornerRadius: isTicked ? 12 : 0))
            .padding(isTicked ? 6 : 0)
            .background(isTicked ? tint.opacity(isMember ? 0.22 : 0.35) : .clear)
            .overlay(alignment: .topLeading) {
                Image(systemName: isTicked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isTicked ? tint : .black.opacity(0.25))
                    .contentTransition(.symbolEffect(.replace))
                    .padding(6)
                    .accessibilityIdentifier(isMember ? "album-picker-member" : "album-picker-tick")
            }
            .animation(.snappy(duration: 0.22), value: isTicked)
            .contentShape(.rect)
            .onTapGesture {
                guard !isMember else { return }
                if selection.contains(asset.id) {
                    selection.remove(asset.id)
                } else {
                    selection.insert(asset.id)
                }
            }
    }

    private func add() async {
        guard let client = session.client else { return }
        isAdding = true
        do {
            let results = try await client.addAssets(albumID: album.id, ids: Array(selection))
            // duplicates come back as failures; only real additions count.
            let added = results.count(where: \.success)
            dismiss()
            await onAdded(added)
        } catch {
            self.error = error.localizedDescription
            isAdding = false
        }
    }
}
