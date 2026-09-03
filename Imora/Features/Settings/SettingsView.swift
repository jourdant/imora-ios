import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var about: ServerAbout?
    @State private var confirmLogout = false
    @State private var memoriesMutations = SerialOptimisticValue<Bool>()
    @State private var peopleMutations = SerialOptimisticValue<Bool>()

    private func preferenceToggle(
        _ title: String,
        icon: String,
        section: ServerFeaturePreference
    ) -> some View {
        Toggle(isOn: Binding(
            get: { section.isEnabled(in: session.preferences) },
            set: { updatePreference(section, enabled: $0) }
        )) {
            Label(title, systemImage: icon)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        ProfileAvatar(size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.user?.name ?? "Unknown")
                                .font(.headline)
                            Text(session.user?.email ?? "")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Features") {
                    preferenceToggle("Memories", icon: "clock.arrow.circlepath", section: .memories)
                    preferenceToggle("People", icon: "person.2", section: .people)
                }

                Section {
                    NavigationLink {
                        NotificationSettingsScreen()
                    } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                    .accessibilityIdentifier("settings-notifications")

                    NavigationLink {
                        PrivacyScreen()
                    } label: {
                        Label("Privacy", systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("settings-privacy")

                    NavigationLink {
                        StorageScreen()
                    } label: {
                        Label("Storage", systemImage: "internaldrive")
                    }
                    .accessibilityIdentifier("settings-storage")

                    NavigationLink {
                        BackupScreen()
                    } label: {
                        Label("Backup", systemImage: "arrow.triangle.2.circlepath.icloud")
                    }
                    .accessibilityIdentifier("settings-backup")
                }

                Section("Server") {
                    LabeledContent("Address") {
                        Text(session.client?.apiURL.host() ?? "")
                            .lineLimit(1)
                    }
                    if let about {
                        LabeledContent("Version") {
                            Text(about.version)
                        }
                    }
                    if session.user?.isAdmin == true {
                        NavigationLink {
                            AdminScreen()
                        } label: {
                            Label("Administration", systemImage: "person.badge.key")
                        }
                        .accessibilityIdentifier("settings-administration")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        confirmLogout = true
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    // ios 26 morphs the dialog out of its source control, so it
                    // sits on the row - on the screen root it floats detached.
                    .confirmationDialog("Sign out of this server?", isPresented: $confirmLogout, titleVisibility: .visible) {
                        Button("Sign Out", role: .destructive) {
                            dismiss()
                            Task { await session.logOut() }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityIdentifier("settings-close")
                }
            }
            .task {
                about = try? await session.client?.serverAbout()
            }
        }
    }

    private func updatePreference(_ section: ServerFeaturePreference, enabled: Bool) {
        guard let client = session.client else {
            ErrorToastCenter.shared.show("Couldn’t update \(section.title.lowercased()). The server is not available.")
            return
        }
        let mutations = section == .memories ? memoriesMutations : peopleMutations
        mutations.submit(
            current: section.isEnabled(in: session.preferences),
            desired: enabled,
            errorMessage: "Couldn’t update \(section.title.lowercased())",
            apply: { value in
                guard session.client === client else { return }
                let current = session.preferences ?? .emptyForLocalProjection
                session.projectPreferences(
                    current.replacingFeature(section, enabled: value),
                    field: section.rawValue
                )
            },
            request: { value in
                let updated = try await client.updatePreference(section: section.rawValue, enabled: value)
                return section.isEnabled(in: updated)
            },
            activityChanged: { active in
                guard session.client === client else { return }
                session.setPreferenceMutation(section.rawValue, active: active)
            }
        )
    }
}

nonisolated enum ServerFeaturePreference: String {
    case memories
    case people

    var title: String {
        switch self {
        case .memories: "Memories"
        case .people: "People"
        }
    }

    func isEnabled(in preferences: UserPreferences?) -> Bool {
        switch self {
        case .memories: preferences?.memoriesEnabled ?? true
        case .people: preferences?.peopleEnabled ?? true
        }
    }
}

extension UserPreferences {
    nonisolated static var emptyForLocalProjection: UserPreferences {
        UserPreferences(
            memories: nil,
            people: nil,
            folders: nil,
            ratings: nil,
            tags: nil,
            sharedLinks: nil,
            emailNotifications: nil
        )
    }

    nonisolated func replacingFeature(
        _ section: ServerFeaturePreference,
        enabled: Bool
    ) -> UserPreferences {
        UserPreferences(
            memories: section == .memories ? FeatureToggle(enabled: enabled) : memories,
            people: section == .people ? FeatureToggle(enabled: enabled) : people,
            folders: folders,
            ratings: ratings,
            tags: tags,
            sharedLinks: sharedLinks,
            emailNotifications: emailNotifications
        )
    }

    nonisolated func replacingEmailNotifications(
        with email: EmailNotificationPreferences
    ) -> UserPreferences {
        UserPreferences(
            memories: memories,
            people: people,
            folders: folders,
            ratings: ratings,
            tags: tags,
            sharedLinks: sharedLinks,
            emailNotifications: email
        )
    }
}
