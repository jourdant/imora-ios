import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var storage: ServerStorage?
    @State private var about: ServerAbout?
    @State private var confirmLogout = false

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

                if let user = session.user, let quota = user.quotaSizeInBytes, quota > 0 {
                    Section("Storage") {
                        VStack(alignment: .leading, spacing: 8) {
                            let used = user.quotaUsageInBytes ?? 0
                            ProgressView(value: Double(used), total: Double(quota))
                                .tint(.indigo)
                            Text("\(ByteCountFormatStyle().format(used)) of \(ByteCountFormatStyle().format(quota)) used")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } else if let storage {
                    Section("Server Storage") {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: storage.diskUsagePercentage / 100)
                                .tint(.indigo)
                            Text("\(storage.diskUse) of \(storage.diskSize) used")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
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
                }
            }
            .task {
                guard let client = session.client else { return }
                async let storageTask = try? client.serverStorage()
                async let aboutTask = try? client.serverAbout()
                storage = await storageTask
                about = await aboutTask
            }
            .confirmationDialog("Sign out of this server?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    dismiss()
                    Task { await session.logOut() }
                }
            }
        }
    }
}
