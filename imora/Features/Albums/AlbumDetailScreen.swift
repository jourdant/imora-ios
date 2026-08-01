import SwiftUI

/// full album view: the timeline grid plus editing, sharing and management.
struct AlbumDetailScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var album: Album
    /// bumping recreates the timeline; only the order toggle needs it since
    /// the filter is captured at init. content changes resync in place.
    @State private var timelineGeneration = 0
    @State private var resyncTrigger = 0
    @State private var activeSheet: AlbumSheet?
    @State private var showDeleteConfirm = false
    @State private var showLeaveConfirm = false
    @State private var feedback: String?
    @State private var feedbackTask: Task<Void, Never>?

    init(album: Album) {
        _album = State(initialValue: album)
    }

    private enum AlbumSheet: String, Identifiable {
        case edit, addPhotos, invite, options, shareLinks
        var id: String { rawValue }
    }

    private var isOwner: Bool { album.owner?.id == session.user?.id }
    private var myRole: String? { album.role(of: session.user?.id) }
    private var canAddPhotos: Bool { isOwner || myRole == "editor" }
    private var currentOrder: String { album.order ?? "desc" }

    var body: some View {
        TimelineScreen(
            title: album.albumName,
            filter: TimelineFilter(visibility: nil, albumId: album.id, order: album.order),
            emptyIcon: "rectangle.stack",
            emptyMessage: "This album is empty",
            showsLargeTitle: false,
            resyncTrigger: resyncTrigger,
            albumOwnerID: album.owner?.id
        ) {
            AlbumHeader(album: album) { activeSheet = .options }
        }
        .id(timelineGeneration)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                menu
            }
        }
        .overlay(alignment: .bottom) {
            if let feedback {
                Text(feedback)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("album-feedback")
            }
        }
        .animation(.smooth(duration: 0.25), value: feedback)
        .task { await refreshAlbum() }
        // metadata edits from other clients arrive over the realtime channel;
        // the grid itself resyncs through the timeline model.
        .onChange(of: session.realtime?.albumsGeneration ?? 0) {
            Task { await refreshAlbum() }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .edit:
                AlbumEditSheet(album: album) { await refreshAlbum() }
            case .addPhotos:
                AlbumAddAssetsSheet(album: album) { added in
                    await refreshAlbum()
                    if added > 0 {
                        // in-place animated resync; a generation bump would
                        // remount and visibly reload the whole grid.
                        resyncTrigger += 1
                        showFeedback("Added \(added) photo\(added == 1 ? "" : "s")")
                    }
                }
            case .invite:
                AlbumInviteSheet(album: album) { count in
                    await refreshAlbum()
                    showFeedback("Invited \(count) \(count == 1 ? "person" : "people")")
                }
            case .options:
                AlbumOptionsSheet(
                    album: album,
                    onChanged: { await refreshAlbum() },
                    onLeft: { dismiss() }
                )
            case .shareLinks:
                ShareLinksSheet(target: .album(album)) { await refreshAlbum() }
            }
        }
        .onDisappear { feedbackTask?.cancel() }
    }

    private var menu: some View {
        Menu {
            if isOwner {
                Button {
                    activeSheet = .edit
                } label: {
                    Label("Edit Album", systemImage: "pencil")
                }
            }
            if canAddPhotos {
                Button {
                    activeSheet = .addPhotos
                } label: {
                    Label("Add Photos", systemImage: "photo.badge.plus")
                }
            }
            if isOwner {
                Button {
                    activeSheet = .invite
                } label: {
                    Label("Invite People", systemImage: "person.badge.plus")
                }
                Button {
                    activeSheet = .shareLinks
                } label: {
                    Label("Share Link", systemImage: "link")
                }
                Button {
                    Task { await toggleOrder() }
                } label: {
                    Label(
                        currentOrder == "asc" ? "Show Newest First" : "Show Oldest First",
                        systemImage: "arrow.up.arrow.down"
                    )
                }
            }
            Button {
                activeSheet = .options
            } label: {
                Label("Options", systemImage: "gearshape")
            }
            Divider()
            if isOwner {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete Album", systemImage: "trash")
                }
            } else if myRole != nil {
                Button(role: .destructive) {
                    showLeaveConfirm = true
                } label: {
                    Label("Leave Album", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("album-menu")
        // ios 26 morphs a confirmation out of its source control; the menu item
        // is gone by then, so the dialogs anchor to the menu button itself.
        // attached to the screen root they float detached in the middle.
        .confirmationDialog(
            "Delete \"\(album.albumName)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Album", role: .destructive) { Task { await deleteAlbum() } }
        } message: {
            Text("The album is removed for everyone. Photos stay in your library.")
        }
        .confirmationDialog(
            "Leave \"\(album.albumName)\"?",
            isPresented: $showLeaveConfirm,
            titleVisibility: .visible
        ) {
            Button("Leave Album", role: .destructive) { Task { await leaveAlbum() } }
        } message: {
            Text("You will no longer see this album.")
        }
    }

    // MARK: - actions

    private func refreshAlbum() async {
        guard let client = session.client else { return }
        if let fresh = try? await client.album(id: album.id) {
            album = fresh
        }
    }

    private func toggleOrder() async {
        guard let client = session.client else { return }
        let next = currentOrder == "asc" ? "desc" : "asc"
        do {
            try await client.updateAlbum(id: album.id, order: next)
            await refreshAlbum()
            timelineGeneration += 1
        } catch {
            showFeedback("Couldn't change the order")
        }
    }

    private func deleteAlbum() async {
        guard let client = session.client else { return }
        do {
            try await client.deleteAlbum(id: album.id)
            dismiss()
        } catch {
            showFeedback("Couldn't delete the album")
        }
    }

    private func leaveAlbum() async {
        guard let client = session.client, let userID = session.user?.id else { return }
        do {
            try await client.removeAlbumUser(albumID: album.id, userID: userID)
            dismiss()
        } catch {
            showFeedback("Couldn't leave the album")
        }
    }

    private func showFeedback(_ text: String) {
        feedbackTask?.cancel()
        feedback = text
        feedbackTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            feedback = nil
        }
    }
}

