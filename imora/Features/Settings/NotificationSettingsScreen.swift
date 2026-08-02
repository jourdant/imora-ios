import SwiftUI

/// two independent delivery paths: banners on this device, and the account-wide
/// email switches the server owns.
struct NotificationSettingsScreen: View {
    @Environment(SessionStore.self) private var session
    @Bindable private var local = LocalNotifications.shared

    @State private var email = EmailNotificationPreferences.default

    var body: some View {
        List {
            permissionSection
            alertsSection
            emailSection
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await local.refreshAuthorization()
            email = session.preferences?.email ?? .default
        }
    }

    // MARK: - system permission

    @ViewBuilder private var permissionSection: some View {
        Section {
            if local.isAuthorized {
                Button {
                    LocalNotifications.openSystemSettings()
                } label: {
                    LabeledContent {
                        Text("Open Settings")
                    } label: {
                        Label("Allowed", systemImage: "bell.badge")
                    }
                }
                .accessibilityIdentifier("notifications-open-settings")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Notifications Are Off", systemImage: "bell.slash")
                    Text("Imora cannot alert you about album invites, album activity or backup results until you allow notifications.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // a denied permission can only be undone in the system
                    // settings; asking again would do nothing.
                    Button(local.isDenied ? "Open Settings" : "Allow Notifications") {
                        if local.isDenied {
                            LocalNotifications.openSystemSettings()
                        } else {
                            Task { await local.requestAuthorization() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("notifications-allow")
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("This Device")
        }
    }

    // MARK: - device alerts

    private var alertsSection: some View {
        Section {
            Toggle(isOn: $local.albumInvites) {
                Label("Album Invites", systemImage: "rectangle.stack.badge.person.crop")
            }
            Toggle(isOn: $local.albumUpdates) {
                Label("Album Activity", systemImage: "photo.badge.plus")
            }
            Toggle(isOn: $local.serverAlerts) {
                Label("Server Alerts", systemImage: "exclamationmark.triangle")
            }
            Toggle(isOn: $local.backupReports) {
                Label("Backup Results", systemImage: "arrow.triangle.2.circlepath.icloud")
            }
        } header: {
            Text("Alerts")
        } footer: {
            Text("Immich has no push channel, so alerts arrive while Imora is running and anything missed is caught up the next time you open the app.")
        }
        .disabled(!local.isAuthorized)
    }

    // MARK: - server email

    private var emailSection: some View {
        Section {
            Toggle(isOn: binding(\.enabled)) {
                Label("Enable", systemImage: "envelope")
            }
            Toggle(isOn: binding(\.albumInvite)) {
                Label("Album Added", systemImage: "rectangle.stack.badge.plus")
            }
            .disabled(!email.enabled)
            Toggle(isOn: binding(\.albumUpdate)) {
                Label("Album Updated", systemImage: "photo.badge.plus")
            }
            .disabled(!email.enabled)
        } header: {
            Text("Email")
        } footer: {
            Text("Your server emails \(session.user?.email ?? "your address") when someone shares an album with you or adds photos to a shared album.")
        }
    }

    private func binding(_ keyPath: WritableKeyPath<EmailNotificationPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { email[keyPath: keyPath] },
            set: { newValue in
                email[keyPath: keyPath] = newValue
                save()
            }
        )
    }

    /// the album flags are gated by the master switch on the way out, matching
    /// the web client - the server then stores a coherent set.
    private func save() {
        guard let client = session.client else { return }
        let payload = EmailNotificationPreferences(
            enabled: email.enabled,
            albumInvite: email.enabled && email.albumInvite,
            albumUpdate: email.enabled && email.albumUpdate
        )
        Task {
            if let updated = try? await client.updateEmailNotifications(payload) {
                session.preferences = updated
            }
        }
    }
}
