import SwiftUI

struct BackupScreen: View {
    @Environment(SessionStore.self) private var session

    @State private var cleanup: CleanupState = .idle
    @State private var confirmCleanup = false
    @State private var confirmBackupConditions = false
    @State private var reportsNextBackupFailure = false
    @State private var activeBackupPresented = false

    nonisolated private enum CleanupState: Equatable {
        case idle
        case verifying
        case ready(CleanupReport)
        case deleting
        case finished(deleted: MediaCounts, kept: MediaCounts)
        case failed(String)
    }

    var body: some View {
        List {
            if let backup = session.backup {
                autoSection(backup)
                selectionSection(backup)
                batterySection(backup)
                statusSection(backup)
                advancedSection(backup)
                cleanupSection(backup)
            }
        }
        .keepsBackupScreenAwake(while: session.backup?.isRunning == true)
        .task { await session.backup?.refreshLibraryStatus() }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $activeBackupPresented) {
            if let backup = session.backup {
                ActiveBackupScreen(backup: backup)
            }
        }
        .onChange(of: session.backup?.phase) { _, phase in
            guard reportsNextBackupFailure, let phase else { return }
            switch phase {
            case .error(let message):
                reportsNextBackupFailure = false
                ErrorToastCenter.shared.show("Couldn’t complete the backup. \(message)")
            case .done(let summary):
                reportsNextBackupFailure = false
                if summary.failed > 0 {
                    let detail = session.backup?.lastFailure ?? "Some photos or videos were not uploaded."
                    ErrorToastCenter.shared.show("Some photos or videos couldn’t be backed up. \(detail)")
                }
            case .cancelled:
                // the ask died with the run, or the next automatic one
                // would toast for a failure nobody started.
                reportsNextBackupFailure = false
            default:
                break
            }
        }
    }

    // MARK: - automatic backup

    private func autoSection(_ backup: BackupManager) -> some View {
        return Section {
            Toggle(isOn: Binding(
                get: { backup.autoBackup },
                set: { value in
                    backup.autoBackup = value
                    if value { reportsNextBackupFailure = true }
                }
            )) {
                Label("Back Up Automatically", systemImage: "arrow.triangle.2.circlepath.icloud")
            }
            .accessibilityIdentifier("backup-auto-toggle")

            Toggle(isOn: Binding(
                get: { backup.backUpOnCellular },
                set: { backup.backUpOnCellular = $0 }
            )) {
                Label("Use Cellular Data", systemImage: "antenna.radiowaves.left.and.right")
            }
            .accessibilityIdentifier("backup-cellular-toggle")
        } footer: {
            Text("Imora first indexes your library to identify photos and videos already on your server, then uploads what’s missing. New captures get priority during the initial backup.\n\nWhen cellular data is off, automatic indexing and uploads wait for Wi-Fi. Back Up Now lets you approve a backup over cellular. Background work continues when iOS allows; force-quitting pauses it until you reopen Imora.")
        }
    }

    private func selectionSection(_ backup: BackupManager) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { !backup.excludeScreenshots },
                set: { backup.excludeScreenshots = !$0 }
            )) {
                Label("Include Screenshots", systemImage: "camera.viewfinder")
            }
            .accessibilityIdentifier("backup-include-screenshots-toggle")
        } header: {
            Text("Include in Backup")
        } footer: {
            Text("Include screenshots in automatic backup and Back Up Now. When off, screenshots stay in your gallery and can still be selected for manual backup. Existing server copies are kept. Transfers already in progress may finish.")
        }
    }

    private func batterySection(_ backup: BackupManager) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { backup.pauseOnLowBattery },
                set: { backup.pauseOnLowBattery = $0 }
            )) {
                Label("Pause on Low Battery", systemImage: "battery.25percent")
            }
            .accessibilityIdentifier("backup-low-battery-toggle")
            if backup.pauseOnLowBattery {
                Stepper(value: Binding(
                    get: { backup.batteryThreshold },
                    set: { backup.batteryThreshold = $0 }
                ), in: 1...50) {
                    Text("Pause at \(backup.batteryThreshold)% or Less")
                }
                .accessibilityIdentifier("backup-battery-threshold")
            }
        } header: {
            Text("Battery")
        } footer: {
            Text("Indexing and uploads pause at this battery level, including while charging. Sync This Time allows backup until the battery rises above the threshold. The cellular override ends when you connect to Wi-Fi. Transfers already handed to iOS may finish while backup is paused.")
        }
    }

    private func advancedSection(_ backup: BackupManager) -> some View {
        Section {
            Picker("Files Indexed at Once", selection: Binding(
                get: { backup.hashWorkers },
                set: { backup.hashWorkers = $0 }
            )) {
                ForEach(BackupManager.hashWorkerOptions, id: \.self) { workers in
                    Text("\(workers)").tag(workers)
                }
            }
            .accessibilityIdentifier("backup-hash-workers")

            Picker("Backup Order", selection: Binding(
                get: { backup.dateOrder }, set: { backup.dateOrder = $0 }
            )) {
                ForEach(BackupDateOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .accessibilityIdentifier("backup-date-order")

            Picker("Media Priority", selection: Binding(
                get: { backup.mediaPriority }, set: { backup.mediaPriority = $0 }
            )) {
                ForEach(BackupMediaPriority.allCases) { priority in
                    Text(priority.title).tag(priority)
                }
            }
            .accessibilityIdentifier("backup-media-priority")
        } header: {
            Text("Advanced")
        } footer: {
            Text("More indexing workers may be faster but use more memory, battery, and iCloud bandwidth. Ordering controls which photos and videos are indexed and queued first. Your backup exclusions still apply, and new captures keep priority. Changes apply to the next pass.")
        }
    }

    // MARK: - status

    @ViewBuilder
    private func statusSection(_ backup: BackupManager) -> some View {
        Section("Status") {
            if PhotoAccess.shared.canAsk {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Full photo library access is required for backup.")
                        .font(.callout)
                    Button("Allow Access") {
                        requestAccess()
                    }
                    .font(.callout.weight(.semibold))
                    .accessibilityIdentifier("backup-allow-access")
                }
                .padding(.vertical, 2)
            } else if PhotoAccess.shared.isBlocked {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Full photo library access is required for backup.")
                        .font(.callout)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Open Settings", destination: url)
                            .font(.callout.weight(.semibold))
                    }
                }
                .padding(.vertical, 2)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(statusText(backup))
                    .font(.callout)
                    .accessibilityIdentifier("backup-status")
                if let status = backup.libraryStatus {
                    Text(status.countText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("backup-library-count")
                    if status.excluded > 0 {
                        Text("\(status.excluded) screenshot\(status.excluded == 1 ? "" : "s") excluded")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("backup-excluded-count")
                    }
                }
                if case .hashing = backup.phase {
                    Text("Indexing your files to identify what’s already on your server. Missing photos and videos upload after indexing and matching; new captures can back up while the older library is indexed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let fraction = progressFraction(backup.phase) {
                    ProgressView(value: fraction)
                        .tint(.indigo)
                        .accessibilityIdentifier("backup-progress")
                }
            }
            .padding(.vertical, 2)

            if case .hashing = backup.phase, backup.downloadedOriginalsFromICloud {
                Label(
                    "Some originals are downloading from iCloud, so indexing may take longer.",
                    systemImage: "icloud.and.arrow.down"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("backup-icloud-download")
            }

            if let status = backup.recentBackupStatus {
                Label(status, systemImage: "sparkles")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("backup-recent-status")
            }

            if backup.isRunning {
                Button {
                    activeBackupPresented = true
                } label: {
                    Label("Active Mode", systemImage: "moon.stars")
                }
                .accessibilityIdentifier("backup-keep-awake")

                Text("This page keeps your screen awake while Imora indexes and backs up your library. Auto-Lock resumes when backup finishes or you leave this page. Active Mode offers a darker screen for longer backups.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Cancel", role: .destructive) {
                    backup.cancel()
                }
                .accessibilityIdentifier("backup-cancel")
            } else {
                let canStart = backup.canStartBackup && cleanup != .verifying && cleanup != .deleting
                Button {
                    if backup.manualBackupNeedsApproval {
                        confirmBackupConditions = true
                    } else {
                        startBackup(backup)
                    }
                } label: {
                    Label("Back Up Now", systemImage: "icloud.and.arrow.up")
                        .foregroundStyle(canStart ? Color.accentColor : Color.secondary)
                }
                .disabled(!canStart)
                .accessibilityIdentifier("backup-start")
                // ios 26 morphs the dialog out of its source control, so it
                // sits on the row instead of the section, where it would
                // float detached.
                .confirmationDialog(
                    "Back up now?",
                    isPresented: $confirmBackupConditions,
                    titleVisibility: .visible
                ) {
                    Button("Back Up Now") {
                        startBackup(backup)
                    }
                    .accessibilityIdentifier("backup-cellular-confirm")
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(backup.manualBackupApprovalMessage)
                }
            }
        }
    }

    private func requestAccess() {
        Task {
            guard await PhotoLibraryService.requestFullAccess() else { return }
            await session.adoptPhotoAccess()
        }
    }

    /// hands the run to the scheduler when it will take it, so the progress
    /// indicator survives leaving the app; otherwise backs up in app as before.
    private func startBackup(_ backup: BackupManager) {
        reportsNextBackupFailure = true
        Task {
            let accepted = await ContinuedProcessing.backup.submit(
                title: "Backing up",
                subtitle: "Indexing your library…"
            )
            if !accepted { backup.start() }
        }
    }

    private func statusText(_ backup: BackupManager) -> String {
        // the run itself just goes quiet on a metered connection, so the
        // reason has to be said out loud or nothing explains the silence.
        if let message = backup.syncHoldMessage {
            return "Not currently syncing. " + message
        }
        return switch backup.phase {
        case .idle:
            if let status = backup.libraryStatus {
                status.isUpToDate ? BackupLibraryStatus.upToDateText
                    : status.pending == 0 ? "Some photos or videos use an unsupported format." : "Ready to index and back up."
            } else {
                "Checking backup status…"
            }
        case .scanning: "Scanning library..."
        case .hashing: backup.continuedSubtitle
        case .checking: "Matching indexed files with your server…"
        case .uploading: backup.continuedSubtitle
        case .done(let summary): doneText(summary)
        case .error(let message): "Error: \(message)"
        case .cancelled: "Backup cancelled."
        }
    }

    private func doneText(_ summary: BackupSummary) -> String {
        var text = session.backup?.libraryStatus?.completionText(summary) ?? "Backup check complete."
        if summary.failed > 0, let failure = session.backup?.lastFailure {
            text += " (\(failure))"
        }
        return text
    }

    private func progressFraction(_ phase: BackupPhase) -> Double? {
        switch phase {
        case .hashing(let done, let total), .uploading(let done, let total):
            total > 0 ? Double(done) / Double(total) : nil
        default:
            nil
        }
    }

    // MARK: - cleanup

    @ViewBuilder
    private func cleanupSection(_ backup: BackupManager) -> some View {
        Section {
            switch cleanup {
            case .verifying:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Verifying with server...")
                        .foregroundStyle(.secondary)
                }
            case .deleting:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Deleting...")
                        .foregroundStyle(.secondary)
                }
            default:
                Button(role: .destructive) {
                    verifyCleanup(backup)
                } label: {
                    Label("Clean Up Device", systemImage: "trash.slash")
                }
                .disabled(backup.isRunning)
                .accessibilityIdentifier("backup-cleanup")
                // ios 26 morphs the dialog out of its source control, so it sits
                // on the row - on the section it floats detached.
                .confirmationDialog(
                    confirmTitle,
                    isPresented: $confirmCleanup,
                    titleVisibility: .visible
                ) {
                    if case .ready(let report) = cleanup {
                        Button("Delete \(report.eligibleMedia.text)", role: .destructive) {
                            performCleanup(backup, report: report)
                        }
                        .accessibilityIdentifier("backup-cleanup-confirm")
                        Button("Cancel", role: .cancel) {
                            cleanup = .idle
                        }
                    }
                }
            }

            if let summary = cleanupSummary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("backup-cleanup-summary")
            }
        } header: {
            Text("Device Storage")
        } footer: {
            Text("Removes device copies of photos and videos already backed up to your server. Anything not verified as backed up stays on this device.")
        }
    }

    private var confirmTitle: String {
        if case .ready(let report) = cleanup {
            return "Delete \(report.eligibleMedia.text) from this device? These are already backed up."
        }
        return ""
    }

    private var cleanupSummary: String? {
        switch cleanup {
        case .finished(let deleted, let kept):
            "Deleted \(deleted.text). Kept \(kept.text) on this device because their backups could not be verified."
        case .failed(let message):
            "Cleanup failed: \(message)"
        default:
            nil
        }
    }

    private func verifyCleanup(_ backup: BackupManager) {
        cleanup = .verifying
        Task {
            do {
                let report = try await backup.cleanUpCandidates()
                if report.eligible.isEmpty {
                    cleanup = .finished(deleted: MediaCounts(), kept: report.keptMedia)
                } else {
                    cleanup = .ready(report)
                    confirmCleanup = true
                }
            } catch {
                cleanup = .idle
                ErrorToastCenter.shared.show("Couldn’t verify cleanup candidates", error: error)
            }
        }
    }

    private func performCleanup(_ backup: BackupManager, report: CleanupReport) {
        cleanup = .deleting
        Task {
            do {
                _ = try await backup.performCleanup(ids: report.eligible)
                cleanup = .finished(deleted: report.eligibleMedia, kept: report.keptMedia)
            } catch {
                // declining the system dialog is a normal way out, not a failure.
                if PhotoLibraryService.isUserCancelled(error) {
                    cleanup = .idle
                } else {
                    cleanup = .failed(error.localizedDescription)
                }
            }
        }
    }
}
