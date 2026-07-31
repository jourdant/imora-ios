import SwiftUI

/// expiry presets matching the official client's shared link form.
private enum LinkExpiry: String, CaseIterable, Identifiable {
    case keep
    case never
    case minutes30
    case hour1
    case hours6
    case day1
    case days7
    case days30
    case months3
    case year1

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep: "Keep current"
        case .never: "Never"
        case .minutes30: "After 30 minutes"
        case .hour1: "After 1 hour"
        case .hours6: "After 6 hours"
        case .day1: "After 1 day"
        case .days7: "After 7 days"
        case .days30: "After 30 days"
        case .months3: "After 3 months"
        case .year1: "After 1 year"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .keep, .never: nil
        case .minutes30: 30 * 60
        case .hour1: 3_600
        case .hours6: 6 * 3_600
        case .day1: 86_400
        case .days7: 7 * 86_400
        case .days30: 30 * 86_400
        case .months3: 90 * 86_400
        case .year1: 365 * 86_400
        }
    }
}

/// lists the album's public links and hosts the create and edit form.
struct AlbumShareLinksSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let album: Album
    let onChanged: () async -> Void

    @State private var links: [SharedLink] = []
    @State private var isLoading = true
    @State private var webBase: URL?
    @State private var createdURL: URL?
    @State private var linkToDelete: SharedLink?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let createdURL {
                    Section("Link created and copied") {
                        HStack {
                            Text(createdURL.absoluteString)
                                .font(.footnote.monospaced())
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Spacer()
                            ShareLink(item: createdURL) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .accessibilityIdentifier("album-share-created")
                    }
                }

                Section {
                    NavigationLink {
                        SharedLinkForm(album: album, existing: nil) { link in
                            await handleCreated(link)
                        }
                    } label: {
                        Label("New Shared Link", systemImage: "plus")
                    }
                    .accessibilityIdentifier("album-share-new")
                }

                if !links.isEmpty {
                    Section("Active links") {
                        ForEach(links) { link in
                            linkRow(link)
                        }
                    }
                }

                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                }
            }
            .navigationTitle("Share Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .confirmationDialog(
                "Delete this shared link?",
                isPresented: .init(
                    get: { linkToDelete != nil },
                    set: { if !$0 { linkToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Link", role: .destructive) {
                    if let link = linkToDelete {
                        Task { await delete(link) }
                    }
                }
            } message: {
                Text("People with this link will lose access.")
            }
        }
    }

    @ViewBuilder private func linkRow(_ link: SharedLink) -> some View {
        NavigationLink {
            SharedLinkForm(album: album, existing: link) { _ in
                await reload()
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(linkTitle(link))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(linkSubtitle(link))
                    .font(.caption)
                    .foregroundStyle(link.isExpired ? .red : .secondary)
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                linkToDelete = link
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            if let url = shareURL(for: link) {
                Button {
                    UIPasteboard.general.string = url.absoluteString
                } label: {
                    Label("Copy Link", systemImage: "doc.on.doc")
                }
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            Button(role: .destructive) {
                linkToDelete = link
            } label: {
                Label("Delete Link", systemImage: "trash")
            }
        }
    }

    private func linkTitle(_ link: SharedLink) -> String {
        if let description = link.description, !description.isEmpty { return description }
        if let slug = link.slug, !slug.isEmpty { return "/s/\(slug)" }
        return "Public link"
    }

    private func linkSubtitle(_ link: SharedLink) -> String {
        var parts: [String] = []
        if let expiry = link.expiryDate {
            if link.isExpired {
                parts.append("Expired")
            } else {
                parts.append("Expires \(expiry.formatted(.relative(presentation: .named)))")
            }
        } else {
            parts.append("Never expires")
        }
        if link.password?.isEmpty == false { parts.append("password") }
        if link.allowUpload { parts.append("upload") }
        if !link.allowDownload { parts.append("no download") }
        return parts.joined(separator: " · ")
    }

    private func shareURL(for link: SharedLink) -> URL? {
        webBase?.appending(path: link.sharePath)
    }

    // MARK: - actions

    private func load() async {
        guard let client = session.client else { return }
        webBase = await client.serverWebURL()
        await reload()
        isLoading = false
    }

    private func reload() async {
        guard let client = session.client else { return }
        do {
            links = try await client.sharedLinks(albumID: album.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func handleCreated(_ link: SharedLink) async {
        await reload()
        await onChanged()
        if let url = shareURL(for: link) {
            UIPasteboard.general.string = url.absoluteString
            createdURL = url
        }
    }

    private func delete(_ link: SharedLink) async {
        guard let client = session.client else { return }
        do {
            try await client.deleteSharedLink(id: link.id)
            if shareURL(for: link) == createdURL { createdURL = nil }
            await reload()
            await onChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - form

/// create or edit form for one shared link.
private struct SharedLinkForm: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let album: Album
    let existing: SharedLink?
    let onSaved: (SharedLink) async -> Void

    @State private var options: SharedLinkOptions
    @State private var expiry: LinkExpiry
    @State private var isSaving = false
    @State private var error: String?

    init(album: Album, existing: SharedLink?, onSaved: @escaping (SharedLink) async -> Void) {
        self.album = album
        self.existing = existing
        self.onSaved = onSaved
        _options = State(initialValue: existing.map(SharedLinkOptions.init(from:)) ?? SharedLinkOptions())
        _expiry = State(initialValue: existing == nil ? .never : .keep)
    }

    var body: some View {
        Form {
            Section("Description") {
                TextField("What is this link for?", text: $options.description)
            }
            Section {
                TextField("No password", text: $options.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Password")
            } footer: {
                Text("Viewers must enter this password to open the link.")
            }
            Section {
                TextField("my-album", text: $options.slug)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Custom URL")
            } footer: {
                Text("Served at /s/your-text instead of a random key.")
            }
            Section {
                Toggle("Show metadata", isOn: $options.showMetadata)
                Toggle("Allow downloads", isOn: $options.allowDownload)
                Toggle("Allow uploads", isOn: $options.allowUpload)
            }
            Section("Expiration") {
                Picker("Expire", selection: $expiry) {
                    ForEach(availableExpiries) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .accessibilityIdentifier("share-link-expiry")
            }
        }
        .alert("Couldn't save the link", isPresented: .init(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        .navigationTitle(existing == nil ? "New Link" : "Edit Link")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(existing == nil ? "Create" : "Save") {
                    Task { await save() }
                }
                .disabled(isSaving)
                .accessibilityIdentifier("share-link-save")
            }
        }
    }

    /// "keep current" only makes sense while editing.
    private var availableExpiries: [LinkExpiry] {
        existing == nil ? LinkExpiry.allCases.filter { $0 != .keep } : LinkExpiry.allCases
    }

    private func save() async {
        guard let client = session.client else { return }
        isSaving = true
        error = nil

        var resolved = options
        switch expiry {
        case .keep:
            resolved.expiresAt = existing?.expiryDate
        case .never:
            resolved.expiresAt = nil
        default:
            resolved.expiresAt = expiry.interval.map { Date().addingTimeInterval($0) }
        }

        do {
            let saved: SharedLink
            if let existing {
                saved = try await client.updateSharedLink(id: existing.id, options: resolved)
            } else {
                saved = try await client.createSharedLink(albumID: album.id, options: resolved)
            }
            dismiss()
            await onSaved(saved)
        } catch {
            self.error = error.localizedDescription
            isSaving = false
        }
    }
}
