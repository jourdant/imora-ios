import SwiftUI

/// A foreground lane for a large initial backup. Keeping this deliberately
/// explicit mirrors the contract of Photos-style active upload modes: the app
/// can prevent idle sleep while this screen is visible, but a manual lock or
/// leaving the app still returns control to iOS.
struct ActiveBackupScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let backup: BackupManager

    @State private var idleTimerOwner = UUID()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geometry in
                ScrollView {
                    content
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height)
                }
            }
        }
        .foregroundStyle(.white)
        .statusBarHidden()
        .onAppear {
            guard backup.isRunning else {
                finishActiveMode()
                return
            }
            if scenePhase == .active { acquireIdleTimer() }
        }
        .onDisappear {
            releaseIdleTimer()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if backup.isRunning {
                    acquireIdleTimer()
                } else {
                    finishActiveMode()
                }
            } else {
                releaseIdleTimer()
            }
        }
        .onChange(of: backup.isRunning) { _, running in
            if !running { finishActiveMode() }
        }
    }

    private var content: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "icloud.and.arrow.up")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.white.opacity(0.7))

            VStack(spacing: 8) {
                Text("Active Mode")
                    .font(.title2.weight(.semibold))
                Text(backup.continuedSubtitle)
                    .multilineTextAlignment(.center)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
            }

            if let status = backup.libraryStatus {
                Text(status.countText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("active-backup-library-count")
            }

            ProgressView(value: backup.progressFraction)
                .tint(.indigo)
                .frame(maxWidth: 280)
                .accessibilityLabel("Backup progress")
                .accessibilityValue(backup.continuedSubtitle)
                .accessibilityIdentifier("active-backup-progress")

            if case .hashing = backup.phase, backup.downloadedOriginalsFromICloud {
                Label(
                    "Downloading some originals from iCloud",
                    systemImage: "icloud.and.arrow.down"
                )
                .font(.callout)
                .foregroundStyle(.white.opacity(0.65))
            }

            if let status = backup.recentBackupStatus {
                Label(status, systemImage: "sparkles")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.65))
                    .accessibilityIdentifier("active-backup-recent-status")
            }

            VStack(spacing: 10) {
                Text("Especially helpful for your first backup")
                    .font(.callout.weight(.semibold))
                Text("This screen prevents automatic locking and keeps Imora active, giving it more time to index your library and upload missing photos and videos.")
                Text("Indexing checks your files against the server so photos and videos already backed up don’t upload again.")
                Text("When the backup finishes, Imora returns to Backup settings and lets your screen lock normally again.")
                Text("Connect to power and leave this screen open. Locking your phone or switching apps lets iOS limit how long indexing and backup can continue.")
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.75))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            .accessibilityIdentifier("active-backup-explanation")

            Spacer()

            Button("Exit Active Mode") {
                finishActiveMode()
            }
            .buttonStyle(.bordered)
            .tint(.white.opacity(0.75))
            .accessibilityIdentifier("active-backup-exit")
        }
        .padding(32)
    }

    private func finishActiveMode() {
        // Release this screen before dismissal. Backup settings may still
        // keep the screen awake if the user exits while a backup is running.
        releaseIdleTimer()
        dismiss()
    }

    private func acquireIdleTimer() {
        ScreenAwakeCoordinator.shared.setActive(true, owner: idleTimerOwner)
    }

    private func releaseIdleTimer() {
        ScreenAwakeCoordinator.shared.setActive(false, owner: idleTimerOwner)
    }
}
