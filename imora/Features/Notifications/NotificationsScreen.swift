import SwiftUI

/// the server inbox: album invites, album activity and server alerts, with the
/// same read semantics as the web panel.
struct NotificationsScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let inbox = session.notifications {
                    list(inbox)
                } else {
                    empty
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let inbox = session.notifications {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button {
                                inbox.markAllRead()
                            } label: {
                                Label("Mark All as Read", systemImage: "checkmark.circle")
                            }
                            .disabled(inbox.unreadCount == 0)

                            Button(role: .destructive) {
                                inbox.deleteAll()
                            } label: {
                                Label("Clear All", systemImage: "trash")
                            }
                            .disabled(inbox.items.isEmpty)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityIdentifier("notifications-menu")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityIdentifier("notifications-close")
                }
            }
        }
    }

    private func list(_ inbox: NotificationInbox) -> some View {
        List {
            ForEach(inbox.items) { notification in
                Button {
                    open(notification, in: inbox)
                } label: {
                    NotificationRow(notification: notification)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .leading) {
                    if notification.isUnread {
                        Button {
                            inbox.markRead(notification.id)
                        } label: {
                            Label("Read", systemImage: "envelope.open")
                        }
                        .tint(.indigo)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        inbox.delete(notification.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if inbox.items.isEmpty, !inbox.isLoading {
                empty
            }
        }
        .refreshable { await inbox.load() }
        .task {
            await inbox.load()
            await LocalNotifications.shared.requestAuthorizationIfNeeded()
        }
    }

    private var empty: some View {
        ContentUnavailableView(
            "No Notifications",
            systemImage: "bell",
            description: Text("Album invites and server alerts show up here.")
        )
    }

    /// tapping clears the entry and, for album notifications, hands the id to
    /// the router so the albums tab opens it.
    private func open(_ notification: ServerNotification, in inbox: NotificationInbox) {
        inbox.markRead(notification.id)
        guard let albumID = notification.albumID else { return }
        dismiss()
        NotificationRouter.shared.openAlbum(albumID)
    }
}

struct NotificationRow: View {
    let notification: ServerNotification

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(notification.level.tint.gradient)
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: notification.kind.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(notification.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let body = notification.body, !body.isEmpty {
                    Text(body)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(notification.createdAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            if notification.isUnread {
                Circle()
                    .fill(.indigo)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

extension NotificationLevel {
    var tint: Color {
        switch self {
        case .success: .green
        case .error: .red
        case .warning: .orange
        case .info: .blue
        }
    }
}

extension NotificationKind {
    var symbol: String {
        switch self {
        case .albumInvite: "rectangle.stack.badge.person.crop"
        case .albumUpdate: "photo.badge.plus"
        case .backupFailed: "icloud.slash"
        case .jobFailed: "arrow.triangle.2.circlepath"
        case .systemMessage: "megaphone"
        case .custom: "info.circle"
        }
    }
}
