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

/// what a public link points at: a whole album or a hand-picked asset set.
nonisolated enum ShareLinkTarget {
    case album(Album)
    case assets([String])
}

private enum SharedLinkProjection {
    case upsert(SharedLink, replacingID: String)
    case remove(String)
}

/// lists the target's public links and hosts the create and edit form.
struct ShareLinksSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let target: ShareLinkTarget
    var onChanged: () async -> Void = {}

    @State private var links: [SharedLink] = []
    @State private var isLoading = true
    @State private var webBase: URL?
    @State private var createdURL: URL?
    @State private var linkToDelete: SharedLink?
    @State private var error: String?
    @State private var deletingLinkIDs = Set<String>()
    @State private var savingLinkIDs = Set<String>()
    @State private var linkLoadGate = LatestAlbumLoadGate()

    private var hasMutationInFlight: Bool {
        !deletingLinkIDs.isEmpty || !savingLinkIDs.isEmpty
    }

    private var title: String {
        switch target {
        case .album: "Share Album"
        case .assets: "Share Link"
        }
    }

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
                        SharedLinkForm(
                            target: target,
                            existing: nil,
                            project: project,
                            setSaving: setSaving,
                            onSaved: handleCreated
                        )
                    } label: {
                        Label("New Shared Link", systemImage: "plus")
                    }
                    .disabled(isLoading)
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(hasMutationInFlight)
                }
            }
            .task { await load() }
            .interactiveDismissDisabled(hasMutationInFlight)
        }
    }

    @ViewBuilder private func linkRow(_ link: SharedLink) -> some View {
        NavigationLink {
            SharedLinkForm(
                target: target,
                existing: link,
                project: project,
                setSaving: setSaving,
                onSaved: { _ in await onChanged() }
            )
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
        .disabled(deletingLinkIDs.contains(link.id) || savingLinkIDs.contains(link.id))
        .swipeActions {
            Button(role: .destructive) {
                linkToDelete = link
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(savingLinkIDs.contains(link.id))
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
            .disabled(savingLinkIDs.contains(link.id))
        }
        // ios 26 morphs the dialog out of its source control, so it belongs on
        // the row that was swiped - on the list root it floats detached.
        .confirmationDialog(
            "Delete this shared link?",
            isPresented: .init(
                get: { linkToDelete?.id == link.id },
                set: { if !$0 { linkToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Link", role: .destructive) {
                Task { await delete(link) }
            }
        } message: {
            Text("People with this link will lose access.")
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
        guard let client = session.client, !hasMutationInFlight else { return }
        let ticket = linkLoadGate.begin()
        isLoading = true
        let base = await client.serverWebURL()
        guard linkLoadGate.accepts(ticket) else { return }
        do {
            let fetched: [SharedLink]
            switch target {
            case .album(let album):
                fetched = try await client.sharedLinks(albumID: album.id)
            case .assets(let ids):
                // the api has no asset filter; keep individual links whose
                // asset set contains every requested id.
                let wanted = Set(ids)
                fetched = try await client.sharedLinks().filter { link in
                    guard link.type == "INDIVIDUAL" else { return false }
                    let contained = Set((link.assets ?? []).map(\.id))
                    return wanted.isSubset(of: contained)
                }
            }
            guard linkLoadGate.accepts(ticket) else { return }
            webBase = base
            links = fetched
            error = nil
        } catch {
            guard linkLoadGate.accepts(ticket) else { return }
            webBase = base
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func handleCreated(_ link: SharedLink) async {
        await onChanged()
        if let url = shareURL(for: link) {
            UIPasteboard.general.string = url.absoluteString
            createdURL = url
        }
    }

    private func delete(_ link: SharedLink) async {
        guard let client = session.client,
              !savingLinkIDs.contains(link.id),
              deletingLinkIDs.insert(link.id).inserted else { return }
        let originalIndex = links.firstIndex(where: { $0.id == link.id }) ?? links.endIndex
        let previousID = originalIndex > links.startIndex ? links[originalIndex - 1].id : nil
        let nextID = originalIndex < links.index(before: links.endIndex) ? links[originalIndex + 1].id : nil
        let originalCreatedURL = createdURL
        defer { deletingLinkIDs.remove(link.id) }
        let deleted: Void? = await OptimisticAction.perform(
            errorMessage: "Couldn’t delete the shared link.",
            apply: {
                project(.remove(link.id))
                if shareURL(for: link) == createdURL { createdURL = nil }
            },
            rollback: {
                links.removeAll { $0.id == link.id }
                let index: Int
                if let nextID, let nextIndex = links.firstIndex(where: { $0.id == nextID }) {
                    index = nextIndex
                } else if let previousID,
                          let previousIndex = links.firstIndex(where: { $0.id == previousID }) {
                    index = previousIndex + 1
                } else {
                    index = min(originalIndex, links.endIndex)
                }
                links.insert(link, at: index)
                createdURL = originalCreatedURL
            },
            request: { try await client.deleteSharedLink(id: link.id) }
        )
        if deleted != nil { await onChanged() }
    }

    private func project(_ projection: SharedLinkProjection) {
        invalidateLinkLoads()
        switch projection {
        case .remove(let id):
            links.removeAll { $0.id == id }
        case .upsert(let link, let replacingID):
            let index = links.firstIndex { $0.id == replacingID || $0.id == link.id }
                ?? links.startIndex
            links.removeAll { $0.id == replacingID || $0.id == link.id }
            links.insert(link, at: min(index, links.endIndex))
        }
    }

    private func setSaving(_ linkID: String, _ saving: Bool) {
        if saving {
            invalidateLinkLoads()
            savingLinkIDs.insert(linkID)
        } else {
            savingLinkIDs.remove(linkID)
        }
    }

    private func invalidateLinkLoads() {
        linkLoadGate.invalidate()
        isLoading = false
    }
}

// MARK: - form

/// create or edit form for one shared link.
private struct SharedLinkForm: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let target: ShareLinkTarget
    let existing: SharedLink?
    let project: (SharedLinkProjection) -> Void
    let setSaving: (String, Bool) -> Void
    let onSaved: (SharedLink) async -> Void

    @State private var options: SharedLinkOptions
    @State private var expiry: LinkExpiry
    @State private var isSaving = false

    init(
        target: ShareLinkTarget,
        existing: SharedLink?,
        project: @escaping (SharedLinkProjection) -> Void,
        setSaving: @escaping (String, Bool) -> Void,
        onSaved: @escaping (SharedLink) async -> Void
    ) {
        self.target = target
        self.existing = existing
        self.project = project
        self.setSaving = setSaving
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
        guard let client = session.client, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        var resolved = options
        switch expiry {
        case .keep:
            resolved.expiresAt = existing?.expiryDate
        case .never:
            resolved.expiresAt = nil
        default:
            resolved.expiresAt = expiry.interval.map { Date().addingTimeInterval($0) }
        }

        let optimistic = existing?.applying(resolved)
            ?? SharedLink.pending(options: resolved, type: target.linkType)
        setSaving(optimistic.id, true)
        defer { setSaving(optimistic.id, false) }
        let saved = await OptimisticAction.perform(
            errorMessage: "Couldn’t save the shared link.",
            apply: {
                project(.upsert(optimistic, replacingID: existing?.id ?? optimistic.id))
                dismiss()
            },
            rollback: {
                if let existing {
                    project(.upsert(existing, replacingID: optimistic.id))
                } else {
                    project(.remove(optimistic.id))
                }
            },
            request: {
                if let existing {
                    return try await client.updateSharedLink(id: existing.id, options: resolved)
                }
                switch target {
                case .album(let album):
                    return try await client.createSharedLink(albumID: album.id, options: resolved)
                case .assets(let ids):
                    return try await client.createSharedLink(assetIDs: ids, options: resolved)
                }
            },
            commit: { project(.upsert($0, replacingID: optimistic.id)) }
        )
        if let saved { await onSaved(saved) }
    }
}

private extension ShareLinkTarget {
    var linkType: String {
        switch self {
        case .album: "ALBUM"
        case .assets: "INDIVIDUAL"
        }
    }
}
