import SwiftUI

struct BackupScreen: View {
    @Environment(SessionStore.self) private var session

    @State private var cleanup: CleanupState = .idle
    @State private var confirmCleanup = false
    @State private var reportsNextBackupFailure = false

    nonisolated private enum CleanupState: Equatable {
        case idle
        case verifying
        case ready(CleanupReport)
        case deleting
        case finished(deleted: Int, kept: Int)
        case failed(String)
    }

    var body: some View {
        List {
            if let backup = session.backup {
                autoSection(backup)
                statusSection(backup)
                cleanupSection(backup)
            }
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: session.backup?.phase) { _, phase in
            guard reportsNextBackupFailure, let phase else { return }
            switch phase {
            case .error(let message):
                reportsNextBackupFailure = false
                ErrorToastCenter.shared.show("Couldn’t complete the backup. \(message)")
            case .done(let summary):
                reportsNextBackupFailure = false
                if summary.failed > 0 {
                    let detail = session.backup?.lastFailure ?? "Some items were not uploaded."
                    ErrorToastCenter.shared.show("Some photos couldn’t be backed up. \(detail)")
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
        } footer: {
            Text("Photos and videos upload to your server while the app is open, and new uploads appear in the timeline automatically. A backup you start yourself keeps running for a while after you leave, with progress on the Lock Screen.")
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
                if let fraction = progressFraction(backup.phase) {
                    ProgressView(value: fraction)
                        .tint(.indigo)
                        .accessibilityIdentifier("backup-progress")
                }
            }
            .padding(.vertical, 2)

            if backup.isRunning {
                Button("Cancel", role: .destructive) {
                    backup.cancel()
                }
                .accessibilityIdentifier("backup-cancel")
            } else {
                Button {
                    startBackup(backup)
                } label: {
                    Label("Back Up Now", systemImage: "icloud.and.arrow.up")
                }
                .disabled(cleanup == .verifying || cleanup == .deleting)
                .accessibilityIdentifier("backup-start")
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
                subtitle: "Preparing..."
            )
            if !accepted { backup.start() }
        }
    }

    private func statusText(_ backup: BackupManager) -> String {
        switch backup.phase {
        case .idle: "Waiting to back up."
        case .scanning: "Scanning library..."
        case .hashing(let done, let total): "Preparing \(done) of \(total)"
        case .checking: "Checking with server..."
        case .uploading(let done, let total): "Uploading \(done) of \(total)"
        case .done(let summary): doneText(summary)
        case .error(let message): "Error: \(message)"
        case .cancelled: "Backup cancelled."
        }
    }

    private func doneText(_ summary: BackupSummary) -> String {
        var parts = ["\(summary.uploaded) uploaded", "\(summary.duplicates) already backed up"]
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        if summary.skipped > 0 { parts.append("\(summary.skipped) skipped") }
        if summary.unsupported > 0 { parts.append("\(summary.unsupported) unsupported") }
        var text = "Done - " + parts.joined(separator: ", ")
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
                        Button("Delete \(report.eligible.count) Items", role: .destructive) {
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
            Text("Removes device copies of photos already backed up to your server. Photos not yet backed up stay on this device.")
        }
    }

    private var confirmTitle: String {
        if case .ready(let report) = cleanup {
            return "Delete \(report.eligible.count) backed-up items from this device?"
        }
        return ""
    }

    private var cleanupSummary: String? {
        switch cleanup {
        case .finished(let deleted, let kept):
            "Deleted \(deleted) items - \(kept) local-only items kept."
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
                    cleanup = .finished(deleted: 0, kept: report.keptLocalOnly)
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
                let deleted = try await backup.performCleanup(ids: report.eligible)
                cleanup = .finished(deleted: deleted, kept: report.keptLocalOnly)
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
