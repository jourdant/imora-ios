import Foundation
import Observation

/// carries notification taps into swiftui navigation. the tab shell consumes
/// the pending values and clears them.
@Observable
final class NotificationRouter {
    static let shared = NotificationRouter()

    var pendingAlbumID: String?
    var showsInbox = false

    private init() {}

    func openAlbum(_ id: String) {
        showsInbox = false
        pendingAlbumID = id
    }

    func openInbox() {
        showsInbox = true
    }
}

/// the server-side inbox, GET /notifications plus the on_notification socket
/// event. entries stay in this list: without a push transport a native banner
/// could only ever appear over the open app, duplicating what the inbox
/// already shows. the app icon badge still mirrors the unread count.
@Observable
final class NotificationInbox: RealtimeListener {
    private(set) var items: [ServerNotification] = []
    private(set) var unreadCount = 0
    private(set) var isLoading = false

    private let client: ImmichClient
    private let local: LocalNotifications

    init(client: ImmichClient, local: LocalNotifications = .shared) {
        self.client = client
        self.local = local
    }

    var unread: [ServerNotification] { items.filter(\.isUnread) }

    // MARK: - loading

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard let fetched = try? await client.notifications() else { return }
        items = fetched
        sync()
    }

    // MARK: - mutations

    /// every mutation paints locally first: the server call is a formality the
    /// list should not wait on, and a failed one only costs a stale read flag
    /// until the next fetch.
    func markRead(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isUnread else { return }
        items[index].readAt = Date()
        sync()
        let client = client
        Task { try? await client.markNotificationRead(id: id) }
    }

    func markAllRead() {
        let ids = unread.map(\.id)
        guard !ids.isEmpty else { return }
        let now = Date()
        for index in items.indices where items[index].isUnread {
            items[index].readAt = now
        }
        sync()
        let client = client
        Task { try? await client.markNotificationsRead(ids: ids, at: now) }
    }

    func delete(_ id: String) {
        items.removeAll { $0.id == id }
        sync()
        let client = client
        Task { try? await client.deleteNotifications(ids: [id]) }
    }

    func deleteAll() {
        let ids = items.map(\.id)
        guard !ids.isEmpty else { return }
        items = []
        sync()
        let client = client
        Task { try? await client.deleteNotifications(ids: ids) }
    }

    /// called on logout: the badge and any lingering backup banner belong to
    /// an account that is no longer signed in.
    func clear() {
        items = []
        unreadCount = 0
        local.clearAll()
    }

    // MARK: - realtime

    func realtimeNotification(_ notification: ServerNotification) {
        if let index = items.firstIndex(where: { $0.id == notification.id }) {
            items[index] = notification
        } else {
            items.insert(notification, at: 0)
            items.sort { $0.createdAt > $1.createdAt }
        }
        sync()
    }

    // MARK: - internals

    private func sync() {
        unreadCount = items.filter(\.isUnread).count
        local.setBadge(unreadCount)
    }
}
