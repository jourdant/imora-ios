import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var about: ServerAbout?
    @State private var confirmLogout = false

    private func preferenceToggle(_ title: String, icon: String, section: String, isOn: Bool) -> some View {
        Toggle(isOn: Binding(
            get: { isOn },
            set: { newValue in
                Task {
                    if let updated = try? await session.client?.updatePreference(section: section, enabled: newValue) {
                        session.preferences = updated
                    }
                }
            }
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
                    preferenceToggle("Memories", icon: "clock.arrow.circlepath", section: "memories", isOn: session.preferences?.memoriesEnabled ?? true)
                    preferenceToggle("People", icon: "person.2", section: "people", isOn: session.preferences?.peopleEnabled ?? true)
                }

                Section {
                    NavigationLink {
                        NotificationSettingsScreen()
                    } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                    .accessibilityIdentifier("settings-notifications")

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
}
