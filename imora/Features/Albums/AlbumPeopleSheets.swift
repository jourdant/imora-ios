import SwiftUI

// MARK: - invite

/// multi-select picker over the server's users; invited people join as
/// editors, matching the official client.
struct AlbumInviteSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let album: Album
    let onInvited: (Int) async -> Void

    @State private var candidates: [User] = []
    @State private var selection = Set<String>()
    @State private var isLoading = true
    @State private var isInviting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if !candidates.isEmpty {
                    Section("Suggestions") {
                        ForEach(candidates) { user in
                            row(user)
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
                } else if candidates.isEmpty && error == nil {
                    ContentUnavailableView(
                        "Nobody to invite",
                        systemImage: "person.2",
                        description: Text("Everyone on this server is already in the album.")
                    )
                }
            }
            .navigationTitle("Invite to Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selection.isEmpty ? "Add" : "Add (\(selection.count))") {
                        Task { await invite() }
                    }
                    .disabled(selection.isEmpty || isInviting)
                    .accessibilityIdentifier("album-invite-add")
                }
            }
            .interactiveDismissDisabled(isInviting)
            .task { await load() }
        }
    }

    @ViewBuilder private func row(_ user: User) -> some View {
        let isSelected = selection.contains(user.id)
        Button {
            if isSelected {
                selection.remove(user.id)
            } else {
                selection.insert(user.id)
            }
        } label: {
            HStack(spacing: 12) {
                UserAvatar(user: user, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(user.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(user.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy(duration: 0.22), value: isSelected)
            }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        defer { isLoading = false }
        do {
            let all = try await client.allUsers()
            let excluded = Set(album.albumUsers.map(\.user.id) + [session.user?.id].compactMap(\.self))
            candidates = all.filter { !excluded.contains($0.id) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func invite() async {
        guard let client = session.client else { return }
        isInviting = true
        do {
            try await client.addAlbumUsers(albumID: album.id, userIDs: Array(selection))
            let count = selection.count
            dismiss()
            await onInvited(count)
        } catch {
            self.error = error.localizedDescription
            isInviting = false
        }
    }
}

// MARK: - options

/// album options: the activity toggle and the people list, mirroring the
/// official client's options page.
struct AlbumOptionsSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let album: Album
    let onChanged: () async -> Void
    let onLeft: () -> Void

    @State private var activityEnabled: Bool
    @State private var showInvite = false
    @State private var userToRemove: User?
    @State private var showLeaveConfirm = false
    @State private var error: String?

    init(album: Album, onChanged: @escaping () async -> Void, onLeft: @escaping () -> Void) {
        self.album = album
        self.onChanged = onChanged
        self.onLeft = onLeft
        _activityEnabled = State(initialValue: album.isActivityEnabled ?? true)
    }

    private var isOwner: Bool { album.owner?.id == session.user?.id }

    var body: some View {
        NavigationStack {
            List {
                if isOwner {
                    Section {
                        Toggle(isOn: $activityEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Comments and Likes")
                                Text("Let others respond in shared albums")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("album-activity-toggle")
                        .onChange(of: activityEnabled) { _, value in
                            Task { await setActivity(value) }
                        }
                    }
                }

                Section("People") {
                    if isOwner {
                        Button {
                            showInvite = true
                        } label: {
                            Label("Invite People", systemImage: "person.badge.plus")
                        }
                        .accessibilityIdentifier("album-options-invite")
                    }

                    if let owner = album.owner {
                        personRow(owner, role: "Owner")
                    }
                    ForEach(album.sharedUsers, id: \.user.id) { albumUser in
                        personRow(albumUser.user, role: albumUser.role.capitalized)
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
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showInvite) {
                AlbumInviteSheet(album: album) { _ in
                    await onChanged()
                    dismiss()
                }
            }
            .confirmationDialog(
                "Remove \(userToRemove?.name ?? "")?",
                isPresented: .init(
                    get: { userToRemove != nil },
                    set: { if !$0 { userToRemove = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove from Album", role: .destructive) {
                    if let user = userToRemove {
                        Task { await remove(user) }
                    }
                }
            } message: {
                Text("They will no longer see this album.")
            }
            .confirmationDialog(
                "Leave \"\(album.albumName)\"?",
                isPresented: $showLeaveConfirm,
                titleVisibility: .visible
            ) {
                Button("Leave Album", role: .destructive) {
                    Task { await leave() }
                }
            } message: {
                Text("You will no longer see this album.")
            }
        }
    }

    @ViewBuilder private func personRow(_ user: User, role: String) -> some View {
        let isMe = user.id == session.user?.id
        let removable = isOwner && role != "Owner"
        let canLeave = !isOwner && isMe

        HStack(spacing: 12) {
            UserAvatar(user: user, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(user.name)
                    .font(.subheadline.weight(.medium))
                Text(user.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(role)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .contextMenu {
            if removable {
                Button(role: .destructive) {
                    userToRemove = user
                } label: {
                    Label("Remove from Album", systemImage: "person.badge.minus")
                }
            } else if canLeave {
                Button(role: .destructive) {
                    showLeaveConfirm = true
                } label: {
                    Label("Leave Album", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .onTapGesture {
            if removable {
                userToRemove = user
            } else if canLeave {
                showLeaveConfirm = true
            }
        }
    }

    // MARK: - actions

    private func setActivity(_ value: Bool) async {
        guard let client = session.client else { return }
        do {
            try await client.updateAlbum(id: album.id, isActivityEnabled: value)
            await onChanged()
        } catch {
            activityEnabled = !value
            self.error = error.localizedDescription
        }
    }

    private func remove(_ user: User) async {
        guard let client = session.client else { return }
        do {
            try await client.removeAlbumUser(albumID: album.id, userID: user.id)
            await onChanged()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func leave() async {
        guard let client = session.client, let userID = session.user?.id else { return }
        do {
            try await client.removeAlbumUser(albumID: album.id, userID: userID)
            dismiss()
            onLeft()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
