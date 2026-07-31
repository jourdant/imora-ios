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

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 180), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if model.isLoading && model.assets.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                } else {
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
                if let client = session.client { model.attach(client) }
                model.apply(SearchFilter(), allowEmpty: true)
            }
        }
    }

    @ViewBuilder private func tile(_ asset: Asset) -> some View {
        let isSelected = selection.contains(asset.id)
        AssetTile(asset: asset)
            .overlay(alignment: .topLeading) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isSelected ? Color.accentColor : .black.opacity(0.25))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy(duration: 0.22), value: isSelected)
                    .padding(6)
            }
            .overlay {
                if isSelected {
                    Rectangle().stroke(Color.accentColor, lineWidth: 3)
                }
            }
            .contentShape(.rect)
            .onTapGesture {
                if isSelected {
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
