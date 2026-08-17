import SwiftUI

/// paged library grid used to pick photos to add to an album. the server
/// dedups anything already in the album, so only real additions count.
struct AlbumAddAssetsSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let album: Album
    @Binding var isAlbumMutationInFlight: Bool
    let onAlbumChanged: (Album) -> Void
    /// The count always drives a grid resync. The flag suppresses success UI
    /// when the same bulk response already needs to present an error toast.
    let onAdded: (_ count: Int, _ showSuccessFeedback: Bool) -> Void

    @State private var model = SearchModel()
    @State private var selection = Set<String>()
    @State private var isAdding = false
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
                } else if model.assets.isEmpty {
                    // an empty library or a failed page otherwise rendered a
                    // silent blank sheet.
                    if model.loadFailed {
                        ContentUnavailableView {
                            Label("Couldn't load photos", systemImage: "wifi.exclamationmark")
                        } actions: {
                            Button("Retry") { model.loadMore() }
                                .buttonStyle(.glass)
                        }
                        .padding(.top, 60)
                    } else {
                        ContentUnavailableView("No photos to add", systemImage: "photo.on.rectangle")
                            .padding(.top, 60)
                    }
                } else {
                    if membershipFailed {
                        Label("Couldn't check what's already in this album", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }

                    // ids rather than indices: enumerating copied every asset
                    // in the grid on every pass just to find the tail.
                    let paginationIDs = Set(model.assets.suffix(12).lazy.map(\.id))
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(model.assets) { asset in
                            tile(asset)
                                .onAppear {
                                    if paginationIDs.contains(asset.id) {
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
                    .disabled(selection.isEmpty || isAdding || isAlbumMutationInFlight)
                    .accessibilityIdentifier("album-picker-add")
                }
            }
            .interactiveDismissDisabled(isAdding)
            .task {
                guard let client = session.client else { return }
                model.attach(client)
                model.apply(SearchFilter(), allowEmpty: true)
                do {
                    // pages stream in, so members lock as each one answers
                    // instead of after a huge album's full pagination walk.
                    // anything ticked before its page answered is already in
                    // the album and unticks then.
                    try await client.albumAssetIDs(id: album.id) { pageIDs in
                        existingIDs.formUnion(pageIDs)
                        selection.subtract(pageIDs)
                    }
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
        guard let client = session.client, !isAdding, !isAlbumMutationInFlight else { return }
        let requested = selection
        let optimistic = album.withAssetCountDelta(requested.count)
        isAdding = true
        isAlbumMutationInFlight = true
        defer {
            isAdding = false
            isAlbumMutationInFlight = false
        }
        await OptimisticAction.perform(
            errorMessage: "Couldn’t add the selected photos.",
            apply: {
                onAlbumChanged(optimistic)
                dismiss()
            },
            rollback: { onAlbumChanged(album) },
            request: { try await client.addAssets(albumID: album.id, ids: Array(requested)) },
            commit: { results in
                let outcome = BulkMutationOutcome(requestedIDs: requested, results: results)
                onAlbumChanged(album.withAssetCountDelta(outcome.successfulIDs.count))
                if !outcome.successfulIDs.isEmpty {
                    onAdded(outcome.successfulIDs.count, outcome.failedIDs.isEmpty)
                }
                reportFailures(outcome.failedIDs.count)
            }
        )
    }

    private func reportFailures(_ count: Int) {
        guard count > 0 else { return }
        ErrorToastCenter.shared.show(
            "Couldn’t add \(count) selected photo\(count == 1 ? "" : "s")."
        )
    }
}
