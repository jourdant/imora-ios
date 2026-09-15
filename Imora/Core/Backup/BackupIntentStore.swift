import Foundation

/// Only unfinished whole-library requests are restored. A one-run cellular
/// approval is deliberately never persisted. Atomic writes happen before work.
@MainActor
final class BackupIntentStore {
    static let shared = BackupIntentStore()
    private let url: URL
    private var accounts: Set<String> = []
    private var loaded = false

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "imora/backup-intents.json")) {
        self.url = url
    }

    private func load() -> Bool {
        if loaded { return true }
        do {
            accounts = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            accounts = []
        } catch { return false }
        loaded = true
        return true
    }

    func contains(_ account: String) -> Bool {
        load() && accounts.contains(account)
    }

    @discardableResult
    func set(_ pending: Bool, account: String) -> Bool {
        guard load() else { return false }
        var next = accounts
        if pending { next.insert(account) } else { next.remove(account) }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            accounts = next
            return true
        } catch { return false }
    }
}
