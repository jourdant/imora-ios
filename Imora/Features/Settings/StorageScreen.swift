import SwiftUI

/// storage overview: what the account occupies on the server and what imora
/// keeps on this device, with a way to reclaim the local caches. backup has
/// its own screen and is deliberately not represented here.
struct StorageScreen: View {
    @Environment(SessionStore.self) private var session

    @State private var serverStorage: ServerStorage?
    @State private var imageBytes: Int64 = 0
    @State private var libraryBytes: Int64 = 0
    @State private var confirmClear = false
    @State private var isClearing = false

    var body: some View {
        List {
            serverSection
            deviceSection
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // local sizes first - they are instant and must not sit behind a
            // slow server round trip showing zero kb.
            await refreshLocalSizes()
            serverStorage = try? await session.client?.serverStorage()
        }
    }

    // MARK: - server

    @ViewBuilder private var serverSection: some View {
        if let user = session.user, let quota = user.quotaSizeInBytes, quota > 0 {
            Section("Server") {
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
        } else if let serverStorage {
            Section("Server") {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: serverStorage.diskUsagePercentage / 100)
                        .tint(.indigo)
                    Text("\(serverStorage.diskUse) of \(serverStorage.diskSize) used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - device

    private var deviceSection: some View {
        Section {
            LabeledContent("Image Cache") {
                Text(byteText(imageBytes))
            }
            LabeledContent("Library Data") {
                Text(byteText(libraryBytes))
            }
            Button(role: .destructive) {
                confirmClear = true
            } label: {
                if isClearing {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Clear Cache")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(isClearing || imageBytes + libraryBytes == 0)
            .accessibilityIdentifier("storage-clear-cache")
            // ios 26 morphs the dialog out of its source control, so it sits
            // on the button - on the screen root it floats detached.
            .confirmationDialog(
                "Clear \(byteText(imageBytes + libraryBytes)) of cached data?",
                isPresented: $confirmClear,
                titleVisibility: .visible
            ) {
                Button("Clear Cache", role: .destructive) {
                    Task { await clearCache() }
                }
            } message: {
                Text("Photos download again as you browse, and offline browsing rebuilds on the next launch.")
            }
        } header: {
            Text("On This Device")
        } footer: {
            Text("Cached data is re-downloadable and separate from your backed up photos.")
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    private func refreshLocalSizes() async {
        let sizes = await Task.detached(priority: .utility) {
            (
                ImageLoader.shared.diskUsage(),
                TimelineCache.diskUsage() + OfflineCache.diskUsage()
            )
        }.value
        imageBytes = sizes.0
        libraryBytes = sizes.1
    }

    private func clearCache() async {
        isClearing = true
        await Task.detached(priority: .userInitiated) {
            ImageLoader.shared.clearCache()
            TimelineCache.removeAll()
            OfflineCache.removeAll()
        }.value
        await refreshLocalSizes()
        isClearing = false
    }
}
