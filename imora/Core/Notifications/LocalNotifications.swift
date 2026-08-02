import Observation
import UIKit
import UserNotifications

/// the system side of the inbox. immich ships no apns transport, so every
/// banner is a local notification raised from a socket event or a catch-up
/// fetch while the app runs - the same trick the official mobile client uses
/// for its backup notifications.
@Observable
final class LocalNotifications {
    static let shared = LocalNotifications()

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// per-kind delivery switches, device local. the server-side email
    /// switches live in the account preferences instead.
    var albumInvites: Bool { didSet { defaults.set(albumInvites, forKey: Key.albumInvites) } }
    var albumUpdates: Bool { didSet { defaults.set(albumUpdates, forKey: Key.albumUpdates) } }
    var serverAlerts: Bool { didSet { defaults.set(serverAlerts, forKey: Key.serverAlerts) } }
    var backupReports: Bool { didSet { defaults.set(backupReports, forKey: Key.backupReports) } }

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let albumInvites = "imora.notify.albumInvites"
        static let albumUpdates = "imora.notify.albumUpdates"
        static let serverAlerts = "imora.notify.serverAlerts"
        static let backupReports = "imora.notify.backupReports"
    }

    enum Category {
        static let serverNotification = "imora.serverNotification"
    }

    enum Action {
        static let markRead = "imora.markRead"
    }

    /// backup reports share one identifier so a new run replaces the old
    /// banner instead of stacking a second one.
    private static let backupRequestID = "imora.backup.report"

    private init() {
        // unset defaults to true: opting in is the point of asking for the
        // permission in the first place.
        albumInvites = defaults.object(forKey: Key.albumInvites) as? Bool ?? true
        albumUpdates = defaults.object(forKey: Key.albumUpdates) as? Bool ?? true
        serverAlerts = defaults.object(forKey: Key.serverAlerts) as? Bool ?? true
        backupReports = defaults.object(forKey: Key.backupReports) as? Bool ?? true
    }

    // MARK: - authorization

    var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    /// denied is the only state a prompt cannot recover from; the ui sends the
    /// user to the system settings instead.
    var isDenied: Bool { authorizationStatus == .denied }

    func refreshAuthorization() async {
        authorizationStatus = await center.notificationSettings().authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorization()
        return granted
    }

    /// asked the first time the user opens the inbox, which is the in-context
    /// moment. the system only ever shows the prompt once anyway.
    func requestAuthorizationIfNeeded() async {
        await refreshAuthorization()
        guard authorizationStatus == .notDetermined else { return }
        await requestAuthorization()
    }

    static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// one category with a mark-as-read button, so an album invite can be
    /// cleared without opening the app.
    func registerCategories() {
        let markRead = UNNotificationAction(
            identifier: Action.markRead,
            title: "Mark as Read",
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Category.serverNotification,
                actions: [markRead],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    // MARK: - delivery

    func allows(_ kind: NotificationKind) -> Bool {
        switch kind {
        case .albumInvite: albumInvites
        case .albumUpdate: albumUpdates
        case .jobFailed, .backupFailed, .systemMessage, .custom: serverAlerts
        }
    }

    /// raises a banner for one inbox entry. the request id is the server id, so
    /// the same entry never lands twice. the authorization state is not checked
    /// here on purpose - the cached value can lag a launch, and the system drops
    /// the request itself when the user said no.
    func deliver(_ notification: ServerNotification) {
        guard allows(notification.kind) else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        if let body = notification.body, !body.isEmpty { content.body = body }
        content.sound = .default
        content.threadIdentifier = notification.kind.rawValue
        content.categoryIdentifier = Category.serverNotification
        var info = ["notificationId": notification.id]
        if let albumID = notification.albumID { info["albumId"] = albumID }
        content.userInfo = info
        add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil))
    }

    /// end-of-run backup report, mirroring the official client's upload
    /// finished notification.
    func deliverBackupReport(_ summary: BackupSummary) {
        guard backupReports, summary.uploaded > 0 || summary.failed > 0 else { return }
        var parts: [String] = []
        if summary.uploaded > 0 { parts.append("\(summary.uploaded) uploaded") }
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        deliverBackup(
            title: summary.failed > 0 ? "Backup finished with errors" : "Backup complete",
            body: parts.joined(separator: ", ")
        )
    }

    func deliverBackupFailure(_ message: String) {
        guard backupReports else { return }
        deliverBackup(title: "Backup stopped", body: message)
    }

    private func deliverBackup(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "imora.backup"
        add(UNNotificationRequest(identifier: Self.backupRequestID, content: content, trigger: nil))
    }

    private func add(_ request: UNNotificationRequest) {
        let center = center
        Task { try? await center.add(request) }
    }

    // MARK: - badge and cleanup

    func setBadge(_ count: Int) {
        let center = center
        Task { try? await center.setBadgeCount(max(0, count)) }
    }

    /// pulls banners for entries that were read elsewhere out of notification
    /// center, so the two views of the inbox never disagree.
    func clearDelivered(ids: [String]) {
        guard !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    func clearAll() {
        center.removeAllDeliveredNotifications()
        setBadge(0)
    }
}

/// routes notification taps and action buttons. the delegate itself stays off
/// the main actor because the protocol is not annotated for it.
nonisolated final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationDelegate()

    private override init() { super.init() }

    /// banners while the app is on screen are the whole point here: without a
    /// push transport the socket only feeds us in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let notificationID = info["notificationId"] as? String
        let albumID = info["albumId"] as? String
        let action = response.actionIdentifier

        await MainActor.run {
            let router = NotificationRouter.shared
            switch action {
            case LocalNotifications.Action.markRead:
                guard let notificationID else { return }
                router.markRead(notificationID)
            case UNNotificationDefaultActionIdentifier:
                // a backup report carries no inbox id; tapping it just opens
                // the app rather than a list it does not belong to.
                guard let notificationID else { return }
                router.markRead(notificationID)
                if let albumID, !albumID.isEmpty {
                    router.openAlbum(albumID)
                } else {
                    router.openInbox()
                }
            default:
                break
            }
        }
    }
}
