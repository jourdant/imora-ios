import SwiftUI

/// Holds the idle timer only while this screen is visible, active and working.
private struct BackupScreenAwake: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @State private var owner = UUID()
    @State private var isVisible = false
    let isRunning: Bool

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                updateIdleTimer()
            }
            .onDisappear {
                isVisible = false
                updateIdleTimer()
            }
            .onChange(of: isRunning) { _, _ in updateIdleTimer() }
            .onChange(of: scenePhase) { _, _ in updateIdleTimer() }
    }

    private func updateIdleTimer() {
        ScreenAwakeCoordinator.shared.setActive(
            isVisible && isRunning && scenePhase == .active, owner: owner
        )
    }
}

extension View {
    func keepsBackupScreenAwake(while isRunning: Bool) -> some View {
        modifier(BackupScreenAwake(isRunning: isRunning))
    }
}
