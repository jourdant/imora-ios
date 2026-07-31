import Foundation
import Observation
import Photos
import os

nonisolated let backupLog = Logger(subsystem: "app.imora", category: "backup")

nonisolated enum BackupPhase: Equatable {
    case idle
    case scanning
    case hashing(done: Int, total: Int)
    case checking
    case uploading(done: Int, total: Int)
    case done(BackupSummary)
    case error(String)
}

nonisolated struct BackupSummary: Equatable, Sendable {
    var uploaded = 0
    var duplicates = 0
    var failed = 0
    var skipped = 0
    var unsupported = 0
}

nonisolated struct CleanupReport: Equatable, Sendable {
    var eligible: [String] = []
    var keptLocalOnly = 0
}

/// live per-asset upload state, keyed by local identifier. drives the
/// progress overlay on timeline tiles.
nonisolated enum LocalUploadState: Equatable, Sendable {
    case uploading(Double)
    case failed
}

/// device asset paired with what the backup index knows about it.
nonisolated struct LocalTimelineItem: Sendable {
    let device: DeviceAsset
    let remoteId: String?
    let backedUp: Bool
}

/// per-install identifier sent as deviceId on uploads. dedup is checksum
/// based, so a fresh id after reinstall is harmless.
nonisolated enum DeviceID {
    private static let key = "imora.deviceId"

    static var current: String {
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}

/// orchestrates the backup pipeline: scan, hash, bulk-check, upload. state
/// mutations stay on the main actor; heavy work runs in the services.
@Observable
final class BackupManager {
    static let autoBackupKey = "imora.backupEnabled"
    private static let uploadWorkers = 3
    private static let checkBatchSize = 100

    private(set) var phase: BackupPhase = .idle
    private(set) var summary = BackupSummary()
    /// first per-asset failure of the current run, for display next to counts.
    private(set) var lastFailure: String?
    var userId: String?

    /// per-asset upload progress for tile overlays.
    private(set) var uploadStates: [String: LocalUploadState] = [:]
    /// remote ids proven to be fully backed up from this device, for the
    /// merged cloud badge on remote tiles.
    private(set) var backedUpRemoteIds: Set<String> = []
    /// wired by sessionstore to the realtime hub, which debounces.
    var onLocalChange: (() -> Void)?

    var autoBackup: Bool {
        didSet {
            UserDefaults.standard.set(autoBackup, forKey: Self.autoBackupKey)
            if autoBackup {
                Task { await self.enableAndStart() }
            } else {
                updateChangeObserver()
            }
        }
    }

    var isRunning: Bool {
        switch phase {
        case .scanning, .hashing, .checking, .uploading: true
        default: false
        }
    }

    private let client: ImmichClient
    private let index: BackupIndex
    private var runTask: Task<Void, Never>?
    private var rerunRequested = false
    private var changeObserver: LibraryChangeObserver?

    nonisolated static var scratchDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "backup")
    }

    init(client: ImmichClient) {
        self.client = client
        self.autoBackup = UserDefaults.standard.bool(forKey: Self.autoBackupKey)
        self.index = BackupIndex()
        // stale exports from a killed run are useless without their request.
        let scratch = Self.scratchDirectory
        Task.detached { try? FileManager.default.removeItem(at: scratch) }
        updateChangeObserver()
    }

    /// called by sessionstore on logout. the manager must not outlive its client.
    func shutdown() {
        runTask?.cancel()
        runTask = nil
        if let changeObserver {
            PHPhotoLibrary.shared().unregisterChangeObserver(changeObserver)
            self.changeObserver = nil
        }
    }

    // MARK: - triggers

    func start() {
        guard !isRunning else { return }
        runTask = Task { await run() }
    }

    func cancel() {
        runTask?.cancel()
    }

    func startIfIdle() {
        guard autoBackup, !isRunning, PhotoLibraryService.hasFullAccess else { return }
        start()
    }

    private func enableAndStart() async {
        guard await PhotoLibraryService.requestFullAccess() else {
            phase = .error("full photo library access is required for backup.")
            updateChangeObserver()
            return
        }
        updateChangeObserver()
        if !isRunning { start() }
    }

    /// the observer keeps the merged timeline fresh, so it registers with
    /// full access alone - auto backup only decides whether uploads start.
    private func updateChangeObserver() {
        if PhotoLibraryService.hasFullAccess {
            guard changeObserver == nil else { return }
            let observer = LibraryChangeObserver { [weak self] in
                guard let self else { return }
                Task { @MainActor in self.libraryChanged() }
            }
            PHPhotoLibrary.shared().register(observer)
            changeObserver = observer
        } else if let changeObserver {
            PHPhotoLibrary.shared().unregisterChangeObserver(changeObserver)
            self.changeObserver = nil
        }
    }

    private func libraryChanged() {
        LocalImageLoader.shared.noteLibraryChange()
        localChanged()
        if isRunning {
            rerunRequested = true
        } else {
            startIfIdle()
        }
    }

    // MARK: - local timeline support

    /// refreshes the badge snapshot and tells the hub the device library or
    /// index changed.
    private func localChanged() {
        Task { [weak self] in
            guard let self else { return }
            self.backedUpRemoteIds = await self.index.backedUpRemoteIds()
            self.onLocalChange?()
        }
    }

    /// loads the index for the signed-in account so badges and the merged
    /// timeline are right from the first frame.
    func primeLocalState() async {
        guard let userId else { return }
        await index.load(serverHost: client.apiURL.host() ?? "", userId: userId)
        backedUpRemoteIds = await index.backedUpRemoteIds()
        updateChangeObserver()
        onLocalChange?()
    }

    /// every device asset paired with its backup status, newest first.
    func localTimelineAssets() async -> [LocalTimelineItem] {
        guard PhotoLibraryService.hasFullAccess, let userId else { return [] }
        await index.load(serverHost: client.apiURL.host() ?? "", userId: userId)
        let entries = await index.allEntries()
        let scanned = await PhotoLibraryService.scan()
        return scanned.map { asset in
            let entry = entries[asset.localIdentifier]
            return LocalTimelineItem(
                device: asset,
                remoteId: entry?.primaryRemoteId,
                backedUp: entry?.isBackedUp ?? false
            )
        }
    }

    private func noteUploadProgress(_ localId: String, _ fraction: Double) {
        guard case .uploading(let current) = uploadStates[localId] else { return }
        // quantized so progress redraws stay coarse.
        guard fraction >= 1 || fraction - current >= 0.02 else { return }
        uploadStates[localId] = .uploading(min(fraction, 1))
    }

    // MARK: - pipeline

    private func run() async {
        summary = BackupSummary()
        lastFailure = nil
        phase = .scanning
        do {
            guard await PhotoLibraryService.requestFullAccess() else {
                phase = .error("full photo library access is required for backup.")
                runTask = nil
                return
            }
            let user = try await client.currentUser()
            userId = user.id
            await index.load(serverHost: client.apiURL.host() ?? "", userId: user.id)

            let scanned = await PhotoLibraryService.scan()
            try Task.checkCancellation()
            await index.prune(keeping: Set(scanned.map(\.localIdentifier)))

            try await hashPhase(scanned)
            let pending = try await checkPhase(scanned)
            localChanged()
            try await uploadPhase(pending)

            await index.save()
            phase = .done(summary)
        } catch is CancellationError {
            await index.save()
            phase = .idle
        } catch {
            await index.save()
            phase = .error(error.localizedDescription)
        }
        uploadStates.removeAll()
        localChanged()
        runTask = nil
        if rerunRequested {
            rerunRequested = false
            startIfIdle()
        }
    }

    private func hashPhase(_ scanned: [DeviceAsset]) async throws {
        var toHash: [DeviceAsset] = []
        for asset in scanned {
            let entry = await index.entry(for: asset.localIdentifier)
            if entry == nil || entry?.matches(modificationDate: asset.modificationDate) != true {
                toHash.append(asset)
            }
        }
        phase = .hashing(done: 0, total: toHash.count)
        for (i, asset) in toHash.enumerated() {
            try Task.checkCancellation()
            do {
                let hashes = try await PhotoLibraryService.hash(
                    localIdentifier: asset.localIdentifier,
                    includeMotion: asset.isLivePhoto
                )
                await index.setHashed(
                    localId: asset.localIdentifier,
                    isLivePhoto: asset.isLivePhoto,
                    primaryChecksum: hashes.primary,
                    motionChecksum: hashes.motion,
                    modificationDate: asset.modificationDate
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                backupLog.error("hash failed for \(asset.localIdentifier): \(error)")
                if lastFailure == nil { lastFailure = "\(error)" }
                summary.failed += 1
            }
            if (i + 1) % 50 == 0 { await index.save() }
            phase = .hashing(done: i + 1, total: toHash.count)
        }
        await index.save()
    }

    /// asks the server about every hashed component we cannot prove yet, then
    /// returns the assets that still need uploads.
    private func checkPhase(_ scanned: [DeviceAsset]) async throws -> [DeviceAsset] {
        phase = .checking
        var pending: [DeviceAsset] = []
        var items: [BulkUploadCheckItem] = []
        for asset in scanned {
            guard let entry = await index.entry(for: asset.localIdentifier) else { continue }
            if entry.unsupported {
                summary.unsupported += 1
                continue
            }
            if entry.isBackedUp { continue }
            pending.append(asset)
            if entry.primaryRemoteId == nil {
                items.append(BulkUploadCheckItem(id: asset.localIdentifier, checksum: entry.primaryChecksum))
            }
            if entry.isLivePhoto, entry.motionRemoteId == nil, let motion = entry.motionChecksum {
                items.append(BulkUploadCheckItem(id: asset.localIdentifier + Self.motionSuffix, checksum: motion))
            }
        }

        for batch in items.chunks(of: Self.checkBatchSize) {
            try Task.checkCancellation()
            let results = try await client.bulkUploadCheck(batch)
            for result in results {
                let isMotion = result.id.hasSuffix(Self.motionSuffix)
                let localId = isMotion ? String(result.id.dropLast(Self.motionSuffix.count)) : result.id
                if result.isConfirmedDuplicate, let assetId = result.assetId {
                    // a trashed duplicate still proves the bytes exist for upload
                    // purposes; cleanup re-verifies with the stricter rule.
                    if isMotion {
                        await index.setMotionRemoteId(localId: localId, assetId)
                    } else {
                        await index.setPrimaryRemoteId(localId: localId, assetId)
                    }
                } else if result.isUnsupported {
                    await index.markUnsupported(localId: localId)
                }
            }
            await index.save()
        }

        var uploadQueue: [DeviceAsset] = []
        for asset in pending {
            guard let entry = await index.entry(for: asset.localIdentifier) else { continue }
            if entry.unsupported {
                summary.unsupported += 1
            } else if entry.isBackedUp {
                summary.duplicates += 1
            } else {
                uploadQueue.append(asset)
            }
        }
        return uploadQueue
    }

    private func uploadPhase(_ queue: [DeviceAsset]) async throws {
        guard !queue.isEmpty else { return }
        phase = .uploading(done: 0, total: queue.count)
        let client = client
        let index = index
        let deviceId = DeviceID.current
        let scratch = Self.scratchDirectory
        var quotaMessage: String?
        let progress: @Sendable (String, Double) -> Void = { [weak self] localId, fraction in
            Task { @MainActor in self?.noteUploadProgress(localId, fraction) }
        }

        await withTaskGroup(of: (String, UploadOutcome).self) { group in
            var next = 0
            var done = 0
            func addNext() {
                guard next < queue.count, quotaMessage == nil else { return }
                let asset = queue[next]
                next += 1
                uploadStates[asset.localIdentifier] = .uploading(0)
                group.addTask {
                    let outcome = await Self.uploadOne(
                        asset: asset, client: client, index: index,
                        deviceId: deviceId, scratch: scratch, onProgress: progress
                    )
                    return (asset.localIdentifier, outcome)
                }
            }
            for _ in 0..<Self.uploadWorkers { addNext() }
            while let (localId, outcome) = await group.next() {
                done += 1
                switch outcome {
                case .uploaded:
                    summary.uploaded += 1
                    uploadStates[localId] = nil
                case .duplicate:
                    summary.duplicates += 1
                    uploadStates[localId] = nil
                case .failed(let reason):
                    if lastFailure == nil { lastFailure = reason }
                    summary.failed += 1
                    markUploadFailed(localId)
                case .skipped:
                    summary.skipped += 1
                    uploadStates[localId] = nil
                case .quota(let message):
                    // nothing else can succeed once the account is full.
                    quotaMessage = message
                    uploadStates[localId] = nil
                    group.cancelAll()
                }
                localChanged()
                phase = .uploading(done: done, total: queue.count)
                addNext()
            }
        }
        try Task.checkCancellation()
        if let quotaMessage {
            throw ImmichError.http(400, quotaMessage)
        }
    }

    /// the red error overlay lingers briefly, then the tile falls back to
    /// the not-backed-up badge, mirroring the official client.
    private func markUploadFailed(_ localId: String) {
        uploadStates[localId] = .failed
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.uploadStates[localId] == .failed else { return }
            self.uploadStates[localId] = nil
        }
    }

    private nonisolated static let motionSuffix = "#motion"

    private nonisolated enum UploadOutcome: Sendable {
        case uploaded
        case duplicate
        case failed(String)
        case skipped
        case quota(String)
    }

    /// uploads every missing component of one asset. motion first for live
    /// photos so the still can link it via livePhotoVideoId.
    @concurrent
    private static func uploadOne(
        asset: DeviceAsset,
        client: ImmichClient,
        index: BackupIndex,
        deviceId: String,
        scratch: URL,
        onProgress: @escaping @Sendable (String, Double) -> Void
    ) async -> UploadOutcome {
        // the asset may have changed or vanished since the scan.
        guard let current = await PhotoLibraryService.assetInfo(localIdentifier: asset.localIdentifier) else {
            return .skipped
        }
        var entry = await index.entry(for: asset.localIdentifier)
        if entry == nil || entry?.matches(modificationDate: current.modificationDate) != true {
            do {
                let hashes = try await PhotoLibraryService.hash(
                    localIdentifier: current.localIdentifier,
                    includeMotion: current.isLivePhoto
                )
                await index.setHashed(
                    localId: current.localIdentifier,
                    isLivePhoto: current.isLivePhoto,
                    primaryChecksum: hashes.primary,
                    motionChecksum: hashes.motion,
                    modificationDate: current.modificationDate
                )
                entry = await index.entry(for: current.localIdentifier)
            } catch is CancellationError {
                return .skipped
            } catch {
                return .failed("rehash: \(error)")
            }
        }
        guard let entry else { return .failed("no index entry") }
        if entry.isBackedUp { return .duplicate }

        let createdAt = current.creationDate ?? current.modificationDate ?? Date()
        let modifiedAt = current.modificationDate ?? createdAt
        var uploadedSomething = false

        do {
            var motionRemoteId = entry.motionRemoteId
            if current.isLivePhoto, motionRemoteId == nil {
                guard let motionChecksum = entry.motionChecksum else { return .failed("missing motion checksum") }
                let exported = try await PhotoLibraryService.exportMotion(
                    localIdentifier: current.localIdentifier, to: scratch
                )
                let result = try await client.uploadAsset(AssetUploadRequest(
                    fileURL: exported.fileURL,
                    checksum: motionChecksum,
                    filename: exported.filename,
                    deviceAssetId: current.localIdentifier,
                    deviceId: deviceId,
                    fileCreatedAt: createdAt,
                    fileModifiedAt: modifiedAt,
                    isFavorite: false,
                    durationMs: 0,
                    hidden: true
                )) { fraction in
                    onProgress(current.localIdentifier, fraction)
                }
                // persisted immediately so a failed still upload resumes here.
                await index.setMotionRemoteId(localId: current.localIdentifier, result.id)
                await index.save()
                motionRemoteId = result.id
                if !result.isDuplicate { uploadedSomething = true }
            }

            if entry.primaryRemoteId == nil {
                let exported = try await PhotoLibraryService.exportPrimary(
                    localIdentifier: current.localIdentifier, to: scratch
                )
                let result = try await client.uploadAsset(AssetUploadRequest(
                    fileURL: exported.fileURL,
                    checksum: entry.primaryChecksum,
                    filename: exported.filename,
                    deviceAssetId: current.localIdentifier,
                    deviceId: deviceId,
                    fileCreatedAt: createdAt,
                    fileModifiedAt: modifiedAt,
                    isFavorite: current.isFavorite,
                    durationMs: current.isVideo ? current.durationMs : 0,
                    livePhotoVideoId: motionRemoteId
                )) { fraction in
                    onProgress(current.localIdentifier, fraction)
                }
                await index.setPrimaryRemoteId(localId: current.localIdentifier, result.id)
                await index.save()
                if !result.isDuplicate { uploadedSomething = true }
            }
            return uploadedSomething ? .uploaded : .duplicate
        } catch is CancellationError {
            return .skipped
        } catch let ImmichError.http(_, message) where message.lowercased().contains("quota") {
            return .quota(message)
        } catch {
            backupLog.error("upload failed for \(asset.localIdentifier): \(error)")
            return .failed("\(error)")
        }
    }

    // MARK: - viewer support

    /// resolves a remote asset to a device asset when the index proves the
    /// pairing and the phasset still exists. never prompts for access.
    func localIdentifier(forRemote remoteId: String) async -> String? {
        guard PhotoLibraryService.hasFullAccess, let userId else { return nil }
        await index.load(serverHost: client.apiURL.host() ?? "", userId: userId)
        guard let localId = await index.localId(forRemote: remoteId) else { return nil }
        return PhotoLibraryService.assetExists(localIdentifier: localId) ? localId : nil
    }

    func noteLocalDeletion(_ localIds: [String]) {
        Task {
            await index.remove(ids: localIds)
            await index.save()
            localChanged()
        }
    }

    // MARK: - download

    /// downloads a server asset into the photo library, verifying the bytes
    /// against the server checksum, and records the pairing in the index.
    /// returns the new local identifier.
    func download(asset: Asset) async throws -> String {
        guard await PhotoLibraryService.requestFullAccess() else {
            throw ImmichError.http(0, "full photo library access is required to download.")
        }
        let user = try await client.currentUser()
        userId = user.id
        await index.load(serverHost: client.apiURL.host() ?? "", userId: user.id)

        let detail = try await client.assetDetail(id: asset.id)
        let scratch = Self.scratchDirectory
        let primaryExtension = URL(fileURLWithPath: detail.originalFileName).pathExtension
        let primaryURL = try await client.downloadOriginal(assetID: asset.id, to: scratch, fileExtension: primaryExtension)
        var motionURL: URL?
        do {
            let primaryChecksum = try await PhotoLibraryService.sha1Base64(ofFile: primaryURL)
            if let expected = detail.checksum, expected != primaryChecksum {
                throw ImmichError.decoding("downloaded bytes do not match the server checksum")
            }
            var motionChecksum: String?
            if let motionId = detail.livePhotoVideoId {
                let url = try await client.downloadOriginal(assetID: motionId, to: scratch, fileExtension: "mov")
                motionURL = url
                motionChecksum = try await PhotoLibraryService.sha1Base64(ofFile: url)
            }

            let localId = try await PhotoLibraryService.importAsset(
                primaryURL: primaryURL,
                isVideo: detail.type == .video,
                filename: detail.originalFileName,
                motionURL: motionURL
            )
            let info = await PhotoLibraryService.assetInfo(localIdentifier: localId)
            await index.setHashed(
                localId: localId,
                isLivePhoto: motionURL != nil,
                primaryChecksum: primaryChecksum,
                motionChecksum: motionChecksum,
                modificationDate: info?.modificationDate
            )
            await index.setPrimaryRemoteId(localId: localId, asset.id)
            if let motionId = detail.livePhotoVideoId {
                await index.setMotionRemoteId(localId: localId, motionId)
            }
            await index.save()
            localChanged()
            return localId
        } catch {
            // on success the files were moved into the library; on any failure
            // whatever remains in scratch is ours to clean.
            try? FileManager.default.removeItem(at: primaryURL)
            if let motionURL { try? FileManager.default.removeItem(at: motionURL) }
            throw error
        }
    }

    // MARK: - cleanup

    /// finds device assets that are provably safe to delete: fully backed up,
    /// unmodified since hashing, re-verified against the server right now.
    func cleanUpCandidates() async throws -> CleanupReport {
        guard PhotoLibraryService.hasFullAccess else {
            throw ImmichError.http(0, "full photo library access is required to clean up the device.")
        }
        let user = try await client.currentUser()
        userId = user.id
        await index.load(serverHost: client.apiURL.host() ?? "", userId: user.id)

        let scanned = await PhotoLibraryService.scan()
        var candidates: [DeviceAsset] = []
        for asset in scanned {
            guard let entry = await index.entry(for: asset.localIdentifier),
                  !entry.unsupported,
                  entry.isBackedUp,
                  entry.matches(modificationDate: asset.modificationDate)
            else { continue }
            candidates.append(asset)
        }

        // cleanup is stricter than upload dedup: a trashed server copy can be
        // purged at any time, so it does not justify deleting the device copy.
        var verified: Set<String> = []
        var rejected: Set<String> = []
        var items: [BulkUploadCheckItem] = []
        for asset in candidates {
            guard let entry = await index.entry(for: asset.localIdentifier) else { continue }
            items.append(BulkUploadCheckItem(id: asset.localIdentifier, checksum: entry.primaryChecksum))
            if entry.isLivePhoto, let motion = entry.motionChecksum {
                items.append(BulkUploadCheckItem(id: asset.localIdentifier + Self.motionSuffix, checksum: motion))
            }
        }
        for batch in items.chunks(of: Self.checkBatchSize) {
            let results = try await client.bulkUploadCheck(batch)
            for result in results {
                let isMotion = result.id.hasSuffix(Self.motionSuffix)
                let localId = isMotion ? String(result.id.dropLast(Self.motionSuffix.count)) : result.id
                if result.isConfirmedDuplicate, result.isTrashed != true {
                    continue
                }
                rejected.insert(localId)
                // an accepted checksum means the server lost these bytes.
                if result.action == "accept" {
                    if isMotion {
                        await index.clearMotionRemoteId(localId: localId)
                    } else {
                        await index.clearPrimaryRemoteId(localId: localId)
                    }
                }
            }
        }

        for asset in candidates where !rejected.contains(asset.localIdentifier) {
            if asset.isLivePhoto {
                // checksum presence alone does not prove the server links the
                // motion video; an unlinked still would silently lose it.
                guard let entry = await index.entry(for: asset.localIdentifier),
                      let remoteId = entry.primaryRemoteId,
                      let detail = try? await client.assetDetail(id: remoteId),
                      detail.livePhotoVideoId != nil
                else { continue }
            }
            verified.insert(asset.localIdentifier)
        }
        await index.save()

        return CleanupReport(
            eligible: candidates.map(\.localIdentifier).filter { verified.contains($0) },
            keptLocalOnly: scanned.count - verified.count
        )
    }

    /// deletes the given device assets in one batch - exactly one system
    /// confirmation dialog. throws userCancelled when the user declines.
    func performCleanup(ids: [String]) async throws -> Int {
        try await PhotoLibraryService.delete(localIdentifiers: ids)
        await index.remove(ids: ids)
        await index.save()
        localChanged()
        return ids.count
    }
}

/// forwards photokit change notifications; registration is managed by backupmanager.
private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, Sendable {
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}

private extension Array {
    nonisolated func chunks(of size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
