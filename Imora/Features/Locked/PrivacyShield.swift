import SwiftUI
import UIKit

/// covers the scene while locked content is up and the app is not active,
/// so the app switcher snapshot shows a lock instead of the grid. a window
/// of its own, like the error toast's, so it sits above the viewer's modal
/// and every sheet.
@MainActor
final class PrivacyShieldWindow {
    static let shared = PrivacyShieldWindow()

    private weak var scene: UIWindowScene?
    private var window: UIWindow?

    func show() {
        guard let activeScene = Self.activeScene() else { return }
        if scene !== activeScene || window == nil {
            install(in: activeScene)
        }
        window?.isHidden = false
    }

    func hide() {
        window?.isHidden = true
    }

    private func install(in scene: UIWindowScene) {
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: PrivacyShieldView())
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 2)
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

private struct PrivacyShieldView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
            Image(systemName: "lock.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
    }
}
