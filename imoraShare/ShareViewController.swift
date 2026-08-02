import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// the share sheet entry point. it stages the incoming media in the app group
/// and stops there: extensions are not allowed to open their containing app, so
/// a notification is what invites the user over to actually upload.
final class ShareViewController: UIViewController {
    private var providers: [NSItemProvider] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter {
                $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                    || $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            }

        let host = UIHostingController(
            rootView: ShareSheetView(
                count: providers.count,
                send: { [weak self] in self?.stage() },
                cancel: { [weak self] in self?.finish() }
            )
        )
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    private func stage() {
        Task {
            guard let directory = ShareInbox.directory else { return finish() }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var items: [ShareBatch.Item] = []
            for provider in providers {
                if let item = await Self.copy(provider, into: directory) { items.append(item) }
            }
            guard !items.isEmpty else { return finish() }
            ShareInbox.write(ShareBatch(id: UUID().uuidString, addedAt: Date(), items: items))
            await Self.notify(count: items.count)
            finish()
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// the url handed to the completion block is only valid inside it, so the
    /// copy happens there rather than after the await.
    private static func copy(_ provider: NSItemProvider, into directory: URL) async -> ShareBatch.Item? {
        let isVideo = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
        let type: UTType = isVideo ? .movie : .image
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let fileExtension = url.pathExtension.isEmpty ? (isVideo ? "mov" : "jpg") : url.pathExtension
                let storedName = "\(UUID().uuidString).\(fileExtension)"
                do {
                    try FileManager.default.copyItem(at: url, to: directory.appending(path: storedName))
                } catch {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: ShareBatch.Item(
                    id: UUID().uuidString,
                    storedName: storedName,
                    filename: url.lastPathComponent,
                    isVideo: isVideo
                ))
            }
        }
    }

    private static func notify(count: Int) async {
        let content = UNMutableNotificationContent()
        content.title = count == 1 ? "1 item ready for Imora" : "\(count) items ready for Imora"
        content.body = "Open Imora to upload to your server."
        content.sound = .default
        content.threadIdentifier = "imora.share"
        content.userInfo = ["shareImport": true]
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "imora.share.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
        )
    }
}

private struct ShareSheetView: View {
    let count: Int
    let send: () -> Void
    let cancel: () -> Void

    @State private var isSending = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: count == 0 ? "photo.badge.exclamationmark" : "icloud.and.arrow.up")
                    .font(.system(size: 52))
                    .foregroundStyle(.indigo.gradient)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(count == 0
                     ? "Nothing here that Imora can upload."
                     : "They are handed to Imora, which uploads them to your server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
                if isSending {
                    ProgressView()
                        .padding(.bottom, 12)
                } else if count > 0 {
                    Button {
                        isSending = true
                        send()
                    } label: {
                        Text("Add to Imora")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(24)
            .navigationTitle("Imora")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: cancel)
                }
            }
        }
    }

    private var title: String {
        switch count {
        case 0: "Nothing to add"
        case 1: "Add 1 item"
        default: "Add \(count) items"
        }
    }
}
