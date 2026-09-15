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
    /// the user stopped the run, or the system reclaimed it. nothing to
    /// announce, and the next launch or foreground picks up where it left off.
    case cancelled
}

nonisolated struct BackupSummary: Equatable, Sendable {
    var uploadedMedia = MediaCounts()
    var duplicateMedia = MediaCounts()
    var failedMedia = MediaCounts()
    var skippedMedia = MediaCounts()
    var unsupportedMedia = MediaCounts()
    var uploaded: Int { uploadedMedia.total }
    var duplicates: Int { duplicateMedia.total }
    var failed: Int { failedMedia.total }
    var skipped: Int { skippedMedia.total }
    var unsupported: Int { unsupportedMedia.total }
}

nonisolated struct CleanupReport: Equatable, Sendable {
    var eligible: [String] = []
    var eligibleMedia = MediaCounts()
    var keptMedia = MediaCounts()
    var keptLocalOnly: Int { keptMedia.total }
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
    static let cellularBackupKey = "imora.backupOnCellular"
    static let dateOrderKey = "imora.backupDateOrder"
    static let mediaPriorityKey = "imora.backupMediaPriority"
    static let hashWorkersKey = "imora.backupHashWorkers"
    static let hashWorkerOptions = [1, 3, 5, 8, 16, 32]
    static let defaultHashWorkers = 32
    private static let uploadWorkers = 3
    private nonisolated static let verificationWorkers = 8
    private nonisolated static let checkBatchSize = 100

    private(set) var phase: BackupPhase = .idle {
        didSet { onContinuedProgress?() }
    }
    private(set) var summary = BackupSummary()
    /// first per-asset failure of the current run, for display next to counts.
    private(set) var lastFailure: String?
    /// true once PhotoKit proves that this preparation pass had to fetch an
    /// original from iCloud. iOS exposes no supported global Optimize Storage
    /// flag, so the UI reports the resource-level fact instead.
    private(set) var downloadedOriginalsFromICloud = false
    /// Separate from the backlog phase so a new capture never replaces its
    /// preparation counter. Both paths contribute to the final run summary.
    private(set) var recentBackupStatus: String?
    private(set) var recentBackedUpMedia = MediaCounts()
    var recentBackedUpCount: Int { recentBackedUpMedia.total }
    private(set) var phaseMediaTotal = MediaCounts()
    private(set) var phaseMediaCompleted = MediaCounts()
    private(set) var libraryStatus: BackupLibraryStatus?
    @ObservationIgnored private var libraryStatusGeneration = 0
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
    /// wired by sessionstore to raise the failure banner. a finished run stays
    /// silent, the uploads show up in the timeline on their own. not called
    /// when the server was unreachable, since every launch and foreground
    /// retries and each retry would repeat the same banner.
    var onRunFailed: ((String) -> Void)?
    /// wired by the continued-processing task, which has to keep feeding the
    /// system progress ui or the scheduler expires it.
    var onContinuedProgress: (() -> Void)?

    var autoBackup: Bool {
        didSet {
            UserDefaults.standard.set(autoBackup, forKey: Self.autoBackupKey)
            scheduleRecovery()
            if autoBackup {
                Task { await self.enableAndStart() }
            } else {
                recentRescanRequested = false
                recentTask?.cancel()
                updateChangeObserver()
            }
        }
    }

    /// spending the data plan on automatic backups is opt in. a backup the
    /// user starts themselves ignores this and asks them instead.
    var backUpOnCellular: Bool {
        didSet {
            UserDefaults.standard.set(backUpOnCellular, forKey: Self.cellularBackupKey)
            if !automaticRecentUploadsPermitted { recentTask?.cancel() }
            if backUpOnCellular {
                startIfIdle()
            } else if !networkAllowsUploads, !isStopping, case .hashing = phase {
                networkInterruptedRun = true
                runTask?.cancel()
            }
        }
    }

    /// bounded PhotoKit resource streams used by the prepare phase. the value
    /// is captured when a pass begins, so changing it never reshapes a live
    /// task group. 32 matches the current official Immich iOS batch limit.
    var hashWorkers: Int {
        didSet {
            UserDefaults.standard.set(hashWorkers, forKey: Self.hashWorkersKey)
        }
    }

    var dateOrder: BackupDateOrder = .newestFirst {
        didSet { UserDefaults.standard.set(dateOrder.rawValue, forKey: Self.dateOrderKey) }
    }
    var mediaPriority: BackupMediaPriority = .together {
        didSet { UserDefaults.standard.set(mediaPriority.rawValue, forKey: Self.mediaPriorityKey) }
    }

    /// the only way out is metered. a personal hotspot counts, since it is
    /// someone else's data plan.
    private(set) var isOnCellular = false
    private var networkStatusKnown = false

    var isRunning: Bool {
        switch phase {
        case .scanning, .hashing, .checking, .uploading: true
        default: false
        }
    }

    /// auto backup is on and holding off only because of the connection.
    /// the screen says so, since the run itself just goes quiet.
    var isHeldForCellular: Bool {
        autoBackup && networkStatusKnown && !networkAllowsUploads
            && (libraryStatus.map { $0.pending > 0 } ?? true)
    }

    var canStartBackup: Bool {
        PhotoLibraryService.hasFullAccess && !isRunning
            && (libraryStatus.map { $0.pending > 0 } ?? true)
    }

    /// whether bytes may leave right now: the user asked for this run, or
    /// they opted in to cellular, or the connection is not theirs to pay for.
    private var networkAllowsUploads: Bool {
        cellularOverride || backUpOnCellular || !isOnCellular
    }

    /// the gate the pipeline reads: somebody asked for uploads, and the
    /// connection is one they are willing to spend.
    private var uploadsPermitted: Bool {
        runAllowsUploads && networkAllowsUploads
    }

    private let client: ImmichClient
    private let index: BackupIndex
    private var runTask: Task<Void, Never>?
    private var localChangedTask: Task<Void, Never>?
    /// One dedicated recent-asset worker, separate from the bounded backlog
    /// pool. Its automatic policy never borrows a manual cellular override.
    private var recentTask: Task<Void, Never>?
    private var recentRescanRequested = false
    private var recentQuotaReached = false
    private var recentAttempted: [String: DeviceAsset] = [:]
    private var activeBacklogCheckpoint: Date?
    private var activeBacklogIDs: Set<String> = []
    private var backlogUploadIDs: Set<String> = []
    /// whether the current or next run may upload. false makes the run a
    /// passive reconcile - scan, hash and bulk-check only - which rebuilds
    /// the index quietly and ends back at idle.
    private var runAllowsUploads = true
    /// the user started this run themselves, so it may spend the data plan
    /// whatever the cellular preference says. cleared when the run ends.
    private var cellularOverride = false
    private var manualBackupRequested = false
    private var rerunRequested = false
    /// Distinguishes a network-policy stop from an explicit user cancellation.
    private var networkInterruptedRun = false
    private var changeObserver: LibraryChangeObserver?
    private var networkWatcher: NetworkPathWatcher?
    private var isStopping = false
    private var isShutDown = false
    private var recoverAfterExpiration = false
    private var runLifetime = BackgroundUploader.RunLifetime()

    /// host|userId, stamped onto every background upload so a completion can
    /// never be applied to a different account's index.
    private var accountKey: String {
        "\(client.apiURL.host() ?? "")|\(userId ?? "")"
    }

    nonisolated static var scratchDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "backup")
    }

    init(client: ImmichClient) {
        self.client = client
        self.autoBackup = UserDefaults.standard.bool(forKey: Self.autoBackupKey)
        self.backUpOnCellular = UserDefaults.standard.bool(forKey: Self.cellularBackupKey)
        let storedHashWorkers = UserDefaults.standard.integer(forKey: Self.hashWorkersKey)
        self.hashWorkers = Self.hashWorkerOptions.contains(storedHashWorkers)
            ? storedHashWorkers
            : Self.defaultHashWorkers
        self.index = BackupIndex()
        self.dateOrder = BackupDateOrder(rawValue: UserDefaults.standard.string(forKey: Self.dateOrderKey) ?? "") ?? .newestFirst
        self.mediaPriority = BackupMediaPriority(rawValue: UserDefaults.standard.string(forKey: Self.mediaPriorityKey) ?? "") ?? .together
        // stale exports from a killed run are useless without their request.
        let scratch = Self.scratchDirectory
        Task.detached { try? FileManager.default.removeItem(at: scratch) }
        updateChangeObserver()
        networkWatcher = NetworkPathWatcher { [weak self] metered in
            self?.networkChanged(metered)
        }
    }

    /// called by sessionstore on logout. the manager must not outlive its client.
    func shutdown() {
        isShutDown = true
        BackupIntentStore.shared.set(false, account: accountKey)
        BackupProcessing.shared.schedule(needed: false)
        isStopping = true
        networkInterruptedRun = false
        rerunRequested = false
        activeBacklogCheckpoint = nil
        recentRescanRequested = false
        recentTask?.cancel()
        runTask?.cancel()
        runTask = nil
        let index = index
        Task { await index.flush() }
        localChangedTask?.cancel()
        localChangedTask = nil
        BackgroundUploader.shared.setOrphanHandler(nil)
        // transfers outlive the process, so signing out has to stop them
        // explicitly or they would keep filling a stranger's library.
        BackgroundUploader.shared.cancelAll()
        if let changeObserver {
            PHPhotoLibrary.shared().unregisterChangeObserver(changeObserver)
            self.changeObserver = nil
        }
        networkWatcher?.stop()
        networkWatcher = nil
    }

    // MARK: - triggers

    /// the user asked for this one, so it spends whatever connection is
    /// there. the screen warns them first when that is the data plan.
    func start() {
        manualBackupRequested = true
        cellularOverride = true
        beginRun(uploads: true)
    }

    /// Automatic preparation also waits for a permitted connection because
    /// hashing may download originals from iCloud.
    private func startAutomatically() {
        // Do not start an iCloud-backed hash pass before the path monitor has
        // identified the connection, or while the user's data plan is gated.
        guard networkStatusKnown, networkAllowsUploads else { return }
        if runTask == nil { networkInterruptedRun = false }
        else { recentAttempted = [:] }
        beginRun(uploads: (autoBackup || hasUnfinishedBackup) && networkAllowsUploads)
    }

    private func beginRun(uploads: Bool) {
        guard !isShutDown else { return }
        if runTask == nil {
            isStopping = false
            recoverAfterExpiration = false
            runLifetime = BackgroundUploader.RunLifetime()
        }
        if uploads, userId != nil, manualBackupRequested || hasUnfinishedBackup {
            guard saveUnfinishedBackup() else { return }
        } else {
            scheduleRecovery()
        }
        // a run is already going: raise its upload gate instead of dropping
        // the ask. a passive reconcile reads the flag again before uploading.
        if runTask != nil {
            if uploads { runAllowsUploads = true }
            requestRecentBackup()
            return
        }
        isStopping = false
        recentAttempted = [:]
        recentQuotaReached = false
        recentBackedUpMedia = MediaCounts()
        recentBackupStatus = nil
        runAllowsUploads = uploads
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
        manualBackupRequested = false
        recoverAfterExpiration = false
        BackupIntentStore.shared.set(false, account: accountKey)
        BackupProcessing.shared.schedule(needed: false)
        stopWork()
    }

    private func stopWork(cancelTransfers: Bool = true) {
        // stopping also withdraws any upload ask that raced this cancel.
        runAllowsUploads = false
        isStopping = true
        networkInterruptedRun = false
        rerunRequested = false
        recentRescanRequested = false
        // Mark the run before cancelling its workers: their cancellation
        // handlers must detach from system-owned uploads instead of stopping them.
        if !cancelTransfers { runLifetime.expire() }
        recentTask?.cancel()
        runTask?.cancel()
        if cancelTransfers { BackgroundUploader.shared.cancelAll() }
        let index = index
        Task { await index.flush() }
    }

    private var hasUnfinishedBackup: Bool {
        userId != nil && BackupIntentStore.shared.contains(accountKey)
    }

    private func saveUnfinishedBackup() -> Bool {
        guard BackupIntentStore.shared.set(true, account: accountKey) else {
            phase = .error("Could not save backup recovery state. Check available device storage and try again.")
            return false
        }
        scheduleRecovery()
        return true
    }

    func scheduleRecovery() {
        BackupProcessing.shared.schedule(needed: !isShutDown && (!isStopping || recoverAfterExpiration) && (autoBackup || hasUnfinishedBackup))
    }

    /// BGProcessing expiration is an execution budget, unlike the continued
    /// task's ambiguous expiration (which may be its user Cancel button).
    func pauseForBackgroundExpiration() {
        let pending = hasUnfinishedBackup
        recoverAfterExpiration = true
        stopWork(cancelTransfers: false)
        // Retain a retry without letting a network callback restart this run.
        BackupProcessing.shared.schedule(needed: !isShutDown && (autoBackup || pending))
    }

    func runScheduledBackup() async -> Bool {
        guard !isShutDown, PhotoLibraryService.hasFullAccess else { return false }
        if userId == nil {
            do { userId = try await client.currentUser().id }
            catch { return false }
        }
        // NetworkPathWatcher delivers asynchronously during a cold launch.
        for _ in 0..<20 where !networkStatusKnown {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled, networkStatusKnown,
              backUpOnCellular || !isOnCellular,
              autoBackup || hasUnfinishedBackup else { return false }
        await primeLocalState()
        startAutomatically()
        while let task = runTask { await task.value }
        guard !Task.isCancelled, !hasUnfinishedBackup, case .done(let result) = phase else { return false }
        return result.failed == 0
    }

    func flushPendingIndexChanges() async {
        await index.flush()
    }

    /// starts a full run when auto backup is on, and a passive reconcile
    /// otherwise, so assets already on the server are recognized - after a
    /// reinstall or an upload from another device - without sending anything.
    func startIfIdle() {
        guard PhotoLibraryService.hasFullAccess else { return }
        localChanged()
        if runTask != nil {
            recentAttempted = [:]
            requestRecentBackup()
            return
        }
        startAutomatically()
    }

    private func enableAndStart() async {
        guard await PhotoLibraryService.requestFullAccess() else {
            phase = .error("full photo library access is required for backup.")
            updateChangeObserver()
            return
        }
        updateChangeObserver()
        // turning the switch on is a vote for automatic backup, not for
        // spending the data plan, so the cellular rule still applies.
        startAutomatically()
    }

    /// the connection changed under us. the upload loop reads the rule live,
    /// so turning metered stops an automatic run from queueing anything more
    /// on its own; only the way back needs a nudge.
    private func networkChanged(_ metered: Bool) {
        networkStatusKnown = true
        isOnCellular = metered
        if !automaticRecentUploadsPermitted { recentTask?.cancel() }
        if !networkAllowsUploads, !isStopping, case .hashing = phase {
            // PhotoKit may be downloading originals, not merely reading local
            // bytes. Stop the active preparation pass when Wi-Fi is lost.
            networkInterruptedRun = true
            runTask?.cancel()
        }
        guard !isStopping, networkAllowsUploads, PhotoLibraryService.hasFullAccess else { return }
        // the queueing loop has already walked past whatever it skipped, so
        // a run that far along needs a fresh one to pick those up. anything
        // earlier just has its gate raised.
        if case .uploading = phase { rerunRequested = true }
        startAutomatically()
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
            requestRecentBackup()
        } else {
            startIfIdle()
        }
    }

    // MARK: - recent captures

    private var automaticRecentUploadsPermitted: Bool {
        autoBackup && networkStatusKnown && (backUpOnCellular || !isOnCellular)
            && !isStopping && !recentQuotaReached && PhotoLibraryService.hasFullAccess
    }

    private func requestRecentBackup() {
        guard runTask != nil, activeBacklogCheckpoint != nil,
              automaticRecentUploadsPermitted else { return }
        recentRescanRequested = true
        guard recentTask == nil else { return }
        recentTask = Task { await backUpRecentAssets() }
    }

    /// Re-scan on library events, not a timer. Yield to newly arrived captures
    /// after the current asset, and do not retry a failed revision in a loop.
    /// Backlog IDs stay assigned to their original worker for the whole run.
    private func backUpRecentAssets() async {
        defer {
            recentBackupStatus = recentBackedUpCount > 0
                ? "\(recentBackedUpMedia.text) backed up from recent captures" : nil
            recentTask = nil
            // Wi-Fi may return while the cancelled worker is still draining.
            // An explicit Cancel or disabled automatic backup cannot restart it.
            if recentRescanRequested { requestRecentBackup() }
        }
        repeat {
            recentRescanRequested = false
            guard !Task.isCancelled, automaticRecentUploadsPermitted,
                  let checkpoint = activeBacklogCheckpoint else { return }
            // Photos can send frequent changes while originals download.
            // Empty checks stay silent: inserting/removing a status row for
            // each scan makes both backup screens flash and shift their layout.
            // Publish status only when a candidate is actually being backed up.
            let scanned = await PhotoLibraryService.scan()
            let entries = await index.allEntries()
            let candidates = scanned.filter { asset in
                guard let created = asset.creationDate, created > checkpoint,
                      !activeBacklogIDs.contains(asset.localIdentifier),
                      recentAttempted[asset.localIdentifier] != asset else { return false }
                if let entry = entries[asset.localIdentifier],
                   entry.matches(modificationDate: asset.modificationDate),
                   entry.isBackedUp || entry.unsupported { return false }
                return true
            }
            for asset in candidates {
                guard !Task.isCancelled, automaticRecentUploadsPermitted,
                      activeBacklogCheckpoint != nil else { break }
                // The viewer may already own this asset. Its result goes to
                // the same index; a later scan can recover a failed upload.
                if case .uploading = uploadStates[asset.localIdentifier] { continue }
                recentAttempted[asset.localIdentifier] = asset
                await backUpRecentAsset(asset)
                if recentRescanRequested { break }
            }
            await index.flush()
        } while recentRescanRequested && !Task.isCancelled
    }

    private func backUpRecentAsset(_ asset: DeviceAsset) async {
        let localId = asset.localIdentifier
        uploadStates[localId] = .uploading(0)
        recentBackupStatus = "Backing up a new \(asset.isVideo && !asset.isLivePhoto ? "video" : "photo")… \(recentBackedUpMedia.text) saved"
        defer {
            if Task.isCancelled || !automaticRecentUploadsPermitted {
                recentAttempted[localId] = nil
            }
            if case .uploading = uploadStates[localId] { uploadStates[localId] = nil }
            localChanged()
        }
        do {
            try Task.checkCancellation()
            let current = await PhotoLibraryService.assetInfo(localIdentifier: localId)
            guard let current else { return }
            try Task.checkCancellation()
            let entry = await index.entry(for: localId)
            if entry == nil || entry?.matches(modificationDate: current.modificationDate) != true {
                let hashes = try await PhotoLibraryService.hash(
                    localIdentifier: localId, includeMotion: current.isLivePhoto
                )
                try Task.checkCancellation()
                await index.setHashed(
                    localId: localId, isLivePhoto: current.isLivePhoto,
                    primaryChecksum: hashes.primary, motionChecksum: hashes.motion,
                    modificationDate: current.modificationDate
                )
            }
            try Task.checkCancellation()
            guard automaticRecentUploadsPermitted else { return }
            let pending = try await checkPhase([current], updatesPhase: false)
            try Task.checkCancellation()
            guard automaticRecentUploadsPermitted else { return }
            if pending.isEmpty {
                if await index.entry(for: localId)?.isBackedUp == true { recentBackedUpMedia.add(current) }
                return
            }
            let outcome = await Self.uploadOne(
                asset: current, client: client, index: index,
                deviceId: DeviceID.current, scratch: Self.scratchDirectory,
                account: accountKey, lifetime: runLifetime
            ) { [weak self] id, fraction in
                Task { @MainActor [weak self] in self?.noteUploadProgress(id, fraction) }
            }
            switch outcome {
            case .uploaded:
                summary.uploadedMedia.add(asset)
                recentBackedUpMedia.add(current)
            case .duplicate:
                summary.duplicateMedia.add(asset)
                recentBackedUpMedia.add(current)
            case .failed(let reason):
                guard !Task.isCancelled else { return }
                summary.failedMedia.add(asset)
                if lastFailure == nil { lastFailure = reason }
                markUploadFailed(localId)
            case .skipped:
                if !Task.isCancelled { summary.skippedMedia.add(asset) }
            case .quota(let message):
                recentQuotaReached = true
                throw ImmichError.http(400, message)
            }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            summary.failedMedia.add(asset)
            if lastFailure == nil { lastFailure = error.localizedDescription }
            markUploadFailed(localId)
        }
    }

    private func finishRecentBackups() async {
        while let task = recentTask { await task.value }
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
        await refreshLibraryStatus()
        onLocalChange?()
    }

    /// Metadata only: safe even while cellular uploads are held. The Photos
    /// service reuses its scan until the library change token changes.
    func refreshLibraryStatus() async {
        libraryStatusGeneration += 1
        let generation = libraryStatusGeneration
        guard !isShutDown, PhotoLibraryService.hasFullAccess, let userId else {
            libraryStatus = nil
            return
        }
        guard await index.load(serverHost: client.apiURL.host() ?? "", userId: userId) else {
            libraryStatus = nil
            return
        }
        let assets = await PhotoLibraryService.scan()
        guard !isShutDown, !Task.isCancelled, PhotoLibraryService.hasFullAccess else { return }
        let status = await index.libraryStatus(for: assets)
        guard generation == libraryStatusGeneration, !isShutDown, PhotoLibraryService.hasFullAccess else { return }
        libraryStatus = status
    }

    /// the server repainted these assets, so their device twins are stale
    /// pixels. the pairing itself survives - deletes still cascade - but grids
    /// and the viewer go back to the server render for them.
    func noteRemoteEdits(_ remoteIds: Set<String>) {
        guard !remoteIds.isEmpty else { return }
        for id in remoteIds { localIdentifierByRemoteId[id] = nil }
        Task { [weak self] in
            guard let self, await self.index.markRemoteEdited(remoteIds) else { return }
            self.localIdentifierByRemoteId = await self.index.renderableRemoteToLocalMap()
        }
    }

    /// loads the index for the signed-in account so badges and the merged
    /// timeline are right from the first frame.
    func primeLocalState() async {
        guard let userId else { return }
        guard await index.load(serverHost: client.apiURL.host() ?? "", userId: userId) else { return }
        await refreshLocalSnapshots()
        updateChangeObserver()
        adoptBackgroundUploads()
        await BackgroundUploader.shared.replayReceipts()
    }

    // MARK: - background uploads

    /// transfers handed to the system finish whether or not this process is
    /// still around. anything that landed while it was not has to reach the
    /// index here, or the next run would send the same bytes again.
    private func adoptBackgroundUploads() {
        BackgroundUploader.shared.setOrphanHandler { [weak self] completion in
            guard let self else { return false }
            return await self.applyBackgroundUpload(completion)
        }
        BackgroundUploader.shared.sweepAbandonedBodies()
    }

    private func applyBackgroundUpload(_ completion: BackgroundUploader.Completion) async -> Bool {
        guard let userId, completion.ticket.account == accountKey, !isShutDown else { return false }
        guard await index.load(serverHost: client.apiURL.host() ?? "", userId: userId) else { return false }
        // Legacy tickets lack revision proof. The ordinary checksum check will
        // rediscover their uploads; never attach them blindly to current bytes.
        if let version = completion.ticket.version, version != 1 { return false }
        guard let source = completion.ticket.source else { return true }
        guard PhotoLibraryService.hasFullAccess else { return false }
        guard let current = await PhotoLibraryService.assetInfo(localIdentifier: completion.ticket.localId) else {
            return true
        }
        guard !isShutDown, completion.ticket.account == accountKey else { return false }
        guard current.modificationDate == source.modificationDate,
              current.isLivePhoto == source.isLivePhoto else { return true }
        let committed = await index.applyReceipt(completion)
        #if DEBUG
        BackupExpiryDebug.shared.record("orphan-index-applied success=\(committed)", localId: completion.ticket.localId)
        #endif
        if committed { localChanged() }
        return committed
    }

    /// every device asset paired with its backup status, newest first.
    func localTimelineAssets() async -> [LocalTimelineItem] {
        guard PhotoLibraryService.hasFullAccess, let userId else { return [] }
        // the library walk and the index decode are independent, and at
        // launch each is a few hundred milliseconds on a large library, so
        // they overlap instead of queueing.
        async let scanned = PhotoLibraryService.scan()
        guard await index.load(serverHost: client.apiURL.host() ?? "", userId: userId) else { return [] }
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
        case .idle, .scanning, .cancelled:
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
        uploadStates.reduce(0) { total, item in
            if backlogUploadIDs.contains(item.key), case .uploading(let fraction) = item.value {
                return total + fraction
            }
            return total
        }
    }

    // MARK: - pipeline

    private func run() async {
        let startedAt = Date()
        let dateOrder = dateOrder
        let mediaPriority = mediaPriority
        var uploadsAllowed = uploadsPermitted
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
            if hasUnfinishedBackup, !isStopping { runAllowsUploads = true }
            guard await index.load(serverHost: client.apiURL.host() ?? "", userId: user.id) else {
                throw SingleAssetBackupError.failed("Backup state is unavailable. Unlock the device and try again.")
            }
            if runAllowsUploads, !isStopping, manualBackupRequested || hasUnfinishedBackup,
               !saveUnfinishedBackup() {
                throw SingleAssetBackupError.failed("Could not save backup recovery state.")
            }

            adoptBackgroundUploads()
            await BackgroundUploader.shared.replayReceipts()
            try Task.checkCancellation()
            let checkpoint = await index.ensureBacklogCheckpoint(at: startedAt)
            let scanned = await PhotoLibraryService.scan()
            try Task.checkCancellation()
            await index.prune(keeping: Set(scanned.map(\.localIdentifier)))
            libraryStatus = await index.libraryStatus(for: scanned)
            // Assign the snapshot before starting the other worker. A manual
            // cellular run can own newer items already in its snapshot, but
            // future automatic captures never inherit that cellular override.
            let backlogCandidates = automaticRecentUploadsPermitted ? scanned.filter {
                ($0.creationDate ?? .distantPast) <= checkpoint
            } : scanned
            let backlog = mediaPriority.order(backlogCandidates, by: dateOrder)
            activeBacklogIDs = Set(backlog.map(\.localIdentifier))
            activeBacklogCheckpoint = checkpoint
            requestRecentBackup()

            try await hashPhase(backlog)
            let pending = try await checkPhase(backlog)
            localChanged()
            // read again so a backup asked for during scan, hash or check
            // upgrades this run instead of waiting for the next one, and so
            // a connection that turned metered meanwhile holds it back.
            uploadsAllowed = uploadsPermitted
            if uploadsAllowed {
                try await uploadPhase(pending)
            }

            await finishRecentBackups()
            activeBacklogCheckpoint = nil
            try Task.checkCancellation()
            if uploadsAllowed {
                await index.advanceBacklogCheckpoint(to: startedAt, completed: scanned)
                let entries = await index.allEntries()
                let complete = scanned.allSatisfy { asset in
                    guard let entry = entries[asset.localIdentifier],
                          entry.matches(modificationDate: asset.modificationDate) else { return false }
                    return entry.isBackedUp || entry.unsupported
                }
                if complete, await index.flush() {
                    BackupIntentStore.shared.set(false, account: accountKey)
                    manualBackupRequested = false
                }
            }
            await index.flush()
            await refreshLibraryStatus()
            if uploadsAllowed {
                phase = .done(summary)
            } else {
                // a passive reconcile ends where it began: no summary, no
                // notification, just fresh pairings for the merged timeline.
                phase = .idle
                chainFullRun = uploadsPermitted
            }
        } catch {
            activeBacklogCheckpoint = nil
            recentRescanRequested = false
            recentTask?.cancel()
            await finishRecentBackups()
            await index.flush()
            if error is CancellationError || Task.isCancelled {
                // a cancel surfaces as whatever the interrupted call threw,
                // not always as a cancellationerror.
                phase = .cancelled
                // A user cancellation drops any queued library-change rerun.
                // A network-policy stop restarts only if the connection became
                // permitted again while its in-flight PhotoKit work drained.
                rerunRequested = !isStopping && networkInterruptedRun && networkAllowsUploads
            } else if runAllowsUploads {
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
        if case .error(let message) = phase, reportsOutcome { onRunFailed?(message) }
        localChanged()
        activeBacklogIDs = []
        runTask = nil
        scheduleRecovery()
        if chainFullRun {
            // the upload ask arrived after the gate: run again, in full,
            // carrying whatever permission that ask brought with it.
            beginRun(uploads: true)
            return
        }
        // the next run is the app's idea rather than the user's, so it has
        // to earn the connection on its own again.
        cellularOverride = false
        networkInterruptedRun = false
        if rerunRequested {
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

    private nonisolated enum HashOutcome: Sendable {
        case hashed(DeviceAsset, primary: String, motion: String?)
        case failed(DeviceAsset, message: String)
        case cancelled
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
        try Task.checkCancellation()
        guard networkAllowsUploads else {
            if !isStopping { networkInterruptedRun = true }
            throw CancellationError()
        }
        downloadedOriginalsFromICloud = false
        phaseMediaTotal = MediaCounts(assets: toHash)
        phaseMediaCompleted = MediaCounts()
        phase = .hashing(done: 0, total: toHash.count)
        let workerLimit = min(max(1, min(hashWorkers, Self.hashWorkerOptions.max() ?? 32)), toHash.count)
        var cancelled = false
        let reportICloudDownload: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.downloadedOriginalsFromICloud = true
            }
        }
        await withTaskGroup(of: HashOutcome.self) { group in
            var next = 0
            var done = 0

            @MainActor func addNext() {
                guard next < toHash.count, !cancelled, !Task.isCancelled,
                      networkAllowsUploads else { return }
                let asset = toHash[next]
                next += 1
                group.addTask {
                    do {
                        let hashes = try await PhotoLibraryService.hash(
                            localIdentifier: asset.localIdentifier,
                            includeMotion: asset.isLivePhoto,
                            onICloudDownload: reportICloudDownload
                        )
                        return .hashed(asset, primary: hashes.primary, motion: hashes.motion)
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        return .failed(asset, message: error.localizedDescription)
                    }
                }
            }

            for _ in 0..<workerLimit { addNext() }
            while let outcome = await group.next() {
                if Task.isCancelled || !networkAllowsUploads {
                    cancelled = true
                    group.cancelAll()
                    continue
                }
                switch outcome {
                case .hashed(let asset, let primary, let motion):
                    phaseMediaCompleted.add(asset)
                    await index.setHashed(
                        localId: asset.localIdentifier,
                        isLivePhoto: asset.isLivePhoto,
                        primaryChecksum: primary,
                        motionChecksum: motion,
                        modificationDate: asset.modificationDate
                    )
                case .failed(let asset, let message):
                    backupLog.error("hash failed for \(asset.localIdentifier): \(message)")
                    if lastFailure == nil { lastFailure = message }
                    summary.failedMedia.add(asset)
                    phaseMediaCompleted.add(asset)
                case .cancelled:
                    cancelled = true
                    group.cancelAll()
                    continue
                }
                done += 1
                phase = .hashing(done: done, total: toHash.count)
                addNext()
            }
        }
        if !networkAllowsUploads, !isStopping { networkInterruptedRun = true }
        if cancelled { throw CancellationError() }
        try Task.checkCancellation()
        guard networkAllowsUploads else {
            if !isStopping { networkInterruptedRun = true }
            throw CancellationError()
        }
    }

    /// asks the server about every hashed component we cannot prove yet, then
    /// returns the assets that still need uploads.
    private func checkPhase(_ scanned: [DeviceAsset], updatesPhase: Bool = true) async throws -> [DeviceAsset] {
        if updatesPhase { phase = .checking }
        var pending: [DeviceAsset] = []
        var items: [BulkUploadCheckItem] = []
        var entries = await index.allEntries()
        for asset in scanned {
            guard let entry = entries[asset.localIdentifier] else { continue }
            if entry.unsupported {
                summary.unsupportedMedia.add(asset)
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

        try Task.checkCancellation()
        let results = try await Self.bulkUploadCheck(items, client: client)
        for result in results {
            try Task.checkCancellation()
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

        var uploadQueue: [DeviceAsset] = []
        // re-read once: the bulk checks above changed what is proven.
        entries = await index.allEntries()
        for asset in pending {
            guard let entry = entries[asset.localIdentifier] else { continue }
            if entry.unsupported {
                summary.unsupportedMedia.add(asset)
            } else if entry.isBackedUp {
                summary.duplicateMedia.add(asset)
            } else {
                uploadQueue.append(asset)
            }
        }
        return uploadQueue
    }

    @concurrent
    private static func bulkUploadCheck(
        _ items: [BulkUploadCheckItem],
        client: ImmichClient
    ) async throws -> [BulkUploadCheckResult] {
        let batches = items.chunks(of: checkBatchSize)
        guard !batches.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: [BulkUploadCheckResult].self) { group in
            let initialCount = min(verificationWorkers, batches.count)
            for batch in batches.prefix(initialCount) {
                group.addTask { try await client.bulkUploadCheck(batch) }
            }
            var next = initialCount
            var combined: [BulkUploadCheckResult] = []
            combined.reserveCapacity(items.count)
            while let results = try await group.next() {
                combined.append(contentsOf: results)
                if next < batches.count {
                    let batch = batches[next]
                    next += 1
                    group.addTask { try await client.bulkUploadCheck(batch) }
                }
            }
            return combined
        }
    }

    private func uploadPhase(_ queue: [DeviceAsset]) async throws {
        guard !queue.isEmpty else { return }
        phaseMediaTotal = MediaCounts(assets: queue)
        phaseMediaCompleted = MediaCounts()
        phase = .uploading(done: 0, total: queue.count)
        backlogUploadIDs = Set(queue.map(\.localIdentifier))
        defer { backlogUploadIDs = [] }
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

        await withTaskGroup(of: (DeviceAsset, UploadOutcome).self) { group in
            var next = 0
            var done = 0
            @MainActor func addNext() {
                // once cancelled, queueing the rest would only race the counter
                // to the end as each new transfer dies on arrival. the network
                // rule is read here too, so walking out of wifi mid-run stops
                // the queue rather than emptying the data plan behind the user.
                guard next < queue.count, quotaMessage == nil, !Task.isCancelled,
                      networkAllowsUploads
                else { return }
                let asset = queue[next]
                next += 1
                uploadStates[asset.localIdentifier] = .uploading(0)
                let lifetime = runLifetime
                group.addTask {
                    let outcome = await Self.uploadOne(
                        asset: asset, client: client, index: index,
                        deviceId: deviceId, scratch: scratch, account: account,
                        lifetime: lifetime,
                        onProgress: progress
                    )
                    return (asset, outcome)
                }
            }
            for _ in 0..<Self.uploadWorkers { addNext() }
            while let (asset, outcome) = await group.next() {
                let localId = asset.localIdentifier
                done += 1
                phaseMediaCompleted.add(asset)
                switch outcome {
                case .uploaded:
                    summary.uploadedMedia.add(asset)
                    uploadStates[localId] = nil
                case .duplicate:
                    summary.duplicateMedia.add(asset)
                    uploadStates[localId] = nil
                case .failed(let reason):
                    if lastFailure == nil { lastFailure = reason }
                    summary.failedMedia.add(asset)
                    markUploadFailed(localId)
                case .skipped:
                    summary.skippedMedia.add(asset)
                    uploadStates[localId] = nil
                case .quota(let message):
                    // nothing else can succeed once the account is full.
                    quotaMessage = message
                    uploadStates[localId] = nil
                    group.cancelAll()
                }
                localChanged()
                // the in-flight leftovers of a cancelled run are not progress.
                if !Task.isCancelled {
                    phase = .uploading(done: done, total: queue.count)
                }
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
        lifetime: BackgroundUploader.RunLifetime? = nil,
        onProgress: @escaping @Sendable (String, Double) -> Void
    ) async -> UploadOutcome {
        // everything up to the hand-off, the export and the request body, has
        // to reach the system before the app is suspended. the lease keeps a
        // backgrounded app running that long, and the uploader lets go of it
        // once the transfer is the system's.
        do {
            try await BackgroundUploader.shared.waitForExisting(account: account, localId: asset.localIdentifier)
        } catch { return .skipped }
        var lease = await ProcessLease.take("backup export")
        defer { lease.release() }
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
                ), account: account, source: entry, lease: lease, lifetime: lifetime) { fraction in
                    onProgress(current.localIdentifier, fraction)
                }
                // recorded immediately so a failed still upload resumes here.
                _ = await index.applyReceipt(.init(ticket: .init(account: account, localId: current.localIdentifier, isMotion: true, bodyPath: "", source: entry), remoteId: result.id))
                motionRemoteId = result.id
                if !result.isDuplicate { uploadedSomething = true }
                // the still is exported on whatever wake delivered the motion.
                lease = await ProcessLease.take("backup export")
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
                ), account: account, source: entry, lease: lease, lifetime: lifetime) { fraction in
                    onProgress(current.localIdentifier, fraction)
                }
                _ = await index.applyReceipt(.init(ticket: .init(account: account, localId: current.localIdentifier, isMotion: false, bodyPath: "", source: entry), remoteId: result.id))
                if !result.isDuplicate { uploadedSomething = true }
            }
            return uploadedSomething ? .uploaded : .duplicate
        } catch is CancellationError {
            return .skipped
        } catch let ImmichError.http(_, message) where message.lowercased().contains("quota") {
            return .quota(message)
        } catch {
            // a cancelled transfer comes back as a url error, not a cancellationerror.
            if Task.isCancelled { return .skipped }
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
        guard await index.load(serverHost: client.apiURL.host() ?? "", userId: user.id) else {
            throw SingleAssetBackupError.failed("Backup state is unavailable. Unlock the device and try again.")
        }
        adoptBackgroundUploads()
        await BackgroundUploader.shared.replayReceipts()

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

        await index.flush()
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
        guard await index.load(serverHost: client.apiURL.host() ?? "", userId: user.id) else {
            throw SingleAssetBackupError.failed("Backup state is unavailable. Unlock the device and try again.")
        }
        adoptBackgroundUploads()
        await BackgroundUploader.shared.replayReceipts()

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
                guard next < queue.count, quotaMessage == nil, !Task.isCancelled else { return }
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
        await index.flush()
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
        guard await index.load(serverHost: client.apiURL.host() ?? "", userId: userId) else { return nil }
        guard await PhotoLibraryService.assetExists(localIdentifier: localIdentifier) else { return nil }
        return await index.entry(for: localIdentifier)?.primaryRemoteId
    }

    /// resolves a remote asset to a device asset when the index proves the
    /// pairing and the phasset still exists. never prompts for access.
    func localIdentifier(forRemote remoteId: String) async -> String? {
        guard PhotoLibraryService.hasFullAccess, let userId else { return nil }
        guard await index.load(serverHost: client.apiURL.host() ?? "", userId: userId) else { return nil }
        guard let localId = await index.localId(forRemote: remoteId) else { return nil }
        return await PhotoLibraryService.assetExists(localIdentifier: localId) ? localId : nil
    }

    func noteLocalDeletion(_ localIds: [String]) {
        Task {
            await index.remove(ids: localIds)
            await index.flush()
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
        guard await index.load(serverHost: client.apiURL.host() ?? "", userId: user.id) else {
            throw SingleAssetBackupError.failed("Backup state is unavailable. Unlock the device and try again.")
        }

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
            await index.flush()
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
        guard await index.load(serverHost: client.apiURL.host() ?? "", userId: user.id) else {
            throw SingleAssetBackupError.failed("Backup state is unavailable. Unlock the device and try again.")
        }

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
        let results = try await Self.bulkUploadCheck(items, client: client)
        for result in results {
            try Task.checkCancellation()
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

        var livePhotos: [(localId: String, remoteId: String)] = []
        for asset in candidates where !rejected.contains(asset.localIdentifier) {
            if asset.isLivePhoto {
                // checksum presence alone does not prove the server links the
                // motion video; an unlinked still would silently lose it.
                guard let remoteId = entries[asset.localIdentifier]?.primaryRemoteId else { continue }
                livePhotos.append((asset.localIdentifier, remoteId))
            } else {
                verified.insert(asset.localIdentifier)
            }
        }
        verified.formUnion(await Self.linkedLivePhotos(livePhotos, client: client))
        try Task.checkCancellation()
        await index.flush()

        return CleanupReport(
            eligible: candidates.map(\.localIdentifier).filter { verified.contains($0) },
            eligibleMedia: MediaCounts(assets: candidates.filter { verified.contains($0.localIdentifier) }),
            keptMedia: MediaCounts(assets: scanned.filter { !verified.contains($0.localIdentifier) })
        )
    }

    /// deletes the given device assets in one batch - exactly one system
    /// confirmation dialog. throws userCancelled when the user declines.
    func performCleanup(ids: [String]) async throws -> Int {
        try await PhotoLibraryService.delete(localIdentifiers: ids)
        await index.remove(ids: ids)
        await index.flush()
        localChanged()
        return ids.count
    }

    @concurrent
    private static func linkedLivePhotos(
        _ photos: [(localId: String, remoteId: String)],
        client: ImmichClient
    ) async -> Set<String> {
        guard !photos.isEmpty else { return [] }
        return await withTaskGroup(of: (String, Bool).self) { group in
            let initialCount = min(verificationWorkers, photos.count)
            for photo in photos.prefix(initialCount) {
                group.addTask {
                    let detail = try? await client.assetDetail(id: photo.remoteId)
                    return (photo.localId, detail?.livePhotoVideoId != nil)
                }
            }
            var next = initialCount
            var linked: Set<String> = []
            while let (localId, isLinked) = await group.next() {
                if isLinked { linked.insert(localId) }
                if next < photos.count, !Task.isCancelled {
                    let photo = photos[next]
                    next += 1
                    group.addTask {
                        let detail = try? await client.assetDetail(id: photo.remoteId)
                        return (photo.localId, detail?.livePhotoVideoId != nil)
                    }
                }
            }
            return linked
        }
    }
}

// MARK: - continued processing

extension BackupManager: ContinuedWorkload {
    var continuedTitle: String {
        switch phase {
        // a run with nothing to send is not an achievement to announce.
        case .scanning, .hashing, .checking: "Indexing library"
        case .done where libraryStatus?.isUpToDate == true && summary.uploaded == 0 && summary.failed == 0:
            "Up to date"
        case .done where (libraryStatus?.pending ?? 0) > 0 || (libraryStatus?.unsupported ?? 0) > 0 || summary.failed > 0:
            "Backup incomplete"
        case .done: "Backup complete"
        case .error: "Backup stopped"
        case .cancelled: "Backup cancelled"
        default: "Backing up"
        }
    }

    var continuedSubtitle: String {
        switch phase {
        case .idle, .scanning: "Scanning library..."
        case .hashing: "Indexing \(phaseMediaCompleted.progressText(of: phaseMediaTotal))"
        case .checking: "Checking with your server..."
        case .uploading: "Uploading \(phaseMediaCompleted.progressText(of: phaseMediaTotal))"
        case .done(let summary):
            libraryStatus?.completionText(summary) ?? "Backup check complete"
        case .error(let message): message
        case .cancelled where summary.uploaded > 0: "\(summary.uploadedMedia.text) uploaded before stopping"
        case .cancelled: "Nothing was sent"
        }
    }

    var continuedProgress: ContinuedProgress? {
        // a cancelled run leaves the system bar where it stopped instead of
        // snapping it empty or full on the way out.
        if case .cancelled = phase { return nil }
        return ContinuedProgress(fraction: progressFraction)
    }

    var continuedFailed: Bool {
        if case .error = phase { return true }
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
