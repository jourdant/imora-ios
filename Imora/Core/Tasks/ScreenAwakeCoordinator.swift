import UIKit

/// Multiple visible backup screens may overlap during a presentation transition.
/// Restore the previous setting only after the last screen releases its request.
@MainActor
final class ScreenAwakeCoordinator {
    static let shared = ScreenAwakeCoordinator()

    private var owners: Set<UUID> = []
    private var previousIdleTimerValue = false

    func setActive(_ active: Bool, owner: UUID) {
        if active {
            guard !owners.contains(owner) else { return }
            if owners.isEmpty {
                previousIdleTimerValue = UIApplication.shared.isIdleTimerDisabled
                UIApplication.shared.isIdleTimerDisabled = true
            }
            owners.insert(owner)
        } else {
            guard owners.remove(owner) != nil, owners.isEmpty else { return }
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerValue
        }
    }
}
