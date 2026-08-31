import Foundation
import os

/// offline store for timeline grids, in two layers. the bucket list per grid
/// lets a cold launch build month headers and correctly sized placeholders
/// before the first frame. the assets of every bucket ever fetched let the
/// grid render actual photos with no network at all - restored buckets are
/// marked stale by the model and refetched once the server is reachable, so
/// the worst a stale entry can do is show yesterday's grid for a moment.
///
/// lives in application support rather than caches so the system does not
/// purge it, and every file is account-tagged so switching servers or users
/// reads as a plain miss instead of leaking another library.
nonisolated enum TimelineCache {
    private struct ListEntry: Codable {
        let account: String
        let buckets: [TimeBucket]
    }

    private struct AssetsEntry: Codable {
        let account: String
        let assets: [Asset]
    }

    /// swiftui rebuilds a screen's state initializer on every re-render, so the
    /// same list would otherwise be read and decoded again each time.
    private static let memo = OSAllocatedUnfairLock<[String: [TimeBucket]]>(initialState: [:])

    private static let root: URL = {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "imora/timeline")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // everything here is re-downloadable, keep it out of device backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    /// only the grids reachable straight from a launch are cached. album,
    /// person and map grids are opened deliberately and would leave files
    /// behind for every one ever visited.
    static func key(for filter: TimelineFilter) -> String? {
        guard filter.albumId == nil, filter.personId == nil, filter.bbox == nil, filter.userId == nil else {
            return nil
        }
        let parts = filter.queryItems.map { "\($0.name)=\($0.value ?? "")" }
        return parts.isEmpty ? "default" : parts.joined(separator: "&")
    }

    // MARK: - bucket lists

    static func buckets(for filter: TimelineFilter, account: String) -> [TimeBucket]? {
        guard let key = key(for: filter) else { return nil }
        let memoKey = "\(account)|\(key)"
        if let known = memo.withLock({ $0[memoKey] }) { return known }
        guard let data = try? Data(contentsOf: listURL(key)),
              let entry = try? JSONDecoder().decode(ListEntry.self, from: data),
              entry.account == account
        else { return nil }
        memo.withLock { $0[memoKey] = entry.buckets }
        return entry.buckets
    }

    static func store(_ buckets: [TimeBucket], for filter: TimelineFilter, account: String) {
        guard let key = key(for: filter) else { return }
        memo.withLock { $0["\(account)|\(key)"] = buckets }
        // resyncs call this from the main actor on every event flush; the
        // memo above is what they need synchronously, the encode, write and
        // prune walk are disk work that can land whenever.
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(ListEntry(account: account, buckets: buckets)) else { return }
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? data.write(to: listURL(key), options: .atomic)
            pruneBucketAssets(keeping: Set(buckets.map(\.timeBucket)), filter: filter)
        }
    }

    // MARK: - bucket assets

    static func bucketAssets(_ bucketID: String, filter: TimelineFilter, account: String) -> [Asset]? {
        guard let key = key(for: filter),
              let data = try? Data(contentsOf: assetsURL(key, bucketID: bucketID)),
              let entry = try? JSONDecoder().decode(AssetsEntry.self, from: data),
              entry.account == account
        else { return nil }
        return entry.assets
    }

    static func storeBucketAssets(_ assets: [Asset], bucketID: String, filter: TimelineFilter, account: String) {
        guard let key = key(for: filter),
              let data = try? JSONEncoder().encode(AssetsEntry(account: account, assets: assets))
        else { return }
        try? FileManager.default.createDirectory(at: assetsDirectory(key), withIntermediateDirectories: true)
        try? data.write(to: assetsURL(key, bucketID: bucketID), options: .atomic)
    }

    /// reads the requested buckets in one pass, keyed by bucket id. misses and
    /// entries from another account are simply absent from the result.
    static func restoreBuckets(
        _ bucketIDs: some Collection<String>,
        filter: TimelineFilter,
        account: String
    ) -> [String: [Asset]] {
        var restored: [String: [Asset]] = [:]
        for bucketID in bucketIDs {
            if let assets = bucketAssets(bucketID, filter: filter, account: account) {
                restored[bucketID] = assets
            }
        }
        return restored
    }

    /// same read, decoded across cores. a fully cached large library is
    /// hundreds of per-bucket json files, and walking them serially held the
    /// offline grid back by seconds on cold launch.
    @concurrent
    static func restoreBucketsConcurrently(
        _ bucketIDs: [String],
        filter: TimelineFilter,
        account: String
    ) async -> [String: [Asset]] {
        let width = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
        return await withTaskGroup(of: (String, [Asset])?.self) { group in
            var iterator = bucketIDs.makeIterator()
            func addNext() {
                guard let id = iterator.next() else { return }
                group.addTask {
                    guard let assets = bucketAssets(id, filter: filter, account: account) else { return nil }
                    return (id, assets)
                }
            }
            for _ in 0..<width { addNext() }
            var restored: [String: [Asset]] = [:]
            while let result = await group.next() {
                if let (id, assets) = result { restored[id] = assets }
                addNext()
            }
            return restored
        }
    }

    /// drops asset files for buckets no longer in the list, e.g. a month whose
    /// last photos were deleted. called with every fresh list so the store
    /// tracks the library instead of growing forever.
    private static func pruneBucketAssets(keeping bucketIDs: Set<String>, filter: TimelineFilter) {
        guard let key = key(for: filter) else { return }
        let directory = assetsDirectory(key)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        let keep = Set(bucketIDs.map { fold($0) + ".json" })
        for file in files where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - storage

    /// bytes on disk. disk io, keep off main.
    static func diskUsage() -> Int64 {
        FileManager.default.allocatedSize(at: root)
    }

    /// contents only, so the directory keeps its backup exclusion. the memo
    /// goes too, otherwise a fresh grid would repaint from a list the disk no
    /// longer holds.
    static func removeAll() {
        memo.withLock { $0.removeAll() }
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - paths

    /// keys are query strings and bucket ids; folded to stable file names.
    private static func fold(_ raw: String) -> String {
        String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
    }

    private static func listURL(_ key: String) -> URL {
        root.appending(path: fold(key) + ".json")
    }

    private static func assetsDirectory(_ key: String) -> URL {
        root.appending(path: fold(key))
    }

    private static func assetsURL(_ key: String, bucketID: String) -> URL {
        assetsDirectory(key).appending(path: fold(bucketID) + ".json")
    }
}
