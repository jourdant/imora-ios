import SwiftUI

/// two independent delivery paths: the device-side backup banners and badge,
/// and the account-wide email switches the server owns. server inbox entries
/// never become banners, so they need no switches here.
struct NotificationSettingsScreen: View {
    @Environment(SessionStore.self) private var session
    @Bindable private var local = LocalNotifications.shared

    @State private var email = EmailNotificationPreferences.default
    @State private var emailMutations = SerialOptimisticValue<EmailNotificationPreferences>()

    var body: some View {
        List {
            permissionSection
            alertsSection
            emailSection
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            email = session.preferences?.email ?? .default
            await local.refreshAuthorization()
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
                    Text("Imora cannot report backup results or badge the app icon with unread notifications until you allow notifications.")
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
            Toggle(isOn: $local.backupReports) {
                Label("Backup Failures", systemImage: "arrow.triangle.2.circlepath.icloud")
            }
        } header: {
            Text("Alerts")
        } footer: {
            Text("Imora only raises a banner when a backup stops on an error. Album invites and server messages stay in the in-app notification inbox.")
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
                var desired = email
                desired[keyPath: keyPath] = newValue
                save(desired)
            }
        )
    }

    /// the album flags are gated by the master switch on the way out, matching
    /// the web client - the server then stores a coherent set.
    private func save(_ desired: EmailNotificationPreferences) {
        guard let client = session.client else {
            ErrorToastCenter.shared.show("Couldn’t update email notifications. The server is not available.")
            return
        }
        emailMutations.submit(
            current: email,
            desired: desired,
            errorMessage: "Couldn’t update email notifications",
            apply: { value in
                guard session.client === client else { return }
                email = value
                let current = session.preferences ?? .emptyForLocalProjection
                session.projectPreferences(
                    current.replacingEmailNotifications(with: serverPayload(for: value)),
                    field: "email"
                )
            },
            request: { value in
                try await client.updateEmailNotifications(serverPayload(for: value)).email
            },
            activityChanged: { active in
                guard session.client === client else { return }
                session.setPreferenceMutation("email", active: active)
            }
        )
    }

    private func serverPayload(
        for value: EmailNotificationPreferences
    ) -> EmailNotificationPreferences {
        EmailNotificationPreferences(
            enabled: value.enabled,
            albumInvite: value.enabled && value.albumInvite,
            albumUpdate: value.enabled && value.albumUpdate
        )
    }
}
