import SwiftUI

// MARK: - invite

/// multi-select picker over the server's users; invited people join as
/// editors, matching the official client.
struct AlbumInviteSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let album: Album
    @Binding var isAlbumMutationInFlight: Bool
    let onAlbumChanged: (Album) -> Void
    let onInvited: (Int) -> Void

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
                    .disabled(selection.isEmpty || isInviting || isAlbumMutationInFlight)
                    .accessibilityIdentifier("album-invite-add")
                }
            }
            .interactiveDismissDisabled(isInviting || isAlbumMutationInFlight)
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
        guard let client = session.client, !isInviting, !isAlbumMutationInFlight else { return }
        let invited = candidates.filter { selection.contains($0.id) }
        guard !invited.isEmpty else { return }
        let optimistic = album.addingSharedUsers(invited)
        isInviting = true
        isAlbumMutationInFlight = true
        defer {
            isInviting = false
            isAlbumMutationInFlight = false
        }
        await OptimisticAction.perform(
            errorMessage: "Couldn’t invite the selected people.",
            apply: {
                candidates.removeAll { selection.contains($0.id) }
                onAlbumChanged(optimistic)
                dismiss()
            },
            rollback: {
                candidates.append(contentsOf: invited)
                onAlbumChanged(album)
            },
            request: {
                try await client.addAlbumUsers(
                    albumID: album.id,
                    userIDs: invited.map(\.id)
                )
            },
            commit: { _ in onInvited(invited.count) }
        )
    }
}

// MARK: - options

