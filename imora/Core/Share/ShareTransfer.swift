import Foundation

// NOTE: this file is duplicated verbatim in imoraShare/ShareTransfer.swift.
// the share extension and the app are separate modules with no shared target,
// and this is the contract between them - change both or neither.

/// everything the app needs to finish an upload the share extension started.
/// carried in the task description, so it survives both processes dying.
nonisolated struct ShareTicket: Codable, Sendable {
    let bodyPath: String
    let filename: String
}

/// the handoff between the share extension and the app. the extension turns a
/// drop into upload tasks on background url sessions; the app adopts those
/// sessions later to clean up and report. media never waits for the app.
nonisolated enum ShareTransfer {
    /// the group id is stamped into both info plists from one build setting, so
    /// the two targets cannot drift apart.
    static var appGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "IMORAAppGroup") as? String
    }

    static var container: URL? {
        guard let appGroup else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// multipart bodies live in the app group so they outlive the extension
    /// and stay readable once the app takes the session over.
    static var bodyDirectory: URL? { container?.appending(path: "share-bodies") }

    /// one marker file per extension session, so the app knows which ids to
    /// reattach. files rather than a defaults array: creates and deletes from
    /// two processes can never lose each other's writes.
    static var sessionDirectory: URL? { container?.appending(path: "share-sessions") }

    static let sessionPrefix = "app.imora.share."

    /// app-to-extension mirror of the signed-in session. the token itself is
    /// in the keychain, written into the app group access group under the
    /// service and account below.
    static var defaults: UserDefaults? {
        guard let appGroup else { return nil }
        return UserDefaults(suiteName: appGroup)
    }

    static let serverURLKey = "imora.share.serverURL"
    static let deviceIdKey = "imora.share.deviceId"
    static let tokenService = "app.imora.credentials"
    static let tokenAccount = "accessToken"

    static func markSession(_ identifier: String) {
        guard let sessionDirectory else { return }
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try? Data().write(to: sessionDirectory.appending(path: identifier))
    }

    static func unmarkSession(_ identifier: String) {
        guard let sessionDirectory else { return }
        try? FileManager.default.removeItem(at: sessionDirectory.appending(path: identifier))
    }

    static func markedSessions() -> [String] {
        guard let sessionDirectory else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: sessionDirectory.path)) ?? []
        return contents.filter { $0.hasPrefix(sessionPrefix) }
    }

    static func encode(_ ticket: ShareTicket) -> String? {
        guard let data = try? JSONEncoder().encode(ticket) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ description: String?) -> ShareTicket? {
        guard let description else { return nil }
        return try? JSONDecoder().decode(ShareTicket.self, from: Data(description.utf8))
    }
}
