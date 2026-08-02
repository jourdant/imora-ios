import SwiftUI

/// what the share sheet handed over, with a percentage per file. leaving the
/// app does not stop it: the transfers belong to the background session and the
/// run reports into the lock screen indicator.
struct ShareUploadScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let model = session.shareUploads, model.hasWork {
                    content(model)
                } else {
                    ContentUnavailableView(
                        "Nothing to upload",
                        systemImage: "square.and.arrow.up",
                        description: Text("Share photos to Imora from any app to send them here.")
                    )
                }
            }
            .navigationTitle("Share to Imora")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if session.shareUploads?.isRunning == true {
                        Button("Cancel", role: .cancel) {
                            session.shareUploads?.cancel()
                        }
                    } else {
                        Button {
                            close()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityIdentifier("share-close")
                    }
                }
            }
        }
        .interactiveDismissDisabled(session.shareUploads?.isRunning == true)
    }

    private func content(_ model: ShareUploadModel) -> some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(model.rows) { row in
                        ShareUploadRow(row: row)
                    }
                } header: {
                    Text(header(model))
                }
            }
            .listStyle(.plain)

            footer(model)
        }
        .task {
            // starting here rather than on appear keeps the run tied to a
            // screen the user can actually watch.
            await start(model)
        }
    }

    private func header(_ model: ShareUploadModel) -> String {
        if model.isFinished {
            var parts = ["\(model.uploadedCount) uploaded"]
            if model.failedCount > 0 { parts.append("\(model.failedCount) failed") }
            return parts.joined(separator: " - ")
        }
        return model.isRunning
            ? "\(model.uploadedCount) of \(model.rows.count) uploaded"
            : "\(model.rows.count) item\(model.rows.count == 1 ? "" : "s") ready"
    }

    @ViewBuilder
    private func footer(_ model: ShareUploadModel) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: model.continuedFraction)
                .tint(.indigo)

            if model.isFinished {
                Button {
                    viewPhotos(model)
                } label: {
                    Label("View Photos", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("share-view-photos")
            } else {
                Text("You can leave Imora - uploads keep going in the background.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
        .padding(16)
        .background(.bar)
    }

    private func start(_ model: ShareUploadModel) async {
        guard !model.isRunning, !model.isFinished else { return }
        ContinuedProcessing.share.workload = model
        // the system runs it when it will, so it keeps going once the app is
        // backgrounded; otherwise the in-app run is the fallback.
        let accepted = await ContinuedProcessing.share.submit(
            title: "Uploading to Imora",
            subtitle: "\(model.rows.count) item\(model.rows.count == 1 ? "" : "s")"
        )
        if !accepted { model.start() }
    }

    private func viewPhotos(_ model: ShareUploadModel) {
        model.clearFinished()
        dismiss()
        NotificationRouter.shared.showsShareUpload = false
        NotificationRouter.shared.showsPhotos = true
    }

    private func close() {
        session.shareUploads?.clearFinished()
        dismiss()
        NotificationRouter.shared.showsShareUpload = false
    }
}

private struct ShareUploadRow: View {
    let row: ShareUploadModel.Row

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 46, height: 46)
                .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(row.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(detailColor)
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var thumbnail: some View {
        if let image = row.thumbnail {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(Color(.secondarySystemFill))
                .overlay {
                    Image(systemName: row.isVideo ? "video" : "photo")
                        .foregroundStyle(.tertiary)
                }
        }
    }

    @ViewBuilder private var trailing: some View {
        switch row.state {
        case .waiting:
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
        case .uploading(let fraction):
            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case .uploaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .duplicate:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var subtitle: String {
        switch row.state {
        case .waiting: "Waiting"
        case .uploading: "Uploading"
        case .uploaded: "Uploaded"
        case .duplicate: "Already on your server"
        case .failed(let message): message
        }
    }

    private var detailColor: Color {
        if case .failed = row.state { return .orange }
        return .secondary
    }
}
