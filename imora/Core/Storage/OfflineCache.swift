import Foundation

/// small json-on-disk store for offline copies of list screens, albums for
/// now. lives in application support so the system does not purge it, and
/// every file is account-tagged so a server or user switch reads as a miss
/// instead of leaking another account's data.
nonisolated enum OfflineCache {
    private struct Entry<T: Codable>: Codable {
        let account: String
        let value: T
    }

    private static let root: URL = {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "imora/offline")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // re-downloadable data, kept out of device backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    static func value<T: Codable>(_ type: T.Type = T.self, key: String, account: String) -> T? {
        guard let data = try? Data(contentsOf: root.appending(path: key + ".json")),
              let entry = try? JSONDecoder().decode(Entry<T>.self, from: data),
              entry.account == account
        else { return nil }
        return entry.value
    }

    static func store<T: Codable>(_ value: T, key: String, account: String) {
        guard let data = try? JSONEncoder().encode(Entry(account: account, value: value)) else { return }
        let file = root.appending(path: key + ".json")
        // keys may nest, like asset-info/<id>.
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - storage

    /// bytes on disk. disk io, keep off main.
    static func diskUsage() -> Int64 {
        FileManager.default.allocatedSize(at: root)
    }

    /// contents only, so the directory keeps its backup exclusion.
    static func removeAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

extension FileManager {
    /// allocated bytes of everything under url, zero when absent.
    nonisolated func allocatedSize(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: keys)
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
