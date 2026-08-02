import Foundation
import Observation

/// carries notification taps into swiftui navigation. the tab shell consumes
/// the pending values and clears them.
@Observable
final class NotificationRouter {
    static let shared = NotificationRouter()

    var pendingAlbumID: String?
    var showsInbox = false
    /// raised when the share extension left something in the app group.
    var showsShareUpload = false
    /// set by the share screen's view photos button.
    var showsPhotos = false
    /// wired by sessionstore so notification actions reach the live inbox.
    @ObservationIgnored weak var inbox: NotificationInbox?

    private init() {}

    func openAlbum(_ id: String) {
        showsInbox = false
        pendingAlbumID = id
    }

    func openInbox() {
        showsInbox = true
    }

    func markRead(_ id: String) {
        inbox?.markRead(id)
    }
}

/// the server-side inbox, GET /notifications plus the on_notification socket
/// event. entries arriving while the app runs also become ios banners, which
/// is the only delivery path immich offers.
@Observable
final class NotificationInbox: RealtimeListener {
    private(set) var items: [ServerNotification] = []
    private(set) var unreadCount = 0
    private(set) var isLoading = false

    /// how many missed entries a catch-up fetch is allowed to raise at once,
    /// so a week away does not bury the lock screen.
    private static let catchUpLimit = 5

    private let client: ImmichClient
    private let local: LocalNotifications
    private let watermarkKey: String

    init(client: ImmichClient, local: LocalNotifications = .shared) {
        self.client = client
        self.local = local
        self.watermarkKey = "imora.notify.watermark|\(SessionCache.accountKey(host: client.apiURL.host() ?? ""))"
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
        deliverMissed()
    }

    // MARK: - mutations

    /// every mutation paints locally first: the server call is a formality the
    /// list should not wait on, and a failed one only costs a stale read flag
    /// until the next fetch.
    func markRead(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isUnread else { return }
        items[index].readAt = Date()
        sync()
        local.clearDelivered(ids: [id])
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
        local.clearDelivered(ids: ids)
        let client = client
        Task { try? await client.markNotificationsRead(ids: ids, at: now) }
    }

    func delete(_ id: String) {
        items.removeAll { $0.id == id }
        sync()
        local.clearDelivered(ids: [id])
        let client = client
        Task { try? await client.deleteNotifications(ids: [id]) }
    }

    func deleteAll() {
        let ids = items.map(\.id)
        guard !ids.isEmpty else { return }
        items = []
        sync()
        local.clearDelivered(ids: ids)
        let client = client
        Task { try? await client.deleteNotifications(ids: ids) }
    }

    /// called on logout: the badge and any lingering banner belong to an
    /// account that is no longer signed in.
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
        if notification.isUnread { local.deliver(notification) }
        noteDelivered(upTo: notification.createdAt)
    }

    // MARK: - internals

    private func sync() {
        unreadCount = items.filter(\.isUnread).count
        local.setBadge(unreadCount)
    }

    /// the socket only runs while the app is in the foreground, so anything
    /// created while it was away has to be replayed on the next fetch.
    private func deliverMissed() {
        let newest = items.first?.createdAt
        defer { if let newest { noteDelivered(upTo: newest) } }
        // a first sync only records the watermark; replaying an existing inbox
        // as banners would be noise.
        guard let watermark = lastDeliveredAt else { return }
        let missed = items.filter { $0.isUnread && $0.createdAt > watermark }
        for notification in missed.prefix(Self.catchUpLimit).reversed() {
            local.deliver(notification)
        }
    }

    private func noteDelivered(upTo date: Date) {
        lastDeliveredAt = max(date, lastDeliveredAt ?? .distantPast)
    }

    private var lastDeliveredAt: Date? {
        get { UserDefaults.standard.object(forKey: watermarkKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: watermarkKey) }
    }
}
