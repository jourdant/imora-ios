import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// the share sheet entry point. the media becomes upload tasks on a background
/// url session right here - the system runs them with everything closed, so
/// there is no trip through the app and nothing for the user to wait on.
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
                signedIn: ShareUploader.credentials() != nil,
                send: { [weak self] in await self?.send() ?? false },
                complete: { [weak self] in self?.finish() }
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

    /// stages every provider into a request body and hands the batch to the
    /// system. returns whether anything was enqueued.
    private func send() async -> Bool {
        guard let credentials = ShareUploader.credentials() else { return false }
        var prepared: [ShareUploader.Prepared] = []
        for provider in providers {
            if let item = await ShareUploader.prepare(provider, deviceId: credentials.deviceId) {
                prepared.append(item)
            }
        }
        guard !prepared.isEmpty else { return false }
        ShareUploader.enqueue(prepared, credentials: credentials)
        return true
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

private let brandTint = Color(red: 171 / 255, green: 115 / 255, blue: 242 / 255)

private struct ShareSheetView: View {
    let count: Int
    let signedIn: Bool
    let send: () async -> Bool
    let complete: () -> Void

    private enum Phase: Equatable {
        case idle, sending, done, failed
    }

    @State private var phase = Phase.idle

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 52))
                    .foregroundStyle(brandTint.gradient)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
                footer
            }
            .padding(24)
            .animation(.smooth(duration: 0.25), value: phase)
            .navigationTitle("Imora")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: complete)
                        .disabled(phase == .sending)
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        switch phase {
        case .idle where count > 0 && signedIn:
            Button {
                phase = .sending
                Task {
                    phase = await send() ? .done : .failed
                    if phase == .done {
                        // a beat to read the confirmation, then out of the way.
                        try? await Task.sleep(for: .milliseconds(900))
                        complete()
                    }
                }
            } label: {
                Text("Add to Imora")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(brandTint)
            .controlSize(.large)
        case .sending:
            ProgressView()
                .padding(.bottom, 12)
        default:
            EmptyView()
        }
    }

    private var icon: String {
        switch phase {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle"
        default: break
        }
        if count == 0 { return "photo.badge.exclamationmark" }
        if !signedIn { return "person.crop.circle.badge.questionmark" }
        return "icloud.and.arrow.up"
    }

    private var title: String {
        switch phase {
        case .done: return "On their way"
        case .failed: return "Could not read the files"
        case .sending: return "Handing over"
        case .idle: break
        }
        if count == 0 { return "Nothing to add" }
        if !signedIn { return "Sign in first" }
        return count == 1 ? "Add 1 item" : "Add \(count) items"
    }

    private var subtitle: String {
        switch phase {
        case .done: return "They upload in the background. Imora notifies you once they are on your server."
        case .failed: return "Nothing was uploaded. Try sharing them again."
        case .sending: return "Preparing the uploads."
        case .idle: break
        }
        if count == 0 { return "Nothing here that Imora can upload." }
        if !signedIn { return "Open Imora and connect to your server, then share again." }
        return "They upload straight to your server - no need to open Imora."
    }
}
