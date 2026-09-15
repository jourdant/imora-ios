import SwiftUI
import Photos

/// Inline status keeps the gallery usable and gives the action a clear label.
struct BackupStatusBanner: View {
    @Environment(SessionStore.self) private var session
    let openSettings: () -> Void

    var body: some View {
        if let backup = session.backup {
            if backup.showsBackupReminder {
                banner(title: "Backups are not enabled", message: "Keep your photos and videos backed up to your server.",
                       symbol: "icloud.slash", backup: backup, reminder: true)
            } else if let message = backup.syncHoldMessage {
                banner(title: "Not currently syncing", message: message,
                       symbol: backup.isHeldForLowBattery ? "battery.25percent" : "wifi.slash",
                       backup: backup, reminder: false)
            }
        }
    }

    private func banner(title: String, message: String, symbol: String,
                        backup: BackupManager, reminder: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if reminder {
                    Menu {
                        Button("Not Now") { backup.reminderHiddenThisSession = true }
                        Button("Don’t Ask Again") { backup.reminderDismissed = true }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("Dismiss backup reminder")
                    .accessibilityIdentifier("backup-reminder-dismiss")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actions(backup, reminder: reminder) }
                VStack(alignment: .leading, spacing: 4) { actions(backup, reminder: reminder) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.tertiary, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(reminder ? "backup-disabled-banner" : "backup-sync-held-banner")
    }

    @ViewBuilder
    private func actions(_ backup: BackupManager, reminder: Bool) -> some View {
        if reminder {
            Button("Enable Backups", action: openSettings)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("backup-reminder-enable")
        } else {
            Button("Sync This Time") { backup.syncThisTime() }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .disabled(PhotoAccess.shared.status != .authorized)
                .accessibilityHint("Temporarily allows backup under the conditions shown above.")
                .accessibilityIdentifier("backup-sync-this-time")
            Button("Backup Settings", action: openSettings)
                .font(.subheadline)
                .frame(minHeight: 44)
                .accessibilityIdentifier("backup-banner-settings")
        }
    }
}
