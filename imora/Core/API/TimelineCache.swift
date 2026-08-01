import Foundation
import os

/// last known bucket list per grid. a cold launch builds month headers and
/// correctly sized placeholders from this before the first frame, so the tabs
/// come up scrollable instead of holding a spinner. the real list lands a
/// moment later and replaces it; the worst a stale entry can do is size a
/// placeholder wrong for a second.
nonisolated enum TimelineCache {
    private struct Entry: Codable {
        let account: String
        let buckets: [TimeBucket]
    }

    /// swiftui rebuilds a screen's state initializer on every re-render, so the
    /// same list would otherwise be read and decoded again each time.
    private static let memo = OSAllocatedUnfairLock<[String: [TimeBucket]]>(initialState: [:])

    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "imora/buckets")
    }

    /// only the grids reachable straight from a launch are cached. album,
    /// person and map grids are opened deliberately and would leave a file
    /// behind for every one ever visited.
    static func key(for filter: TimelineFilter) -> String? {
        guard filter.albumId == nil, filter.personId == nil, filter.bbox == nil, filter.userId == nil else {
            return nil
        }
        let parts = filter.queryItems.map { "\($0.name)=\($0.value ?? "")" }
        return parts.isEmpty ? "default" : parts.joined(separator: "&")
    }

    static func buckets(for filter: TimelineFilter, account: String) -> [TimeBucket]? {
        guard let key = key(for: filter) else { return nil }
        let memoKey = "\(account)|\(key)"
        if let known = memo.withLock({ $0[memoKey] }) { return known }
        guard let data = try? Data(contentsOf: fileURL(key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.account == account
        else { return nil }
        memo.withLock { $0[memoKey] = entry.buckets }
        return entry.buckets
    }

    static func store(_ buckets: [TimeBucket], for filter: TimelineFilter, account: String) {
        guard let key = key(for: filter) else { return }
        memo.withLock { $0["\(account)|\(key)"] = buckets }
        guard let data = try? JSONEncoder().encode(Entry(account: account, buckets: buckets)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(key), options: .atomic)
    }

    private static func fileURL(_ key: String) -> URL {
        // the key is a query string; folded to a stable file name.
        let name = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        return directory.appending(path: String(name) + ".json")
    }
}