// MARK: - header

/// description, counts and the shared-people strip above the grid.
private struct AlbumHeader: View {
    let album: Album
    let onPeopleTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !album.description.isEmpty {
                Text(album.description)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(metaLine)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if album.shared {
                Button(action: onPeopleTap) {
                    HStack(spacing: -8) {
                        ForEach(displayedUsers, id: \.id) { user in
                            UserAvatar(user: user, size: 32)
                                .overlay { Circle().stroke(Color(.systemBackground), lineWidth: 2) }
                        }
                        if extraCount > 0 {
                            Circle()
                                .fill(Color(.secondarySystemFill))
                                .frame(width: 32, height: 32)
                                .overlay {
                                    Text("+\(extraCount)")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .overlay { Circle().stroke(Color(.systemBackground), lineWidth: 2) }
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("album-people")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var allUsers: [User] {
        var users: [User] = []
        if let owner = album.owner { users.append(owner) }
        users.append(contentsOf: album.sharedUsers.map(\.user))
        return users
    }

    private var displayedUsers: [User] { Array(allUsers.prefix(5)) }
    private var extraCount: Int { max(0, allUsers.count - 5) }

    private var metaLine: String {
        var parts = ["\(album.assetCount) item\(album.assetCount == 1 ? "" : "s")"]
        if let range = dateRangeLabel { parts.append(range) }
        return parts.joined(separator: " · ")
    }

    private var dateRangeLabel: String? {
        guard let startRaw = album.startDate, let start = APIDate.parse(startRaw) else { return nil }
        let style = Date.FormatStyle.dateTime.month(.abbreviated).year().utc()
        let startLabel = start.formatted(style)
        guard let endRaw = album.endDate, let end = APIDate.parse(endRaw) else { return startLabel }
        let endLabel = end.formatted(style)
        return startLabel == endLabel ? startLabel : "\(startLabel) – \(endLabel)"
    }
}
