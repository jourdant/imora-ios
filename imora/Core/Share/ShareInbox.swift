import Foundation

// NOTE: this file is duplicated verbatim in imoraShare/ShareInbox.swift.
// the share extension and the app are separate modules with no shared target,
// and this is the contract between them - change both or neither.

/// one drop from the share sheet. written as <id>.json beside the media it
/// describes, so the extension and the app never write the same file and no
/// coordination is needed.
nonisolated struct ShareBatch: Codable, Identifiable, Sendable {
    nonisolated struct Item: Codable, Identifiable, Sendable {
        let id: String
        /// name of the copy sitting in the inbox directory
        let storedName: String
        /// name to send to the server
        let filename: String
        let isVideo: Bool
    }

    let id: String
    let addedAt: Date
    let items: [Item]
}

nonisolated enum ShareInbox {
    /// the group id is stamped into both info plists from one build setting, so
    /// the two targets cannot drift apart.
    static var appGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "IMORAAppGroup") as? String
    }

    static var directory: URL? {
        guard let appGroup,
              let container = FileManager.default
                  .containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else { return nil }
        return container.appending(path: "inbox")
    }

    static func fileURL(for item: ShareBatch.Item) -> URL? {
        directory?.appending(path: item.storedName)
    }

    static func write(_ batch: ShareBatch) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(batch) else { return }
        try? data.write(to: directory.appending(path: "\(batch.id).json"), options: .atomic)
    }

    /// oldest first, so a queue of drops uploads in the order they were made.
    static func batches() -> [ShareBatch] {
        guard let directory else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(ShareBatch.self, from: data)
            }
            .sorted { $0.addedAt < $1.addedAt }
    }

    /// drops the descriptor first: a half-deleted batch that still has media
    /// files is only wasted space, one that still has a descriptor uploads twice.
    static func remove(_ batch: ShareBatch) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory.appending(path: "\(batch.id).json"))
        for item in batch.items {
            try? FileManager.default.removeItem(at: directory.appending(path: item.storedName))
        }
    }
}
