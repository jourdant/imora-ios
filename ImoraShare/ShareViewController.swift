import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// what came out of handing a drop over to the system.
private enum SendOutcome {
    case failed
    /// uploads are enqueued; `progressVisible` says whether the system took
    /// the continued-processing task that shows their progress.
    case queued(progressVisible: Bool)
}

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
                signedIn: ShareTransfer.credentials() != nil,
                send: { [weak self] in await self?.send() ?? .failed },
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

    /// Stages every provider into a request body and hands the batch to the
    /// extension-owned progress task, with a daemon session as fallback.
    private func send() async -> SendOutcome {
        guard let credentials = ShareTransfer.credentials() else { return .failed }
        var prepared: [ShareUploader.Prepared] = []
        for provider in providers {
            if let item = await ShareUploader.prepare(provider, deviceId: credentials.deviceId) {
                prepared.append(item)
            }
        }
        guard !prepared.isEmpty else { return .failed }
        let progressVisible = await ShareUploader.handOff(prepared, credentials: credentials)
        return .queued(progressVisible: progressVisible)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

private let brandTint = Color(red: 171 / 255, green: 115 / 255, blue: 242 / 255)

private struct ShareSheetView: View {
    let count: Int
    let signedIn: Bool
    let send: () async -> SendOutcome
    let complete: () -> Void

    private enum Phase: Equatable {
        case idle, sending, done(progressVisible: Bool), failed
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
            // ipad presents the extension in a wide sheet; the column keeps
            // its phone proportions in the middle of it.
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
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

    /// a fixed-height slot so no phase change reflows the texts above. while
    /// staging, the button stays in place and only its label becomes a
    /// spinner - swapping whole views here is what used to make the sheet
    /// flicker mid-dismissal.
    @ViewBuilder private var footer: some View {
        ZStack {
            switch phase {
            case .idle where count > 0 && signedIn, .sending:
                Button(action: start) {
                    ZStack {
                        // invisible text keeps the button footprint stable.
                        Text("Add to Imora").opacity(phase == .sending ? 0 : 1)
                        if phase == .sending { ProgressView() }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(brandTint)
                .controlSize(.large)
                .disabled(phase == .sending)
            default:
                Color.clear
            }
        }
        .frame(height: 52)
    }

    private func start() {
        guard phase == .idle else { return }
        phase = .sending
        Task {
            switch await send() {
            case .failed:
                phase = .failed
            case .queued(let progressVisible):
                phase = .done(progressVisible: progressVisible)
                // a beat to read the confirmation, then out of the way.
                try? await Task.sleep(for: .milliseconds(900))
                complete()
            }
        }
    }

    private var icon: String {
        switch phase {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle"
        // staging keeps the idle look; the button spinner tells the story.
        case .idle, .sending: break
        }
        if count == 0 { return "photo.badge.exclamationmark" }
        if !signedIn { return "person.crop.circle.badge.questionmark" }
        return "icloud.and.arrow.up"
    }

    private var title: String {
        switch phase {
        case .done: return "On their way"
        case .failed: return "Could not read the files"
        case .idle, .sending: break
        }
        if count == 0 { return "Nothing to add" }
        if !signedIn { return "Sign in first" }
        return count == 1 ? "Add 1 item" : "Add \(count) items"
    }

    private var subtitle: String {
        switch phase {
        case .done(let progressVisible):
            return progressVisible
                ? "They upload in the background - follow the progress from your Lock Screen or Dynamic Island."
                : "They upload in the background. Imora notifies you once they are on your server."
        case .failed: return "Nothing was uploaded. Try sharing them again."
        case .idle, .sending: break
        }
        if count == 0 { return "Nothing here that Imora can upload." }
        if !signedIn { return "Open Imora and connect to your server, then share again." }
        return "They upload straight to your server - no need to open Imora."
    }
}
