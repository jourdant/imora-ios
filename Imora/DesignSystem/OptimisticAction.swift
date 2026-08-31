import Observation
import SwiftUI
import UIKit

/// Runs a server mutation around a synchronous local projection. Callers own
/// the snapshot because only the feature knows the smallest safe rollback.
@MainActor
enum OptimisticAction {
    @discardableResult
    static func perform<Value>(
        errorMessage: String,
        apply: () -> Void,
        rollback: () -> Void,
        request: () async throws -> Value,
        commit: (Value) -> Void = { _ in },
        reportFailure: @MainActor (String, Error) -> Void = { message, error in
            ErrorToastCenter.shared.show(message, error: error)
        }
    ) async -> Value? {
        apply()
        do {
            let value = try await request()
            commit(value)
            return value
        } catch is CancellationError {
            rollback()
            return nil
        } catch {
            rollback()
            reportFailure(errorMessage, error)
            return nil
        }
    }
}

struct ErrorToast: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

/// App-wide post-action failure feedback. A separate pass-through window keeps
/// the banner above sheets and full-screen covers without interrupting input.
@Observable
@MainActor
final class ErrorToastCenter {
    static let shared = ErrorToastCenter()

    private(set) var current: ErrorToast?
    private var pending: [ErrorToast] = []

    func show(_ message: String) {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard current?.message != normalized,
              !pending.contains(where: { $0.message == normalized })
        else { return }

        let toast = ErrorToast(message: normalized)
        if current == nil {
            current = toast
        } else {
            pending.append(toast)
        }
        ErrorToastWindow.shared.present(center: self)
    }

    func show(_ action: String, error: Error) {
        show(Self.message(action: action, error: error))
    }

    func dismiss(_ id: UUID) {
        guard current?.id == id else { return }
        current = pending.isEmpty ? nil : pending.removeFirst()
    }

    private static func message(action: String, error: Error) -> String {
        let action = sentence(action)
        let detail: String
        if case ImmichError.http(401, _) = error {
            detail = "Your session has expired."
        } else {
            detail = sentence(error.localizedDescription)
        }
        guard action.localizedCaseInsensitiveCompare(detail) != .orderedSame else { return action }
        return "\(action) \(detail)"
    }

    private static func sentence(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "Something went wrong." }
        let capitalized = first.uppercased() + trimmed.dropFirst()
        return capitalized.last.map { ".!?".contains($0) } == true
            ? capitalized
            : capitalized + "."
    }
}

private struct ErrorToastHost: View {
    let center: ErrorToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if let toast = center.current {
                ErrorToastBanner(message: toast.message)
                    .id(toast.id)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity)
                    )
                    .task {
                        AccessibilityNotification.Announcement(toast.message).post()
                        try? await Task.sleep(for: .seconds(3.8))
                        guard !Task.isCancelled else { return }
                        center.dismiss(toast.id)
                    }
            }
        }
        .safeAreaPadding(.top)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3), value: center.current?.id)
        .allowsHitTesting(false)
        .ignoresSafeArea(edges: [.horizontal, .bottom])
    }
}

private struct ErrorToastBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 520, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.red.opacity(0.18), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error")
        .accessibilityValue(message)
        .accessibilityIdentifier("error-toast")
    }
}

@MainActor
private final class ErrorToastWindow {
    static let shared = ErrorToastWindow()

    private weak var scene: UIWindowScene?
    private var window: PassthroughWindow?

    func present(center: ErrorToastCenter) {
        guard let activeScene = Self.activeScene() else { return }
        if scene !== activeScene || window == nil {
            install(in: activeScene, center: center)
        }
        window?.isHidden = false
    }

    private func install(in scene: UIWindowScene, center: ErrorToastCenter) {
        let controller = UIHostingController(rootView: ErrorToastHost(center: center))
        controller.view.backgroundColor = .clear

        let window = PassthroughWindow(windowScene: scene)
        window.backgroundColor = .clear
        window.rootViewController = controller
        // Above this app's sheets, below system UI such as permission alerts.
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.accessibilityViewIsModal = false
        self.scene = scene
        self.window = window
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }
}

private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