/// album options: the activity toggle and the people list, mirroring the
/// official client's options page.
struct AlbumOptionsSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var album: Album
    @Binding var isAlbumMutationInFlight: Bool
    let onAlbumChanged: (Album) -> Void
    let onLeft: () -> Void
    let onLeaveRolledBack: (Album) -> Void
    let onLeaveCommitted: (String) -> Void

    @State private var activityEnabled: Bool
    @State private var showInvite = false
    @State private var userToRemove: User?
    @State private var showLeaveConfirm = false
    @State private var isActivitySaving = false
    @State private var removingUserIDs = Set<String>()
    @State private var isLeaving = false

    init(
        album: Album,
        isAlbumMutationInFlight: Binding<Bool>,
        onAlbumChanged: @escaping (Album) -> Void,
        onLeft: @escaping () -> Void,
        onLeaveRolledBack: @escaping (Album) -> Void,
        onLeaveCommitted: @escaping (String) -> Void
    ) {
        _album = State(initialValue: album)
        _isAlbumMutationInFlight = isAlbumMutationInFlight
        self.onAlbumChanged = onAlbumChanged
        self.onLeft = onLeft
        self.onLeaveRolledBack = onLeaveRolledBack
        self.onLeaveCommitted = onLeaveCommitted
        _activityEnabled = State(initialValue: album.isActivityEnabled ?? true)
    }

    private var isOwner: Bool { album.owner?.id == session.user?.id }

    var body: some View {
        NavigationStack {
            List {
                if isOwner {
                    Section {
                        Toggle(isOn: Binding(
                            get: { activityEnabled },
                            set: { value in Task { await setActivity(value) } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Comments and Likes")
                                Text("Let others respond in shared albums")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("album-activity-toggle")
                        .disabled(isActivitySaving || isAlbumMutationInFlight)
                    }
                }

                Section("People") {
                    if isOwner {
                        Button {
                            showInvite = true
                        } label: {
                            Label("Invite People", systemImage: "person.badge.plus")
                        }
                        .disabled(isAlbumMutationInFlight)
                        .accessibilityIdentifier("album-options-invite")
                    }

                    if let owner = album.owner {
                        personRow(owner, role: "Owner")
                    }
                    ForEach(album.sharedUsers, id: \.user.id) { albumUser in
                        personRow(albumUser.user, role: albumUser.role.capitalized)
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
                AlbumInviteSheet(
                    album: album,
                    isAlbumMutationInFlight: $isAlbumMutationInFlight,
                    onAlbumChanged: projectAlbum
                ) { _ in
                    dismiss()
                }
            }
            .interactiveDismissDisabled(isAlbumMutationInFlight)
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
        .disabled(isAlbumMutationInFlight || removingUserIDs.contains(user.id))
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
            guard !isAlbumMutationInFlight else { return }
            if removable {
                userToRemove = user
            } else if canLeave {
                showLeaveConfirm = true
            }
        }
        // ios 26 morphs the dialog out of its source control, so it belongs on
        // the tapped row - on the list root it floats detached.
        .confirmationDialog(
            "Remove \(user.name)?",
            isPresented: .init(
                get: { userToRemove?.id == user.id },
                set: { if !$0 { userToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove from Album", role: .destructive) {
                Task { await remove(user) }
            }
        } message: {
            Text("They will no longer see this album.")
        }
        .confirmationDialog(
            "Leave \"\(album.albumName)\"?",
            isPresented: .init(
                get: { showLeaveConfirm && canLeave },
                set: { if !$0 { showLeaveConfirm = false } }
            ),
            titleVisibility: .visible
        ) {
            Button("Leave Album", role: .destructive) {
                Task { await leave() }
            }
        } message: {
            Text("You will no longer see this album.")
        }
    }

    // MARK: - actions

    private func setActivity(_ value: Bool) async {
        guard let client = session.client,
              !isActivitySaving,
              !isAlbumMutationInFlight else { return }
        let original = album
        let optimistic = original.withActivityEnabled(value)
        isActivitySaving = true
        isAlbumMutationInFlight = true
        defer {
            isActivitySaving = false
            isAlbumMutationInFlight = false
        }
        await OptimisticAction.perform(
            errorMessage: "Couldn’t update album activity.",
            apply: {
                activityEnabled = value
                projectAlbum(optimistic)
            },
            rollback: {
                activityEnabled = original.isActivityEnabled ?? true
                projectAlbum(original)
            },
            request: {
                try await client.updateAlbum(id: original.id, isActivityEnabled: value)
            }
        )
    }

    private func remove(_ user: User) async {
        guard let client = session.client,
              !isAlbumMutationInFlight,
              removingUserIDs.insert(user.id).inserted else { return }
        let original = album
        let optimistic = original.removingUser(user.id)
        isAlbumMutationInFlight = true
        defer {
            removingUserIDs.remove(user.id)
            isAlbumMutationInFlight = false
        }
        await OptimisticAction.perform(
            errorMessage: "Couldn’t remove \(user.name) from the album.",
            apply: {
                userToRemove = nil
                projectAlbum(optimistic)
            },
            rollback: { projectAlbum(original) },
            request: {
                try await client.removeAlbumUser(albumID: original.id, userID: user.id)
            },
            commit: { _ in dismiss() }
        )
    }

    private func leave() async {
        guard let client = session.client,
              let userID = session.user?.id,
              !isLeaving,
              !isAlbumMutationInFlight else { return }
        let original = album
        let optimistic = original.removingUser(userID)
        isLeaving = true
        isAlbumMutationInFlight = true
        defer {
            isLeaving = false
            isAlbumMutationInFlight = false
        }
        let left: Void? = await OptimisticAction.perform(
            errorMessage: "Couldn’t leave the album.",
            apply: {
                projectAlbum(optimistic)
                dismiss()
                onLeft()
            },
            rollback: {
                projectAlbum(original)
                onLeaveRolledBack(original)
            },
            request: {
                try await client.removeAlbumUser(albumID: original.id, userID: userID)
            }
        )
        if left != nil { onLeaveCommitted(original.id) }
    }

    private func projectAlbum(_ replacement: Album) {
        album = replacement
        onAlbumChanged(replacement)
    }
}
