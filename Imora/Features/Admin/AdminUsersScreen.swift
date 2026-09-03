import SwiftUI

/// every account on the server, deleted ones included, with the per-user
/// menu the web's user management table offers.
struct AdminUsersScreen: View {
    @Environment(SessionStore.self) private var session

    @State private var users: [AdminUser] = []
    @State private var hasLoaded = false
    @State private var loadError: Error?
    @State private var action: AdminUserAction?
    @State private var editing: AdminUser?
    @State private var showsCreate = false
    @State private var createdUser: AdminUser?
    @State private var feedback = TransientFeedback()

    var body: some View {
        List {
            if !hasLoaded {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            } else if let loadError, users.isEmpty {
                ContentUnavailableView {
                    Label("Couldn’t Load Users", systemImage: "person.2.slash")
                } description: {
                    Text(loadError.localizedDescription)
                } actions: {
                    Button("Try Again") {
                        Task { await load() }
                    }
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(users) { user in
                        row(user)
                    }
                } footer: {
                    Text("\(users.count) user\(users.count == 1 ? "" : "s")")
                }
            }
        }
        .navigationTitle("Users")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Create User", systemImage: "plus") {
                    showsCreate = true
                }
                .accessibilityIdentifier("admin-users-create")
            }
        }
        .navigationDestination(item: $createdUser) { user in
            detail(user)
        }
        .sheet(isPresented: $showsCreate) {
            AdminUserFormSheet(mode: .create) { user in
                upsert(user)
                createdUser = user
            }
        }
        .sheet(item: $editing) { user in
            AdminUserFormSheet(mode: .edit(user)) { upsert($0) }
        }
        .feedbackPill(feedback)
        .task { await load() }
    }

    private func row(_ user: AdminUser) -> some View {
        NavigationLink {
            detail(user)
        } label: {
            HStack(spacing: 12) {
                AdminUserRow(user: user)
                Menu {
                    AdminUserMenuItems(
                        user: user,
                        onEdit: { editing = user },
                        action: $action
                    )
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Actions for \(user.name)")
                // ios 26 morphs a dialog out of the control that raised it,
                // and a menu item cannot host one, so they sit on the menu.
                .adminUserActions(
                    for: user,
                    action: $action,
                    onUpdated: upsert,
                    onFeedback: feedback.show
                )
            }
        }
        .listRowBackground(user.isDeleted ? Color.red.opacity(0.08) : nil)
        .contextMenu {
            AdminUserMenuItems(
                user: user,
                onEdit: { editing = user },
                action: $action
            )
        }
    }

    private func detail(_ user: AdminUser) -> some View {
        AdminUserDetailScreen(user: user, onUpdated: upsert)
    }

    private func upsert(_ user: AdminUser) {
        if let index = users.firstIndex(where: { $0.id == user.id }) {
            users[index] = user
        } else {
            users.append(user)
            users.sort { $0.createdAt < $1.createdAt }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            users = try await client.adminUsers()
            loadError = nil
        } catch {
            loadError = error
        }
        hasLoaded = true
    }
}

/// avatar, name, email and the quota column of the web table.
struct AdminUserRow: View {
    let user: AdminUser

    var body: some View {
        HStack(spacing: 12) {
            UserAvatar(user: user.asUser, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(user.name)
                        .lineLimit(1)
                    if user.isAdmin {
                        AdminBadge("Admin", color: .indigo)
                    }
                    if user.isDeleted {
                        AdminBadge("Deleted", color: .red)
                    }
                }
                Text(user.email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Group {
                if let quota = user.quotaSizeInBytes, quota >= 0 {
                    Text(BinaryByteFormat.string(quota))
                } else {
                    Image(systemName: "infinity")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// small tinted capsule, the web's badge.
struct AdminBadge: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
