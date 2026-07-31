import Foundation

/// persisted backup state for one device asset. a live photo is backed up only
/// when both its still and its paired motion video are confirmed on the server.
nonisolated struct BackupEntry: Codable, Sendable, Equatable {
    /// phasset modification date at hash time. optional by design - never fabricated.
    var modificationDate: Date?
    var isLivePhoto: Bool
    var primaryChecksum: String
    var primaryRemoteId: String?
    var motionChecksum: String?
    var motionRemoteId: String?
    /// server rejected with unsupported-format. never uploaded again blindly, never cleanup-eligible.
    var unsupported: Bool

    init(
        modificationDate: Date?,
        isLivePhoto: Bool,
        primaryChecksum: String,
        primaryRemoteId: String? = nil,
        motionChecksum: String? = nil,
        motionRemoteId: String? = nil,
        unsupported: Bool = false
    ) {
        self.modificationDate = modificationDate
        self.isLivePhoto = isLivePhoto
        self.primaryChecksum = primaryChecksum
        self.primaryRemoteId = primaryRemoteId
        self.motionChecksum = motionChecksum
        self.motionRemoteId = motionRemoteId
        self.unsupported = unsupported
    }

    /// true when every component the asset has is known to exist server-side.
    var isBackedUp: Bool {
        guard primaryRemoteId != nil else { return false }
        return !isLivePhoto || motionRemoteId != nil
    }

    /// unchanged only when both dates are equal, including both nil.
    func matches(modificationDate date: Date?) -> Bool {
        modificationDate == date
    }
}

/// account-scoped map of device assets to their server backup state, persisted as json.
/// an actor so map mutations and file writes are serialized off the main actor.
actor BackupIndex {
    nonisolated struct Snapshot: Codable {
        var serverHost: String
        var userId: String
        var entries: [String: BackupEntry]
    }

    private let fileURL: URL
    private var serverHost = ""
    private var userId = ""
    private var entries: [String: BackupEntry] = [:]
    private var remoteToLocal: [String: String] = [:]
    private var loaded = false

    init(fileURL: URL = BackupIndex.defaultFileURL) {
        self.fileURL = fileURL
    }

    nonisolated static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "imora/backup-index.json")
    }

    /// reads the snapshot from disk. a snapshot written for a different server or
    /// user is discarded - accounts must never share local-to-remote mappings.
    func load(serverHost: String, userId: String) {
        if loaded, serverHost == self.serverHost, userId == self.userId { return }
        self.serverHost = serverHost
        self.userId = userId
        entries = [:]
        remoteToLocal = [:]
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.serverHost == serverHost, snapshot.userId == userId
        else { return }
        entries = snapshot.entries
        for (localId, entry) in entries {
            if let remoteId = entry.primaryRemoteId {
                remoteToLocal[remoteId] = localId
            }
        }
    }

    func save() {
        let snapshot = Snapshot(serverHost: serverHost, userId: userId, entries: entries)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    func entry(for localId: String) -> BackupEntry? {
        entries[localId]
    }

    func allEntries() -> [String: BackupEntry] {
        entries
    }

    /// records fresh checksums. remote ids survive only when the matching checksum
    /// is unchanged - different bytes on device mean the server copy is stale proof.
    func setHashed(
        localId: String,
        isLivePhoto: Bool,
        primaryChecksum: String,
        motionChecksum: String?,
        modificationDate: Date?
    ) {
        let old = entries[localId]
        var entry = BackupEntry(
            modificationDate: modificationDate,
            isLivePhoto: isLivePhoto,
            primaryChecksum: primaryChecksum,
            motionChecksum: motionChecksum
        )
        if let old {
            if old.primaryChecksum == primaryChecksum {
                entry.primaryRemoteId = old.primaryRemoteId
                entry.unsupported = old.unsupported
            } else if let stale = old.primaryRemoteId {
                remoteToLocal[stale] = nil
            }
            if old.motionChecksum == motionChecksum {
                entry.motionRemoteId = old.motionRemoteId
            }
        }
        entries[localId] = entry
        if let remoteId = entry.primaryRemoteId {
            remoteToLocal[remoteId] = localId
        }
    }

    func setPrimaryRemoteId(localId: String, _ remoteId: String) {
        guard var entry = entries[localId] else { return }
        if let stale = entry.primaryRemoteId {
            remoteToLocal[stale] = nil
        }
        entry.primaryRemoteId = remoteId
        entries[localId] = entry
        remoteToLocal[remoteId] = localId
    }

    func clearPrimaryRemoteId(localId: String) {
        guard var entry = entries[localId] else { return }
        if let stale = entry.primaryRemoteId {
            remoteToLocal[stale] = nil
        }
        entry.primaryRemoteId = nil
        entries[localId] = entry
    }

    func setMotionRemoteId(localId: String, _ remoteId: String) {
        guard var entry = entries[localId] else { return }
        entry.motionRemoteId = remoteId
        entries[localId] = entry
    }

    func clearMotionRemoteId(localId: String) {
        guard var entry = entries[localId] else { return }
        entry.motionRemoteId = nil
        entries[localId] = entry
    }

    func markUnsupported(localId: String) {
        guard var entry = entries[localId] else { return }
        entry.unsupported = true
        entries[localId] = entry
    }

    func remove(ids: [String]) {
        for localId in ids {
            if let remoteId = entries[localId]?.primaryRemoteId {
                remoteToLocal[remoteId] = nil
            }
            entries[localId] = nil
        }
    }

    /// drops entries for assets no longer on the device. only ever called after a
    /// full-access scan - a limited scan hides assets and would erase valid state.
    func prune(keeping localIds: Set<String>) {
        let gone = entries.keys.filter { !localIds.contains($0) }
        remove(ids: gone)
    }

    func localId(forRemote remoteId: String) -> String? {
        remoteToLocal[remoteId]
    }

    /// remote-to-device pairing snapshot so tiles can reuse the device
    /// thumbnail as an instant placeholder for their server twin.
    func remoteToLocalMap() -> [String: String] {
        remoteToLocal
    }

    /// remote ids of assets that exist on this device and are fully backed
    /// up. drives the merged cloud badge on timeline tiles.
    func backedUpRemoteIds() -> Set<String> {
        var ids: Set<String> = []
        ids.reserveCapacity(entries.count)
        for entry in entries.values where entry.isBackedUp {
            if let remoteId = entry.primaryRemoteId {
                ids.insert(remoteId)
            }
        }
        return ids
    }
}
