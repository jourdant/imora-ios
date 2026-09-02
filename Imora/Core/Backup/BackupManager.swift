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

nonisolated enum SingleAssetBackupError: LocalizedError {
    case missing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missing:
            "the photo is no longer available on this device."
        case .failed(let reason):
            reason
        }
    }
}

/// outcome of a multi-select backup started from the grid.
nonisolated struct BulkBackupOutcome: Equatable, Sendable {
    var uploaded = 0
    var alreadyBackedUp = 0
    var skipped = 0
    var failed = 0
    var firstFailure: String?
}

/// device asset paired with what the backup index knows about it.
nonisolated struct LocalTimelineItem: Equatable, Sendable {
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

    private(set) var phase: BackupPhase = .idle {
        didSet { onContinuedProgress?() }
    }
    private(set) var summary = BackupSummary()
    /// first per-asset failure of the current run, for display next to counts.
    private(set) var lastFailure: String?
    var userId: String?

    /// per-asset upload progress for tile overlays.
    private(set) var uploadStates: [String: LocalUploadState] = [:]
    /// remote ids proven to be fully backed up from this device, for the
    /// merged cloud badge on remote tiles.
    private(set) var backedUpRemoteIds: Set<String> = []
    /// synchronous remote-to-device lookup so a tile whose device photo just
    /// finished uploading keeps rendering the same local thumbnail while the
    /// server thumbnail loads - the swap never flashes.
    private(set) var localIdentifierByRemoteId: [String: String] = [:]
    /// every verified index pairing, including server assets whose pixels were
    /// edited after upload. Action availability needs presence, while rendering
    /// deliberately uses the stricter map above.
    private(set) var pairedLocalIdentifierByRemoteId: [String: String] = [:]
    /// inverse of the complete pairing map. A still-open local viewer uses this
    /// immediately after a manual upload to address its new server copy.
    private(set) var remoteIdentifierByLocalId: [String: String] = [:]
    /// wired by sessionstore to the realtime hub, which debounces.
    var onLocalChange: (() -> Void)?
    /// wired by sessionstore to raise the end-of-run notification. carries the
    /// terminal phase so a cancelled run stays silent. not called when the
    /// server was unreachable - every launch and foreground retries, and each
    /// retry would repeat the same banner.
    var onRunFinished: ((BackupPhase) -> Void)?
    /// wired by the continued-processing task, which has to keep feeding the
    /// system progress ui or the scheduler expires it.
    var onContinuedProgress: (() -> Void)?

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
    private var localChangedTask: Task<Void, Never>?
    /// whether the current or next run may upload. false makes the run a
    /// passive reconcile - scan, hash and bulk-check only - which rebuilds
    /// the index quietly and ends back at idle.
    private var runAllowsUploads = true
    private var rerunRequested = false
    private var changeObserver: LibraryChangeObserver?
    /// uploads that landed in the index without a run to count them, i.e. while
    /// the app was suspended or gone.
    private var adoptedUploads = 0

    /// host|userId, stamped onto every background upload so a completion can
    /// never be applied to a different account's index.
    private var accountKey: String {
        SessionCache.accountKey(host: client.apiURL.host() ?? "")
    }

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
        localChangedTask?.cancel()
        localChangedTask = nil
        BackgroundUploader.shared.setOrphanHandler(nil)
        BackgroundUploader.shared.setEventsFinishedHandler(nil)
        // transfers outlive the process, so signing out has to stop them
        // explicitly or they would keep filling a stranger's library.
        BackgroundUploader.shared.cancelAll()
        if let changeObserver {
            PHPhotoLibrary.shared().unregisterChangeObserver(changeObserver)
            self.changeObserver = nil
        }
    }

    // MARK: - triggers

    func start() {
        // a run is already going: raise its upload gate instead of dropping
        // the ask. a passive reconcile reads the flag again before uploading.
        if runTask != nil {
            runAllowsUploads = true
            return
        }
        runAllowsUploads = true
        runTask = Task { await run() }
    }

    /// ensures a full upload run and suspends until the pipeline goes quiet.
    /// the continued-processing task has to outlive the whole run, so it needs
    /// something to await. escalation can chain a follow-up run, hence the loop.
    func runToCompletion() async {
        start()
        while let task = runTask {
            await task.value
        }
    }

    func cancel() {
        // stopping also withdraws any upload ask that raced this cancel.
        runAllowsUploads = false
        runTask?.cancel()
    }

    /// starts a full run when auto backup is on, and a passive reconcile
    /// otherwise, so assets already on the server are recognized - after a
    /// reinstall or an upload from another device - without sending anything.
    func startIfIdle() {
        guard runTask == nil, PhotoLibraryService.hasFullAccess else { return }
        runAllowsUploads = autoBackup
        runTask = Task { await run() }
    }

    private func enableAndStart() async {
        guard await PhotoLibraryService.requestFullAccess() else {
            phase = .error("full photo library access is required for backup.")
            updateChangeObserver()
            return
        }
        updateChangeObserver()
        start()
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
        // keyed on the task, not the phase: a change landing while the run
        // winds down must not be lost.
        if runTask != nil {
            rerunRequested = true
        } else {
            startIfIdle()
        }
    }

    // MARK: - local timeline support

    /// refreshes the badge snapshot and tells the hub the device library or
    /// index changed. coalesced: a run completes uploads several times a
    /// second, and rebuilding four full index maps per upload starved the
    /// main actor on large libraries.
    private func localChanged() {
        guard localChangedTask == nil else { return }
        localChangedTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            self.localChangedTask = nil
            await self.refreshLocalSnapshots()
        }
    }

    /// one hop for all four maps, built inside the actor: assembling them on
    /// the main actor was a visible hitch per upload on a large library.
    private func refreshLocalSnapshots() async {
        let snapshot = await index.localSnapshot()
        backedUpRemoteIds = snapshot.backedUpRemoteIds
        pairedLocalIdentifierByRemoteId = snapshot.localByRemote
        remoteIdentifierByLocalId = snapshot.remoteByLocal
        localIdentifierByRemoteId = snapshot.renderableLocalByRemote
        onLocalChange?()
    }

    /// the server repainted these assets, so their device twins are stale
    /// pixels. the pairing itself survives - deletes still cascade - but grids
    /// and the viewer go back to the server render for them.
    func noteRemoteEdits(_ remoteIds: Set<String>) {
        guard !remoteIds.isEmpty else { return }
        for id in remoteIds { localIdentifierByRemoteId[id] = nil }
        Task { [weak self] in
            guard let self, await self.index.markRemoteEdited(remoteIds) else { return }
            await self.index.save()
            self.localIdentifierByRemoteId = await self.index.renderableRemoteToLocalMap()
        }
    }

    /// loads the index for the signed-in account so badges and the merged
    /// timeline are right from the first frame.
    func primeLocalState() async {
        guard let userId else { return }
        await index.load(serverHost: client.apiURL.host() ?? "", userId: userId)
        await refreshLocalSnapshots()
        updateChangeObserver()
        adoptBackgroundUploads()
    }

    // MARK: - background uploads

    /// transfers handed to the system finish whether or not this process is
    /// still around. anything that landed while it was not has to reach the
    /// index here, or the next run would send the same bytes again.
    private func adoptBackgroundUploads() {
        BackgroundUploader.shared.setOrphanHandler { [weak self] completion in
            guard let manager = self else { return }
            Task { @MainActor in await manager.applyBackgroundUpload(completion) }
        }
        BackgroundUploader.shared.setEventsFinishedHandler { [weak self] in
            guard let manager = self else { return }
            Task { @MainActor in manager.reportAdoptedUploads() }
        }
        BackgroundUploader.shared.sweepAbandonedBodies()
    }

    private func applyBackgroundUpload(_ completion: BackgroundUploader.Completion) async {
        guard let userId, completion.ticket.account == accountKey else { return }
        await index.load(serverHost: client.apiURL.host() ?? "", userId: userId)
        if completion.ticket.isMotion {
            await index.setMotionRemoteId(localId: completion.ticket.localId, completion.remoteId)
        } else {
            await index.setPrimaryRemoteId(localId: completion.ticket.localId, completion.remoteId)
        }
        await index.save()
        adoptedUploads += 1
        localChanged()
    }

    /// the run that started these uploads is long gone, so the end-of-run
    /// notification never fired for them.
    private func reportAdoptedUploads() {
        guard adoptedUploads > 0 else { return }
        LocalNotifications.shared.deliverBackupReport(BackupSummary(uploaded: adoptedUploads))
        adoptedUploads = 0
    }

    /// every device asset paired with its backup status, newest first.
    func localTimelineAssets() async -> [LocalTimelineItem] {
        guard PhotoLibraryService.hasFullAccess, let userId else { return [] }
        // the library walk and the index decode are independent, and at
        // launch each is a few hundred milliseconds on a large library, so
        // they overlap instead of queueing.
        async let scanned = PhotoLibraryService.scan()
        await index.load(serverHost: client.apiURL.host() ?? "", userId: userId)
        let entries = await index.allEntries()
        return await scanned.map { asset in
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
        // a single large video can hold the phase still for minutes, and a
        // continued-processing task that stops reporting gets expired.
        onContinuedProgress?()
    }

    /// how far the current run has come, 0...1, counting the bytes already sent
    /// for uploads still in flight. hashing takes the first fifth because it
    /// runs before a single byte leaves the device.
    var progressFraction: Double {
        switch phase {
        case .idle, .scanning:
            0
        case .hashing(let done, let total):
            total > 0 ? 0.2 * Double(done) / Double(total) : 0
        case .checking:
            0.2
        case .uploading(let done, let total):
            total > 0 ? 0.2 + 0.8 * min(Double(done) + inFlightFraction, Double(total)) / Double(total) : 0.2
        case .done, .error:
            1
        }
    }

    private var inFlightFraction: Double {
        uploadStates.values.reduce(0) { total, state in
            if case .uploading(let fraction) = state { return total + fraction }
            return total
        }
    }

    // MARK: - pipeline

    private func run() async {
        var uploadsAllowed = runAllowsUploads
        var chainFullRun = false
        var reportsOutcome = true
        summary = BackupSummary()
        lastFailure = nil
        phase = .scanning
        do {
            if uploadsAllowed {
                guard await PhotoLibraryService.requestFullAccess() else {
                    phase = .error("full photo library access is required for backup.")
                    runTask = nil
                    return
                }
            } else {
                // a passive reconcile never prompts. access was there at spawn
                // and this only guards against it vanishing in between.
                guard PhotoLibraryService.hasFullAccess else {
                    phase = .idle
                    runTask = nil
                    return
                }
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
            // read again so a backup asked for during scan, hash or check
            // upgrades this run instead of waiting for the next one.
            uploadsAllowed = runAllowsUploads
            if uploadsAllowed {
                try await uploadPhase(pending)
            }

            await index.save()
            if uploadsAllowed {
                phase = .done(summary)
            } else {
                // a passive reconcile ends where it began: no summary, no
                // notification, just fresh pairings for the merged timeline.
                phase = .idle
                chainFullRun = runAllowsUploads
            }
        } catch is CancellationError {
            await index.save()
            phase = .idle
        } catch {
            await index.save()
            if runAllowsUploads {
                phase = .error(error.localizedDescription)
                // the backup screen still shows the error; the banner is
                // reserved for outcomes the server took part in.
                reportsOutcome = !Self.isUnreachable(error)
            } else {
                // nobody asked for this run, so it fails silently.
                backupLog.error("passive reconcile failed: \(error)")
                phase = .idle
            }
        }
        if reportsOutcome { onRunFinished?(phase) }
        uploadStates.removeAll()
        localChanged()
        runTask = nil
        if chainFullRun {
            // the upload ask arrived after the gate: run again, in full.
            start()
        } else if rerunRequested {
            rerunRequested = false
            startIfIdle()
        }
    }

    /// transport failures that mean the server never saw the request - offline,
    /// dns, timeouts. a run ending on one of these happens on every automatic
    /// retry while the network is away, so it is not an outcome to announce.
    private nonisolated static func isUnreachable(_ error: any Error) -> Bool {
        if case ImmichError.unreachable = error { return true }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    private func hashPhase(_ scanned: [DeviceAsset]) async throws {
        // one index snapshot rather than an actor hop per asset: on a large
        // library the hops alone kept the main actor busy for seconds on
        // every launch, under whatever the user was scrolling.
        let entries = await index.allEntries()
        var toHash: [DeviceAsset] = []
        for asset in scanned {
            let entry = entries[asset.localIdentifier]
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
        var entries = await index.allEntries()
        for asset in scanned {
            guard let entry = entries[asset.localIdentifier] else { continue }
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
        // re-read once: the bulk checks above changed what is proven.
        entries = await index.allEntries()
        for asset in pending {
            guard let entry = entries[asset.localIdentifier] else { continue }
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
        let account = accountKey
        var quotaMessage: String?
        let progress: @Sendable (String, Double) -> Void = { [weak self] localId, fraction in
            // bound once here: the nested task cannot capture the weak slot,
            // which is mutable and could be zeroed mid-flight.
            guard let self else { return }
            Task { @MainActor in self.noteUploadProgress(localId, fraction) }
        }

        await withTaskGroup(of: (String, UploadOutcome).self) { group in
            var next = 0
            var done = 0
            @MainActor func addNext() {
                guard next < queue.count, quotaMessage == nil else { return }
                let asset = queue[next]
                next += 1
                uploadStates[asset.localIdentifier] = .uploading(0)
                group.addTask {
                    let outcome = await Self.uploadOne(
                        asset: asset, client: client, index: index,
                        deviceId: deviceId, scratch: scratch, account: account,
                        onProgress: progress
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
        account: String,
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
        if entry.unsupported { return .failed("this file format is not supported by the server.") }
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
                    hidden: true,
                    isMotion: true
                ), account: account) { fraction in
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
                ), account: account) { fraction in
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

    /// Backs up exactly one device asset. This is intentionally independent of
    /// automatic-backup preferences: tapping Back Up is an explicit user action.
    /// The existing per-item pipeline retains checksum deduplication, Live Photo
    /// ordering, background transfer support, and progress reporting.
    func backUp(localIdentifier: String) async throws -> String {
        guard await PhotoLibraryService.requestFullAccess() else {
            throw ImmichError.http(0, "full photo library access is required for backup.")
        }
        let user = try await client.currentUser()
        userId = user.id
        await index.load(serverHost: client.apiURL.host() ?? "", userId: user.id)

        if case .uploading = uploadStates[localIdentifier] {
            try await waitForUpload(localIdentifier: localIdentifier)
        }
        if let entry = await index.entry(for: localIdentifier),
           entry.isBackedUp,
           let remoteID = entry.primaryRemoteId {
            await refreshLocalSnapshots()
            return remoteID
        }
        guard let asset = await PhotoLibraryService.assetInfo(localIdentifier: localIdentifier) else {
            throw SingleAssetBackupError.missing
        }

        uploadStates[localIdentifier] = .uploading(0)
        let progress: @Sendable (String, Double) -> Void = { [weak self] id, fraction in
            guard let self else { return }
            Task { @MainActor in self.noteUploadProgress(id, fraction) }
        }
        let outcome = await Self.uploadOne(
            asset: asset,
            client: client,
            index: index,
            deviceId: DeviceID.current,
            scratch: Self.scratchDirectory,
            account: accountKey,
            onProgress: progress
        )

        switch outcome {
        case .uploaded, .duplicate:
            uploadStates[localIdentifier] = nil
        case .failed(let reason):
            markUploadFailed(localIdentifier)
            throw SingleAssetBackupError.failed(reason)
        case .skipped:
            uploadStates[localIdentifier] = nil
            throw SingleAssetBackupError.missing
        case .quota(let message):
            uploadStates[localIdentifier] = nil
            throw ImmichError.http(400, message)
        }

        await index.save()
        await refreshLocalSnapshots()
        guard let remoteID = await index.entry(for: localIdentifier)?.primaryRemoteId else {
            throw SingleAssetBackupError.failed("the server did not return a backup identifier.")
        }
        return remoteID
    }

    /// backs up several device assets picked in the grid. setup runs once and
    /// uploads share the worker pool of a full run, so every tile keeps its
    /// own progress overlay. like the single-asset path, this ignores the
    /// automatic-backup preference: the selection is an explicit ask.
    func backUp(localIdentifiers: [String]) async throws -> BulkBackupOutcome {
        guard await PhotoLibraryService.requestFullAccess() else {
            throw ImmichError.http(0, "full photo library access is required for backup.")
        }
        let user = try await client.currentUser()
        userId = user.id
        await index.load(serverHost: client.apiURL.host() ?? "", userId: user.id)

        var outcome = BulkBackupOutcome()
        var queue: [DeviceAsset] = []
        for localId in localIdentifiers {
            // an upload already in flight from another trigger covers this one.
            if case .uploading = uploadStates[localId] {
                outcome.skipped += 1
                continue
            }
            if let entry = await index.entry(for: localId), entry.isBackedUp {
                outcome.alreadyBackedUp += 1
                continue
            }
            guard let asset = await PhotoLibraryService.assetInfo(localIdentifier: localId) else {
                outcome.skipped += 1
                continue
            }
            queue.append(asset)
        }
        guard !queue.isEmpty else {
            await refreshLocalSnapshots()
            return outcome
        }

        let client = client
        let index = index
        let deviceId = DeviceID.current
        let scratch = Self.scratchDirectory
        let account = accountKey
        var quotaMessage: String?
        let progress: @Sendable (String, Double) -> Void = { [weak self] localId, fraction in
            guard let self else { return }
            Task { @MainActor in self.noteUploadProgress(localId, fraction) }
        }

        await withTaskGroup(of: (String, UploadOutcome).self) { group in
            var next = 0
            @MainActor func addNext() {
                guard next < queue.count, quotaMessage == nil else { return }
                let asset = queue[next]
                next += 1
                uploadStates[asset.localIdentifier] = .uploading(0)
                group.addTask {
                    let result = await Self.uploadOne(
                        asset: asset, client: client, index: index,
                        deviceId: deviceId, scratch: scratch, account: account,
                        onProgress: progress
                    )
                    return (asset.localIdentifier, result)
                }
            }
            for _ in 0..<Self.uploadWorkers { addNext() }
            while let (localId, result) = await group.next() {
                switch result {
                case .uploaded:
                    outcome.uploaded += 1
                    uploadStates[localId] = nil
                case .duplicate:
                    outcome.alreadyBackedUp += 1
                    uploadStates[localId] = nil
                case .failed(let reason):
                    outcome.failed += 1
                    if outcome.firstFailure == nil { outcome.firstFailure = reason }
                    markUploadFailed(localId)
                case .skipped:
                    outcome.skipped += 1
                    uploadStates[localId] = nil
                case .quota(let message):
                    // nothing else can succeed once the account is full.
                    quotaMessage = message
                    uploadStates[localId] = nil
                    group.cancelAll()
                }
                localChanged()
                addNext()
            }
        }
        await index.save()
        await refreshLocalSnapshots()
        if let quotaMessage {
            throw ImmichError.http(400, quotaMessage)
        }
        return outcome
    }

    private func waitForUpload(localIdentifier: String) async throws {
        while case .uploading = uploadStates[localIdentifier] {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func remoteIdentifier(forLocal localIdentifier: String) async -> String? {
        guard PhotoLibraryService.hasFullAccess, let userId else { return nil }
        await index.load(serverHost: client.apiURL.host() ?? "", userId: userId)
        guard await PhotoLibraryService.assetExists(localIdentifier: localIdentifier) else { return nil }
        return await index.entry(for: localIdentifier)?.primaryRemoteId
    }

    /// resolves a remote asset to a device asset when the index proves the
    /// pairing and the phasset still exists. never prompts for access.
    func localIdentifier(forRemote remoteId: String) async -> String? {
        guard PhotoLibraryService.hasFullAccess, let userId else { return nil }
        await index.load(serverHost: client.apiURL.host() ?? "", userId: userId)
        guard let localId = await index.localId(forRemote: remoteId) else { return nil }
        return await PhotoLibraryService.assetExists(localIdentifier: localId) ? localId : nil
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
            if detail.isEdited == true {
                _ = await index.markRemoteEdited([asset.id])
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
        let entries = await index.allEntries()
        var candidates: [DeviceAsset] = []
        for asset in scanned {
            guard let entry = entries[asset.localIdentifier],
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
            guard let entry = entries[asset.localIdentifier] else { continue }
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

// MARK: - continued processing

extension BackupManager: ContinuedWorkload {
    var continuedTitle: String {
        switch phase {
        // a run with nothing to send is not an achievement to announce.
        case .done(let summary) where summary.uploaded == 0 && summary.failed == 0:
            "Already backed up"
        case .done: "Backup complete"
        case .error: "Backup stopped"
        default: "Backing up"
        }
    }

    var continuedSubtitle: String {
        switch phase {
        case .idle, .scanning: "Scanning library..."
        case .hashing(let done, let total): "Preparing \(done) of \(total)"
        case .checking: "Checking with your server..."
        case .uploading(let done, let total): "\(done) of \(total) uploaded"
        case .done(let summary) where summary.uploaded == 0 && summary.failed == 0:
            "Nothing new to send"
        case .done(let summary) where summary.failed > 0:
            "\(summary.uploaded) uploaded, \(summary.failed) failed"
        case .done(let summary): "\(summary.uploaded) uploaded"
        case .error(let message): message
        }
    }

    var continuedProgress: ContinuedProgress {
        ContinuedProgress(fraction: progressFraction)
    }

    var continuedSucceeded: Bool {
        if case .done = phase { return true }
        return false
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
