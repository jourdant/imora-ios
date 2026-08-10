import SwiftUI

/// edits the album name and description.
struct AlbumEditSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let album: Album
    @Binding var isAlbumMutationInFlight: Bool
    let onAlbumChanged: (Album) -> Void

    @State private var name: String
    @State private var descriptionText: String
    @State private var isSaving = false

    init(
        album: Album,
        isAlbumMutationInFlight: Binding<Bool>,
        onAlbumChanged: @escaping (Album) -> Void
    ) {
        self.album = album
        _isAlbumMutationInFlight = isAlbumMutationInFlight
        self.onAlbumChanged = onAlbumChanged
        _name = State(initialValue: album.albumName)
        _descriptionText = State(initialValue: album.description)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Album name", text: $name)
                        .accessibilityIdentifier("album-edit-name")
                }
                Section("Description") {
                    TextField("Add a description", text: $descriptionText, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("album-edit-description")
                }
            }
            .navigationTitle("Edit Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(trimmedName.isEmpty || isSaving || isAlbumMutationInFlight)
                    .accessibilityIdentifier("album-edit-save")
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func save() async {
        guard let client = session.client else { return }
        guard !isSaving, !isAlbumMutationInFlight else { return }
        let optimistic = album.withDetails(
            name: trimmedName,
            description: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        isSaving = true
        isAlbumMutationInFlight = true
        defer {
            isSaving = false
            isAlbumMutationInFlight = false
        }
        await OptimisticAction.perform(
            errorMessage: "Couldn’t save the album.",
            apply: {
                onAlbumChanged(optimistic)
                dismiss()
            },
            rollback: { onAlbumChanged(album) },
            request: {
                try await client.updateAlbum(
                    id: album.id,
                    name: optimistic.albumName,
                    description: optimistic.description
                )
            }
        )
    }
}
