import SwiftUI

/// edits the album name and description.
struct AlbumEditSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let album: Album
    let onSaved: () async -> Void

    @State private var name: String
    @State private var descriptionText: String
    @State private var isSaving = false
    @State private var error: String?

    init(album: Album, onSaved: @escaping () async -> Void) {
        self.album = album
        self.onSaved = onSaved
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
                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
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
                    .disabled(trimmedName.isEmpty || isSaving)
                    .accessibilityIdentifier("album-edit-save")
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func save() async {
        guard let client = session.client else { return }
        isSaving = true
        error = nil
        do {
            try await client.updateAlbum(
                id: album.id,
                name: trimmedName,
                description: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isSaving = false
        }
    }
}
