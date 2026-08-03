import Observation
import UIKit
import UserNotifications

/// the system side of notifications. immich ships no apns transport, so the
/// only native banners are the ones this device raises about its own backup
/// runs - server inbox entries stay in the in-app inbox, where a banner would
/// only duplicate the list under the open app.
@Observable
final class LocalNotifications {
    static let shared = LocalNotifications()

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// device-local switch for the end-of-run backup banners. the server-side
    /// email switches live in the account preferences instead.
    var backupReports: Bool { didSet { defaults.set(backupReports, forKey: Key.backupReports) } }

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let backupReports = "imora.notify.backupReports"
    }

    /// backup reports share one identifier so a new run replaces the old
    /// banner instead of stacking a second one.
    private static let backupRequestID = "imora.backup.report"

    private init() {
        // unset defaults to true: opting in is the point of asking for the
        // permission in the first place.
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

    /// asked the first time the user opens the inbox: the unread badge is the
    /// first thing the permission powers. the system only ever shows the
    /// prompt once anyway.
    func requestAuthorizationIfNeeded() async {
        await refreshAuthorization()
        guard authorizationStatus == .notDetermined else { return }
        await requestAuthorization()
    }

    static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - delivery

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

    func clearAll() {
        center.removeAllDeliveredNotifications()
        setBadge(0)
    }
}

/// presents foreground banners. a backup run can finish while the app is on
/// screen, and without this the report would be dropped silently. the delegate
/// stays off the main actor because the protocol is not annotated for it.
nonisolated final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationDelegate()

    private override init() { super.init() }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
